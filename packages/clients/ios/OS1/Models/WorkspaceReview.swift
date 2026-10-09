import Foundation

/// Open Session's own review request on a session: who was asked, by whom, and
/// whether they have signed off. GitHub's reviewer list is a separate fact
/// (`Session.prReviewRequested`) — see `Session.reviewRequest`.
struct SessionReviewRequest: Decodable, Equatable, Hashable {
    /// The reviewer's display name, or a review team's GitHub spec.
    var to: String
    /// The individual people a team request covers, expanded server-side.
    var recipients: [String]?
    /// Who asked.
    var by: String
    /// ISO timestamp of the ask.
    var at: String
    /// Set when the reviewer signs off. The request stays in place so the
    /// asker still sees who reviewed it.
    var accepted: Signoff?

    struct Signoff: Decodable, Equatable, Hashable {
        var by: String
        var at: String
    }

    /// Is this request pointed at `person` (the reviewer, or anyone in the
    /// team it was made to)?
    func targets(_ person: String) -> Bool {
        let key = person.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return false }
        return ([to] + (recipients ?? [])).contains { $0.lowercased() == key }
    }
}

/// Where a workspace's review stands, for both of the people who can give one:
/// the agent that reads the pull request, and the teammate somebody asked.
///
/// A workspace is the unit here, not a session. The request is stored per
/// session but the sidebar's Needs-review band groups by workspace, so a
/// request set on a sibling session has to reach the panel of the one you have
/// open — carrying the id it actually lives on, so clearing or re-assigning
/// writes to the right session. Same rule as the web's `effectiveReview`
/// (components/SessionViewer.tsx).
enum WorkspaceReview {
    struct State: Equatable {
        /// The workspace's request, with a GitHub-completed sign-off folded in.
        var request: SessionReviewRequest?
        /// The session that owns it — where a change is written.
        var ownerId: String
        /// The sign-off came from GitHub rather than from the menu, so
        /// reopening means asking again rather than clearing a local flag.
        var acceptedFromPr: Bool
        /// Everyone GitHub still lists as a requested reviewer, across every
        /// PR in the workspace.
        var githubRequested: [String]
    }

    static func state(
        of sessions: [Session],
        openSessionId: String
    ) -> State {
        let open = sessions.first { $0.id == openSessionId }
        let owner = (open?.reviewRequest != nil ? open : nil)
            ?? sessions.first { $0.reviewRequest != nil }
        let request = owner?.reviewRequest
        let signoff = owner.flatMap { session in
            request.flatMap { completion(of: $0, on: session) }
        }
        var withSignoff = request
        if let signoff { withSignoff?.accepted = signoff }
        // A workspace can span several pull requests, and a request on any of
        // them is a request on the workspace.
        var seen = Set<String>()
        let requested = sessions
            .flatMap { $0.prReviewRequested ?? [] }
            .filter { seen.insert($0.lowercased()).inserted }
        return State(
            request: withSignoff,
            ownerId: owner?.id ?? openSessionId,
            acceptedFromPr: signoff != nil,
            githubRequested: requested
        )
    }

    /// A review team somebody asked, as the teammate row names it.
    struct RequestedTeam: Equatable {
        var name: String
        /// Its GitHub spec (`org/team`), what the picker marks as current.
        var github: String
        /// Asked through Open Session's own request rather than only on GitHub.
        var fromRequest: Bool
    }

    /// A review a teammate submitted on the pull request on their own.
    struct Verdict: Equatable {
        var name: String
        /// APPROVED | CHANGES_REQUESTED | COMMENTED
        var state: String

        var label: String {
            switch state {
            case "APPROVED": "approved"
            case "CHANGES_REQUESTED": "requested changes"
            default: "commented"
            }
        }
    }

    /// What the teammate row says: the team a request names, everyone else
    /// GitHub still lists, and the reviews already given.
    struct Summary: Equatable {
        var team: RequestedTeam?
        /// GitHub's pending reviewers no team request speaks for. Empty while
        /// Open Session has a request of its own, which then speaks for the row.
        var githubOthers: [String]
        var verdicts: [Verdict]
    }

    /// A team request is one fact, so it is one name on the row. GitHub
    /// requests the team and the server expands it to its members for "asked
    /// of me", which otherwise reads as one member's name plus a count. Same
    /// rule as the web's `reviewLines` (lib/review-lines.ts).
    ///
    /// `githubRequested` stays the expanded list: the caller still uses it to
    /// tell whether the review waits on the viewer.
    static func summary(
        request: SessionReviewRequest?,
        githubRequested: [String],
        pr: PrDetails?,
        teams: [OS1API.ReviewTeam],
        personName: (String) -> String = { $0 }
    ) -> Summary {
        func team(for spec: String) -> OS1API.ReviewTeam? {
            let lower = spec.lowercased()
            return teams.first {
                let github = $0.github.lowercased()
                return github == lower || github.split(separator: "/").last.map(String.init) == lower
            }
        }
        func key(_ person: String) -> String { personName(person).lowercased() }

        var covered = Set<String>()
        var named: RequestedTeam?
        if let request, let match = team(for: request.to) {
            named = RequestedTeam(name: match.name, github: match.github, fromRequest: true)
            covered.formUnion((match.members ?? []).map(key))
        }
        let open = pr?.isOpen == true
        let reviewers = open ? pr?.reviewers ?? [] : []
        for reviewer in reviewers where reviewer.isTeam == true && reviewer.state == "PENDING" {
            let match = team(for: reviewer.login)
            covered.formUnion((match?.members ?? []).map(key))
            if named == nil, request == nil {
                named = RequestedTeam(
                    name: match?.name ?? reviewer.login,
                    github: match?.github ?? reviewer.login,
                    fromRequest: false
                )
            }
        }

        var seen = Set<String>()
        let others = request != nil ? [] : githubRequested.filter {
            let person = key($0)
            return !covered.contains(person) && seen.insert(person).inserted
        }

        // First submitted review per person; a pending entry is a request,
        // which the row already speaks for.
        var verdicts: [Verdict] = []
        var given = Set<String>()
        for reviewer in reviewers where reviewer.isTeam != true {
            guard let state = reviewer.state,
                  ["APPROVED", "CHANGES_REQUESTED", "COMMENTED"].contains(state),
                  !reviewer.login.lowercased().hasSuffix("[bot]")
            else { continue }
            let name = personName(reviewer.login)
            guard given.insert(name.lowercased()).inserted else { continue }
            verdicts.append(Verdict(name: name, state: state))
        }
        return Summary(team: named, githubOthers: others, verdicts: verdicts)
    }

    /// A review the reviewer gave on GitHub instead of pressing "Mark as
    /// reviewed" here. GitHub drops somebody from the requested list the
    /// moment they submit, so "reviewed, and no longer pending" is the test —
    /// and it only counts when it happened after the ask.
    static func completion(
        of request: SessionReviewRequest,
        on session: Session
    ) -> SessionReviewRequest.Signoff? {
        guard request.accepted == nil, let updatedAt = session.prUpdatedAt else { return nil }
        guard let reviewedAt = Session.parseISO(updatedAt),
              let requestedAt = Session.parseISO(request.at),
              reviewedAt > requestedAt
        else { return nil }
        let reviewers = [request.to] + (request.recipients ?? [])
        let reviewed = (session.prReviewedBy ?? []).map { $0.lowercased() }
        let pending = (session.prReviewRequested ?? []).map { $0.lowercased() }
        guard let reviewer = reviewers.first(where: { person in
            let key = person.lowercased()
            return reviewed.contains(key) && !pending.contains(key)
        }) else { return nil }
        return SessionReviewRequest.Signoff(by: reviewer, at: updatedAt)
    }
}

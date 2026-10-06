import Foundation

/// PR details from `GET /api/sessions/:id/pr` — a tolerant subset of the
/// server's PrDetails (src/server/pr-info.ts). The route answers a bare JSON
/// `null` when the session's branch has no PR; decoding is optional-heavy so
/// server-side additions never break the client.
struct PrDetails: Decodable, Equatable {
    var number: Int
    var title: String?
    var url: String?
    /// OPEN | MERGED | CLOSED
    var state: String?
    var isDraft: Bool?
    var baseRefName: String?
    var headRefName: String?
    var additions: Int?
    var deletions: Int?
    var changedFiles: Int?
    /// APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED | ""
    var reviewDecision: String?
    var author: String?
    var checks: [PrCheck]?
    var reviewers: [PrReviewer]?
    /// MERGEABLE | CONFLICTING | UNKNOWN — the provider's conflict probe.
    var mergeable: String?
    /// CLEAN | BEHIND | BLOCKED | DIRTY | UNSTABLE | … — merge-box state.
    var mergeStateStatus: String?
    /// The agent's last reading of this pull request, when one has run.
    var osReview: OsReviewSummary?
    /// A review pass is running on the PR right now.
    var reviewActive: Bool?
    /// The pull request's conversation, oldest first.
    var comments: [PrComment]?
    /// The description, as the author wrote it (markdown).
    var body: String?
    var commits: [PrCommit]?
    /// Per-file line counts, biggest churn first. The patch itself comes from
    /// the diff route; this is what the overview lists without loading it.
    var files: [PrFile]?
    var staging: PrStaging?
    /// What the PR's host supports. Absent on GitHub-only servers, which
    /// means everything is.
    var capabilities: PrHostCapabilities?
}

/// The host features the review surface branches on (`PrHostCapabilities`
/// in pr-contract.ts). A missing flag means supported, as on the web.
struct PrHostCapabilities: Decodable, Equatable {
    /// Per-viewer "Viewed" state. Without it, review marks stay on device.
    var viewedState: Bool?
    var reviewComments: Bool?
}

struct PrCommit: Decodable, Equatable, Identifiable {
    var oid: String
    var messageHeadline: String?
    var author: String?

    var id: String { oid }
    var shortOid: String { String(oid.prefix(7)) }
}

struct PrFile: Decodable, Equatable, Identifiable {
    var path: String
    var additions: Int?
    var deletions: Int?

    var id: String { path }
}

/// The PR's preview environment, when the repo builds one.
struct PrStaging: Decodable, Equatable {
    var url: String?
}

struct PrComment: Decodable, Equatable {
    var author: String?
    var body: String
    var createdAt: String?
    var url: String?

    /// The comment without the hidden markers bots use to find their own
    /// comments again. Mirrors the web's `stripHtmlComments`.
    var discussionBody: String {
        body
            .replacingOccurrences(
                of: "<!--[\\s\\S]*?-->",
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A superseded automated review stays on GitHub for history, not as
    /// something to read (`isOutdatedReviewComment` on the web).
    var isOutdatedReview: Bool {
        body.range(
            of: "<!--\\s*os-review-outdated\\s*-->",
            options: .regularExpression
        ) != nil
    }

    /// Worth showing in the conversation: it says something once its markers
    /// are stripped, and it has not been superseded.
    var isDiscussion: Bool {
        !discussionBody.isEmpty && !isOutdatedReview
    }
}

struct PrCheck: Decodable, Equatable {
    var name: String
    /// COMPLETED, IN_PROGRESS, QUEUED… ("" for StatusContexts).
    var status: String?
    /// SUCCESS, FAILURE, NEUTRAL, PENDING…
    var conclusion: String?
    var url: String?
    var startedAt: String?
    var completedAt: String?
    /// CheckRun workflow (e.g. "CI") — StatusContexts (Vercel deploys) have none.
    var workflowName: String?

    enum Rank {
        case success, failure, pending, neutral
    }

    /// Mirrors the web PrPanel's checkClass(): anything not completed is
    /// pending, and StatusContexts report PENDING/EXPECTED as a *conclusion*
    /// with an empty status, which must not read as neutral.
    var rank: Rank {
        let liveStatus = status ?? ""
        if liveStatus != "COMPLETED" && liveStatus != "" { return .pending }
        switch conclusion ?? "" {
        case "PENDING", "EXPECTED": return .pending
        case "SUCCESS": return .success
        case "FAILURE", "TIMED_OUT", "ERROR": return .failure
        default: return .neutral
        }
    }
}

/// A person on the PR's reviewer list; `state` is the review outcome
/// (APPROVED | CHANGES_REQUESTED | COMMENTED | DISMISSED) or PENDING for a
/// requested-but-not-yet-submitted review.
struct PrReviewer: Decodable, Equatable {
    var login: String
    var state: String?
    var isTeam: Bool?
}

extension PrDetails {
    /// One-dot summary for the toolbar chip: terminal states first, then the
    /// check rollup while open (no checks at all counts as passing — "no
    /// known CI blocker", matching the web list's treatment).
    enum Summary {
        case merged, closed, draft, failing, pending, passing
    }

    /// Still actionable: not merged and not closed. A server old enough to omit
    /// `state` counts as open — the actions it gates all fail loudly server-side
    /// rather than doing the wrong thing.
    var isOpen: Bool {
        state != "MERGED" && state != "CLOSED"
    }

    var summary: Summary {
        switch state ?? "" {
        case "MERGED": return .merged
        case "CLOSED": return .closed
        default: break
        }
        if isDraft == true { return .draft }
        let ranks = (checks ?? []).map(\.rank)
        if ranks.contains(.failure) { return .failing }
        if ranks.contains(.pending) { return .pending }
        return .passing
    }
}

extension PrDetails.Summary {
    /// How a PR named in prose is coloured. The same five meanings as
    /// `PrChipLabel`'s dot (PrPanel.swift), because one PR must not read one
    /// way in the toolbar and another in the sentence above it — but as a wash
    /// under the whole chip rather than a mark in front of it, which is what
    /// the web does too (`a.pr-ref[data-pr-tone]`).
    var chipTone: TranscriptChip.Tone {
        switch self {
        case .merged: .purple
        case .closed, .failing: .red
        case .draft: .gray
        case .pending: .yellow
        case .passing: .green
        }
    }
}

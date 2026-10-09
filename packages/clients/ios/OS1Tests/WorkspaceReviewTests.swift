import Foundation
import Testing
@testable import OS1

/// Where a workspace's review request lives, and when it counts as given.
///
/// Both rules are shared with the web (`effectiveReview` in SessionViewer.tsx,
/// `prReviewCompletion` in lib/review-queue): a request set on one session
/// speaks for the whole workspace, and a review submitted on GitHub completes
/// it without anybody pressing anything here.
struct WorkspaceReviewTests {
    private func session(
        id: String,
        request: SessionReviewRequest? = nil,
        requested: [String]? = nil,
        reviewedBy: [String]? = nil,
        prUpdatedAt: String? = nil
    ) -> Session {
        var session = Session(id: id)
        session.reviewRequest = request
        session.prReviewRequested = requested
        session.prReviewedBy = reviewedBy
        session.prUpdatedAt = prUpdatedAt
        return session
    }

    private func request(
        to: String,
        recipients: [String]? = nil,
        at: String = "2026-08-14T10:00:00Z",
        accepted: SessionReviewRequest.Signoff? = nil
    ) -> SessionReviewRequest {
        SessionReviewRequest(to: to, recipients: recipients, by: "Michiel", at: at, accepted: accepted)
    }

    @Test func readsTheOpenSessionsOwnRequestFirst() {
        let state = WorkspaceReview.state(
            of: [
                session(id: "a", request: request(to: "Kent")),
                session(id: "b", request: request(to: "Grant")),
            ],
            openSessionId: "b"
        )
        #expect(state.request?.to == "Grant")
        #expect(state.ownerId == "b")
    }

    /// The sidebar bands group by workspace, so a request set on a sibling has
    /// to reach the open session's panel — carrying the sibling's id, or
    /// clearing it would write to the wrong session.
    @Test func fallsBackToASiblingsRequestAndKeepsItsOwner() {
        let state = WorkspaceReview.state(
            of: [session(id: "a", request: request(to: "Kent")), session(id: "b")],
            openSessionId: "b"
        )
        #expect(state.request?.to == "Kent")
        #expect(state.ownerId == "a")
    }

    @Test func withoutARequestTheOpenSessionOwnsTheNextOne() {
        let state = WorkspaceReview.state(of: [session(id: "b")], openSessionId: "b")
        #expect(state.request == nil)
        #expect(state.ownerId == "b")
    }

    @Test func gathersGithubsReviewersAcrossEveryPrInTheWorkspace() {
        let state = WorkspaceReview.state(
            of: [
                session(id: "a", requested: ["kent"]),
                session(id: "b", requested: ["Kent", "grant"]),
            ],
            openSessionId: "a"
        )
        #expect(state.githubRequested == ["kent", "grant"])
    }

    @Test func aReviewSubmittedOnGithubCompletesTheRequest() {
        let state = WorkspaceReview.state(
            of: [
                session(
                    id: "a",
                    request: request(to: "Kent"),
                    requested: [],
                    reviewedBy: ["kent"],
                    prUpdatedAt: "2026-08-14T11:00:00Z"
                )
            ],
            openSessionId: "a"
        )
        #expect(state.request?.accepted?.by == "Kent")
        #expect(state.acceptedFromPr)
    }

    /// Still listed as a reviewer means the review has not landed: GitHub
    /// drops somebody the instant they submit, and puts them back on a
    /// re-request.
    @Test func aStillPendingReviewerDoesNotCompleteIt() {
        let state = WorkspaceReview.state(
            of: [
                session(
                    id: "a",
                    request: request(to: "Kent"),
                    requested: ["kent"],
                    reviewedBy: ["kent"],
                    prUpdatedAt: "2026-08-14T11:00:00Z"
                )
            ],
            openSessionId: "a"
        )
        #expect(state.request?.accepted == nil)
        #expect(!state.acceptedFromPr)
    }

    /// An older review is the previous round's, not an answer to this ask.
    @Test func aReviewFromBeforeTheAskDoesNotCompleteIt() {
        let state = WorkspaceReview.state(
            of: [
                session(
                    id: "a",
                    request: request(to: "Kent", at: "2026-08-14T12:00:00Z"),
                    requested: [],
                    reviewedBy: ["kent"],
                    prUpdatedAt: "2026-08-14T11:00:00Z"
                )
            ],
            openSessionId: "a"
        )
        #expect(state.request?.accepted == nil)
    }

    @Test func aTeamRequestIsCompletedByAnyOfItsMembers() {
        let state = WorkspaceReview.state(
            of: [
                session(
                    id: "a",
                    request: request(to: "tellahq/reviewers", recipients: ["kent", "grant"]),
                    requested: ["kent"],
                    reviewedBy: ["grant"],
                    prUpdatedAt: "2026-08-14T11:00:00Z"
                )
            ],
            openSessionId: "a"
        )
        #expect(state.request?.accepted?.by == "grant")
    }

    @Test func aSignoffMadeHereIsLeftAlone() {
        let signoff = SessionReviewRequest.Signoff(by: "Kent", at: "2026-08-14T10:30:00Z")
        let state = WorkspaceReview.state(
            of: [
                session(
                    id: "a",
                    request: request(to: "Kent", accepted: signoff),
                    requested: [],
                    reviewedBy: ["kent"],
                    prUpdatedAt: "2026-08-14T11:00:00Z"
                )
            ],
            openSessionId: "a"
        )
        #expect(state.request?.accepted == signoff)
        #expect(!state.acceptedFromPr)
    }

    @Test func aRequestTargetsItsTeamsMembersToo() {
        let team = request(to: "tellahq/reviewers", recipients: ["kent", "grant"])
        #expect(team.targets("Kent"))
        #expect(team.targets("tellahq/reviewers"))
        #expect(!team.targets("alex"))
        #expect(!team.targets(""))
    }

    // MARK: Team requests on the teammate row

    private let reviewers = OS1API.ReviewTeam(
        name: "Reviewers",
        github: "acme/reviewers",
        members: ["kent", "grant"]
    )

    private func pr(_ reviewers: [PrReviewer], state: String = "OPEN") -> PrDetails {
        PrDetails(number: 1, state: state, reviewers: reviewers)
    }

    /// GitHub asked the team and the server expanded it to its members; the
    /// row names the team rather than "kent +1".
    @Test func aGithubOnlyTeamRequestNamesTheTeam() {
        let summary = WorkspaceReview.summary(
            request: nil,
            githubRequested: ["kent", "grant"],
            pr: pr([PrReviewer(login: "reviewers", state: "PENDING", isTeam: true)]),
            teams: [reviewers]
        )
        #expect(summary.team == .init(name: "Reviewers", github: "acme/reviewers", fromRequest: false))
        #expect(summary.githubOthers.isEmpty)
    }

    /// A team outside the roster still reads as itself, by its GitHub slug.
    @Test func anUnknownGithubTeamKeepsItsSlug() {
        let summary = WorkspaceReview.summary(
            request: nil,
            githubRequested: [],
            pr: pr([PrReviewer(login: "acme/other", state: "PENDING", isTeam: true)]),
            teams: [reviewers]
        )
        #expect(summary.team?.name == "acme/other")
    }

    /// Open Session's request and GitHub's are the same team: one name, and
    /// it is ours, so the menu offers sign-off rather than only clearing.
    @Test func aMatchingOpenSessionTeamRequestIsOneTeam() {
        let summary = WorkspaceReview.summary(
            request: request(to: "acme/reviewers", recipients: ["kent", "grant"]),
            githubRequested: ["kent", "grant"],
            pr: pr([PrReviewer(login: "acme/reviewers", state: "PENDING", isTeam: true)]),
            teams: [reviewers]
        )
        #expect(summary.team == .init(name: "Reviewers", github: "acme/reviewers", fromRequest: true))
        #expect(summary.githubOthers.isEmpty)
    }

    /// A member who reviewed on their own keeps that review on the row.
    @Test func aMembersSubmittedReviewIsKept() {
        let summary = WorkspaceReview.summary(
            request: nil,
            githubRequested: ["kent"],
            pr: pr([
                PrReviewer(login: "reviewers", state: "PENDING", isTeam: true),
                PrReviewer(login: "grant", state: "APPROVED"),
                PrReviewer(login: "grant", state: "COMMENTED"),
                PrReviewer(login: "ci[bot]", state: "COMMENTED"),
            ]),
            teams: [reviewers]
        )
        #expect(summary.team?.name == "Reviewers")
        #expect(summary.verdicts == [.init(name: "grant", state: "APPROVED")])
        #expect(summary.verdicts.first?.label == "approved")
    }

    /// Somebody GitHub asked outside the team still counts beside it.
    @Test func anUnrelatedGithubRequestStaysBesideTheTeam() {
        let summary = WorkspaceReview.summary(
            request: nil,
            githubRequested: ["kent", "grant", "alex"],
            pr: pr([PrReviewer(login: "reviewers", state: "PENDING", isTeam: true)]),
            teams: [reviewers]
        )
        #expect(summary.team?.name == "Reviewers")
        #expect(summary.githubOthers == ["alex"])
    }

    /// Without any team request, GitHub's people are listed as before.
    @Test func individualGithubRequestsAreNotFolded() {
        let summary = WorkspaceReview.summary(
            request: nil,
            githubRequested: ["kent", "alex"],
            pr: pr([PrReviewer(login: "kent", state: "PENDING")]),
            teams: [reviewers]
        )
        #expect(summary.team == nil)
        #expect(summary.githubOthers == ["kent", "alex"])
    }

    /// A merged pull request's reviewer list is history, not a live request.
    @Test func aClosedPullRequestNamesNoTeam() {
        let summary = WorkspaceReview.summary(
            request: nil,
            githubRequested: [],
            pr: pr([PrReviewer(login: "reviewers", state: "PENDING", isTeam: true)], state: "MERGED"),
            teams: [reviewers]
        )
        #expect(summary.team == nil)
        #expect(summary.verdicts.isEmpty)
    }
}

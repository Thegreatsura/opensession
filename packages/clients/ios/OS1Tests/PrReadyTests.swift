import XCTest
@testable import OS1

@MainActor
final class PrReadyTests: XCTestCase {
    private func draftPr(_ number: Int = 72) -> PrDetails {
        try! JSONDecoder().decode(
            PrDetails.self,
            from: Data(#"{"number":\#(number),"state":"OPEN","isDraft":true}"#.utf8)
        )
    }

    private func seriesSession() -> Session {
        var session = Session(id: "os-ready")
        session.repo = "acme-app"
        session.branch = "feature/base"
        session.prIsDraft = true
        session.prs = [
            SessionPrRef(repo: "acme-app", branch: "feature/base", source: "primary",
                         state: "OPEN", number: 72, isDraft: true),
            SessionPrRef(repo: "acme-docs", branch: "feature/docs", source: "attached",
                         state: "OPEN", number: 9, isDraft: true),
        ]
        return session
    }

    // MARK: - Route targets

    func testSessionTargetWithoutRepoLeavesThePrimaryToTheServer() {
        let target = PrReadyTarget.session(id: "os-ready")
        XCTAssertEqual(target.path, "/api/sessions/os-ready/pr-ready")
        XCTAssertEqual(target.body, [:])
    }

    func testAttachedRepoTargetNamesItsRepoAndBranch() {
        let target = PrReadyTarget.session(id: "os-ready", repo: "acme-docs", branch: "feature/docs")
        XCTAssertEqual(target.path, "/api/sessions/os-ready/pr-ready")
        XCTAssertEqual(target.body, ["repo": "acme-docs", "branch": "feature/docs"])
    }

    func testSessionlessPreviewUsesThePreviewRoute() {
        let target = PrReadyTarget.preview(repo: "acme-app", branch: "feature/preview")
        XCTAssertEqual(target.path, "/api/pr-preview-ready")
        XCTAssertEqual(target.body, ["repo": "acme-app", "branch": "feature/preview"])
    }

    // MARK: - View model

    func testPrimaryReadyClearsDraftAndRefetchesOnlyThePanelPr() async throws {
        var sent: [PrReadyTarget] = []
        var loads = 0
        let viewModel = SessionViewModel(
            session: seriesSession(),
            prLoader: { _ in
                loads += 1
                var pr = self.draftPr()
                pr.isDraft = loads == 1 ? true : false
                return pr
            },
            prReadyMarker: { sent.append($0) }
        )
        await viewModel.refreshPr()
        XCTAssertEqual(viewModel.prDetails?.isDraft, true)

        let ran = try await viewModel.markPrReady()

        XCTAssertTrue(ran)
        XCTAssertEqual(sent, [.session(id: "os-ready")])
        XCTAssertEqual(loads, 2, "the panel's own PR is refetched once")
        XCTAssertEqual(viewModel.prDetails?.isDraft, false)
        XCTAssertEqual(viewModel.session.prIsDraft, false)
        XCTAssertEqual(viewModel.session.prs?.map(\.isDraft), [false, true])
        XCTAssertTrue(viewModel.readyingPrTargets.isEmpty)
    }

    func testAttachedRepoReadyTouchesOnlyThatPr() async throws {
        var sent: [PrReadyTarget] = []
        var loads = 0
        let viewModel = SessionViewModel(
            session: seriesSession(),
            prLoader: { _ in loads += 1; return self.draftPr() },
            prReadyMarker: { sent.append($0) }
        )
        await viewModel.refreshPr()

        try await viewModel.markPrReady(SessionPrTarget(repo: "acme-docs", branch: "feature/docs"))

        XCTAssertEqual(sent, [.session(id: "os-ready", repo: "acme-docs", branch: "feature/docs")])
        XCTAssertEqual(loads, 1, "another PR's action must not refetch the panel's PR")
        XCTAssertEqual(viewModel.prDetails?.isDraft, true)
        XCTAssertEqual(viewModel.session.prIsDraft, true)
        XCTAssertEqual(viewModel.session.prs?.map(\.isDraft), [true, false])
        XCTAssertEqual(SessionPrSeries.rows(for: viewModel.session).map(\.state), ["Draft", "Open"])
    }

    func testFailureKeepsDraftStateAndSurfacesTheServerSentence() async {
        var loads = 0
        let viewModel = SessionViewModel(
            session: seriesSession(),
            prLoader: { _ in loads += 1; return self.draftPr() },
            prReadyMarker: { _ in throw OS1API.APIError.server("Connect your GitHub account first") }
        )
        await viewModel.refreshPr()

        do {
            try await viewModel.markPrReady()
            XCTFail("expected the server's refusal")
        } catch {
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "Connect your GitHub account first"
            )
        }
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(viewModel.prDetails?.isDraft, true)
        XCTAssertEqual(viewModel.session.prIsDraft, true)
        XCTAssertEqual(viewModel.session.prs?.map(\.isDraft), [true, true])
        XCTAssertTrue(viewModel.readyingPrTargets.isEmpty, "a failure frees the target for a retry")
    }

    func testRepeatTapWhileInFlightIsDropped() async throws {
        var sent = 0
        var release: CheckedContinuation<Void, Never>?
        let viewModel = SessionViewModel(
            session: seriesSession(),
            prLoader: { _ in nil },
            prReadyMarker: { _ in
                sent += 1
                await withCheckedContinuation { release = $0 }
            }
        )
        let first = Task { try await viewModel.markPrReady() }
        while release == nil { await Task.yield() }
        XCTAssertEqual(
            viewModel.readyingPrTargets,
            [SessionPrTarget(repo: "acme-app", branch: "feature/base")]
        )

        let second = try await viewModel.markPrReady()
        XCTAssertFalse(second)

        release?.resume()
        let firstRan = try await first.value
        XCTAssertTrue(firstRan)
        XCTAssertEqual(sent, 1)
    }
}

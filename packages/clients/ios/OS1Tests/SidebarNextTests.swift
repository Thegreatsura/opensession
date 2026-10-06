import XCTest
@testable import OS1

final class SidebarNextTests: XCTestCase {
    private func row(
        _ id: String,
        running: Bool = false,
        startedBy: String = "Ada",
        archived: Bool = false,
        parent: String? = nil
    ) -> SidebarWorkspace {
        var session = Session(id: "session-\(id)")
        session.isRunning = running
        session.startedBy = startedBy
        session.archived = archived
        session.parentSessionId = parent
        return SidebarWorkspace(
            id: id,
            title: id,
            sessions: [session],
            mainSession: session
        )
    }

    private func draft(_ id: String) -> SidebarWorkspace {
        let workspace = OS1API.WorkspaceSummary(
            id: id,
            name: id,
            repo: nil,
            createdBy: nil,
            createdAt: nil,
            draft: OS1API.WorkspaceDraft(
                text: "Parked prompt",
                updatedAt: "2026-08-20T12:00:00Z",
                by: nil,
                autoName: nil
            )
        )
        return SidebarWorkspace(
            id: id,
            title: id,
            sessions: [],
            mainSession: Session(id: "workspace-draft:\(id)"),
            workspace: workspace
        )
    }

    private func next(
        after current: String,
        in rows: [SidebarWorkspace],
        unread: Set<String>
    ) -> String? {
        SidebarNext.workspace(
            after: current,
            in: rows,
            isMine: { $0.startedBy == "Ada" },
            isUnread: { unread.contains(String($0.id.dropFirst("session-".count))) }
        )?.id
    }

    func testUnreadSettledWorkWinsInRenderedOrder() {
        let rows = [row("current"), row("running", running: true), row("read"), row("ready")]

        XCTAssertEqual(
            next(after: "current", in: rows, unread: ["current", "running", "ready"]),
            "ready"
        )
    }

    func testOnlyYourOwnUnreadWorkJumpsTheQueue() {
        // A teammate's unread row and a review request sit in the sidebar too,
        // but only the viewer's own unread work is a priority destination.
        let rows = [
            row("current"),
            row("teammate", startedBy: "Grace"),
            row("read"),
            row("mine"),
        ]

        XCTAssertEqual(next(after: "current", in: rows, unread: ["teammate", "mine"]), "mine")
    }

    func testWorkersAndArchivedSessionsNeverJumpTheQueue() {
        let rows = [
            row("current"),
            row("plain"),
            row("worker", parent: "session-current"),
            row("closed", archived: true),
        ]

        XCTAssertEqual(next(after: "current", in: rows, unread: ["worker", "closed"]), "plain")
    }

    func testOrdinaryNextStillReachesOtherPeoplesWork() {
        // Nothing of yours is unread: Next is just the following row, whoever
        // owns it.
        let rows = [row("current"), row("teammate", startedBy: "Grace"), row("mine")]

        XCTAssertEqual(next(after: "current", in: rows, unread: ["teammate"]), "teammate")
    }

    func testFallbackWrapsToTheNextChat() {
        let rows = [row("first"), row("middle"), row("current")]

        XCTAssertEqual(next(after: "current", in: rows, unread: []), "first")
    }

    func testPinnedCopiesAndDraftRowsDoNotBecomeExtraChats() {
        let current = row("current")
        let following = row("next")
        let rows = [current, draft("draft"), following, current, following]

        XCTAssertEqual(next(after: "current", in: rows, unread: []), "next")
        XCTAssertNil(next(after: "current", in: [current, current], unread: ["current"]))
    }

    func testAHiddenCurrentRowContinuesIntoWhatIsVisible() {
        let rows = [row("read"), row("ready")]

        XCTAssertEqual(next(after: "hidden", in: rows, unread: ["ready"]), "ready")
    }
}

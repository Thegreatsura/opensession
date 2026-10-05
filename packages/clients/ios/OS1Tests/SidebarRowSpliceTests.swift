import XCTest
@testable import OS1

/// The list's memoized grouping is spliced — not rebuilt — when a session is
/// created, resolved, archived or restored, because a full regroup runs on the
/// main actor inside the body evaluation those mutations publish into (see
/// `SessionsListViewModel.rowsInserting` / `rowsRemoving`).
///
/// These pin the grouping properties that make the splice equivalent to the
/// regroup it replaces: a workspace-less, worktree-less session owns a row nothing
/// else can join, and dropping one session only rearranges its own row.
final class SidebarRowSpliceTests: XCTestCase {
    private func sessions(_ json: String) throws -> [Session] {
        try JSONDecoder().decode([Session].self, from: Data(json.utf8))
    }

    /// A workspace of two sessions, a legacy worktree row, and a lone session.
    private func existingSessions() throws -> [Session] {
        try sessions(
            """
            [{"id":"bks-1","workspaceId":"ws-1","worktreeDir":"/home/u/worktrees/one"},
             {"id":"bks-2","workspaceId":"ws-1","worktreeDir":"/home/u/worktrees/one"},
             {"id":"bks-3","worktreeDir":"/home/u/worktrees/two"},
             {"id":"bks-4"}]
            """
        )
    }

    private func pendingSession(id: String, workspaceId: String? = nil) -> Session {
        Session.optimistic(
            id: id,
            title: "New session",
            repo: "opensession",
            mode: "code",
            model: nil,
            effort: nil,
            speed: .standard,
            startedBy: "Alex",
            workspaceId: workspaceId
        )
    }

    func testPendingSessionOwnsAFreshRowAheadOfTheRest() throws {
        let existing = try existingSessions()
        let pending = pendingSession(id: "pending-1")

        let regrouped = SessionsListViewModel.sidebarWorkspaces(in: [pending] + existing)
        let spliced = SessionsListViewModel.sidebarWorkspaces(in: [pending])
            + SessionsListViewModel.sidebarWorkspaces(in: existing)

        XCTAssertEqual(regrouped, spliced)
        XCTAssertEqual(regrouped.first?.id, "session:pending-1")
    }

    func testResolvedPendingSessionReplacesItsOwnRow() throws {
        let existing = try existingSessions()
        let pending = pendingSession(id: "pending-1")
        let real = pendingSession(id: "bks-new")

        let regrouped = SessionsListViewModel.sidebarWorkspaces(in: [real] + existing)
        let spliced = SessionsListViewModel.sidebarWorkspaces(in: [real])
            + SessionsListViewModel.sidebarWorkspaces(in: [pending] + existing)
                .filter { $0.id != "session:pending-1" }

        XCTAssertEqual(regrouped, spliced)
    }

    /// A session created into an existing workspace joins that row instead, and
    /// the row leads the list — the position a full regroup gives it, since
    /// the new session is the first session the pass walks.
    func testPendingSessionInAWorkspaceJoinsThatRowAndLeads() throws {
        let existing = try existingSessions()
        let pending = pendingSession(id: "pending-1", workspaceId: "ws-1")

        let regrouped = SessionsListViewModel.sidebarWorkspaces(in: [pending] + existing)
        var rows = SessionsListViewModel.sidebarWorkspaces(in: existing)
        let index = try XCTUnwrap(rows.firstIndex { $0.workspaceId == "ws-1" })
        let merged = SessionsListViewModel.sidebarWorkspaces(
            in: [pending] + rows[index].sessions
        )
        rows.remove(at: index)

        XCTAssertEqual(regrouped, merged + rows)
        XCTAssertEqual(regrouped.first?.id, "workspace:ws-1")
        XCTAssertEqual(regrouped.first?.sessions.count, 3)
    }

    func testDroppingASessionOnlyRearrangesItsOwnRow() throws {
        let all = try existingSessions()
        let dropped = "bks-1"

        let regrouped = SessionsListViewModel.sidebarWorkspaces(
            in: all.filter { $0.id != dropped }
        )
        var spliced = SessionsListViewModel.sidebarWorkspaces(in: all)
        let index = try XCTUnwrap(
            spliced.firstIndex { $0.sessions.contains { $0.id == dropped } }
        )
        let remaining = spliced[index].sessions.filter { $0.id != dropped }
        spliced[index] = try XCTUnwrap(
            SessionsListViewModel.sidebarWorkspaces(in: remaining).first
        )

        XCTAssertEqual(regrouped, spliced)
    }

    func testDroppingARowsLastSessionRemovesTheRow() throws {
        let all = try existingSessions()
        let dropped = "bks-4"

        let regrouped = SessionsListViewModel.sidebarWorkspaces(
            in: all.filter { $0.id != dropped }
        )
        let spliced = SessionsListViewModel.sidebarWorkspaces(in: all)
            .filter { $0.id != "session:\(dropped)" }

        XCTAssertEqual(regrouped, spliced)
        XCTAssertTrue(SessionsListViewModel.sidebarWorkspaces(in: []).isEmpty)
    }
}

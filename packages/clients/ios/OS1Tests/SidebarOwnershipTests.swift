import XCTest
@testable import OS1

private func decodeSessions(_ json: String) throws -> [Session] {
    try JSONDecoder().decode([Session].self, from: Data(json.utf8))
}

private func summary(
    _ id: String,
    createdBy: String? = nil,
    collaborators: [String] = []
) -> OS1API.WorkspaceSummary {
    OS1API.WorkspaceSummary(
        id: id,
        name: id,
        repo: nil,
        createdBy: createdBy,
        createdAt: nil,
        draft: nil,
        collaborators: collaborators.map {
            OS1API.WorkspaceCollaborator(name: $0, by: "Ada", at: nil)
        }
    )
}

/// Collaborators file a workspace into their own sidebar, the way the web's
/// `rowHasCollaborator` / `rowIsOwnWork` do.
final class CollaboratorLensTests: XCTestCase {
    private func row(_ json: String) throws -> SidebarWorkspace {
        try XCTUnwrap(SessionsListViewModel.sidebarWorkspaces(in: decodeSessions(json)).first)
    }

    private let grace = PeopleLens(
        names: ["grace", "grace hopper"],
        claims: [],
        collaborators: ["ws-1": ["Grace"]]
    )

    func testWorkspaceDecodesItsCollaborators() throws {
        let json = #"{"workspaces":[{"id":"ws-1","name":"Fix","collaborators":[{"name":"Grace","by":"Ada","at":"2026-09-01T00:00:00Z"}]},{"id":"ws-2","name":"Old"}]}"#
        struct Response: Decodable { let workspaces: [OS1API.WorkspaceSummary] }
        let workspaces = try JSONDecoder().decode(Response.self, from: Data(json.utf8)).workspaces

        XCTAssertEqual(workspaces[0].collaborators?.map(\.name), ["Grace"])
        XCTAssertTrue(workspaces[0].hasCollaborator(" grace "))
        XCTAssertNil(workspaces[1].collaborators)
        XCTAssertEqual(PeopleLens.collaboratorIndex(workspaces), ["ws-1": ["Grace"]])
    }

    func testACollaboratorOwnsTheRowUnderTheirOwnLens() throws {
        let row = try row(#"[{"id":"os-1","workspaceId":"ws-1","startedBy":"Ada"}]"#)

        XCTAssertTrue(grace.owns(row))
        XCTAssertTrue(grace.matches(row, person: SidebarPersonLens.me, agentKey: "agent"))
        XCTAssertFalse(PeopleLens(names: ["grace"], claims: []).owns(row))
    }

    func testATeammateLensIncludesTheirCollaborations() throws {
        let row = try row(#"[{"id":"os-1","workspaceId":"ws-1","startedBy":"Ada"}]"#)
        let viewer = PeopleLens(
            names: ["ada"], claims: [], collaborators: ["ws-1": ["Grace"]]
        )

        XCTAssertTrue(viewer.matches(row, person: "grace", agentKey: "agent"))
        XCTAssertTrue(viewer.matches(row, person: "ada", agentKey: "agent"))
        XCTAssertFalse(viewer.matches(row, person: "linus", agentKey: "agent"))
    }

    func testCollaborationIsOwnWorkSoAReviewRequestIsNotAnAsk() throws {
        let row = try row(
            #"[{"id":"os-1","workspaceId":"ws-1","startedBy":"Ada","prReviewRequested":["grace"]}]"#
        )
        let stranger = PeopleLens(names: ["linus"], claims: [])

        XCTAssertTrue(grace.isOwnWork(row))
        XCTAssertFalse(stranger.isOwnWork(row))
    }

    func testAClaimDoesNotMakeSomeoneElsesWorkYourOwn() throws {
        let row = try row(#"[{"id":"os-1","workspaceId":"ws-9","startedBy":"Ada"}]"#)
        let claimed = PeopleLens(names: ["grace"], claims: ["os-1"])

        XCTAssertTrue(claimed.owns(row))
        XCTAssertFalse(claimed.isOwnWork(row))
    }

    func testCollaboratorChoicesSkipTheCreatorButKeepListedLeavers() {
        XCTAssertEqual(
            WorkspaceCollaborators.choices(
                roster: ["Ada", "Grace", "Linus"],
                listed: ["Grace", "Margaret"],
                creator: "ada"
            ),
            ["Grace", "Linus", "Margaret"]
        )
    }

    func testACollaboratorIsNotOfferedAddToSidebar() throws {
        let session = try decodeSessions(
            #"[{"id":"os-1","workspaceId":"ws-1","startedBy":"Ada"}]"#
        )[0]
        func intent(_ collaborators: [String]) -> SidebarAddition.Intent? {
            SidebarAddition.intent(
                for: session,
                siblings: [session],
                claims: [],
                hidden: false,
                viewerName: "Grace Hopper",
                viewerLogin: "ghopper",
                collaborators: collaborators
            )
        }

        XCTAssertEqual(intent([]), .claim)
        XCTAssertNil(intent(["Grace"]))
        XCTAssertEqual(intent(["Linus"]), .claim)
    }
}

/// The Active section's manual order and its `active-order` ui-pref.
final class ActiveOrderTests: XCTestCase {
    private func rows() throws -> [SidebarWorkspace] {
        SessionsListViewModel.sidebarWorkspaces(in: try decodeSessions(
            """
            [{"id":"a","workspaceId":"a","createdAt":"2026-09-01T00:00:00Z"},
             {"id":"b","workspaceId":"b","createdAt":"2026-09-02T00:00:00Z"},
             {"id":"c","workspaceId":"c","createdAt":"2026-09-03T00:00:00Z"},
             {"id":"solo","createdAt":"2026-09-04T00:00:00Z"}]
            """
        ))
    }

    func testUnplacedRowsLeadNewestFirstThenTheSavedOrder() throws {
        let sorted = ActiveOrder.sort(
            try rows(),
            order: ["workspace:a", "unknown:elsewhere", "workspace:c"]
        )

        XCTAssertEqual(
            sorted.map(SidebarRowKeys.sharedRowKey),
            ["solo", "workspace:b", "workspace:a", "workspace:c"]
        )
    }

    func testAMoveLeadsWithTheSectionAndKeepsUnknownKeys() {
        let saved = ["workspace:x", "workspace:a", "row-from-another-repo"]

        XCTAssertEqual(
            ActiveOrder.place(saved: saved, section: ["workspace:b", "workspace:a"]),
            ["workspace:b", "workspace:a", "workspace:x", "row-from-another-repo"]
        )
    }

    func testOnMoveAndSteppingProduceTheSectionOrder() {
        let keys = ["workspace:a", "workspace:b", "workspace:c"]

        XCTAssertEqual(
            ActiveOrder.moving(keys, from: IndexSet(integer: 2), to: 0),
            ["workspace:c", "workspace:a", "workspace:b"]
        )
        // The Mac's several rows of one workspace move as one key.
        XCTAssertEqual(
            ActiveOrder.moving(["w", "w", "x"], from: IndexSet(integer: 2), to: 0),
            ["x", "w"]
        )
        XCTAssertEqual(
            ActiveOrder.stepping(keys, key: "workspace:b", by: -1),
            ["workspace:b", "workspace:a", "workspace:c"]
        )
        XCTAssertNil(ActiveOrder.stepping(keys, key: "workspace:a", by: -1))
        XCTAssertNil(ActiveOrder.stepping(keys, key: "workspace:c", by: 1))
    }

    func testThePrefIsNormalizedLikeTheWeb() {
        XCTAssertEqual(
            ActiveOrder.decode(#"[" workspace:a ","",7,"workspace:a","wt:/tmp/x"]"#),
            ["workspace:a", "wt:/tmp/x"]
        )
        XCTAssertEqual(ActiveOrder.validated(#"["b","a"]"#), #"["b","a"]"#)
        XCTAssertNil(ActiveOrder.validated("not json"))
        XCTAssertNil(ActiveOrder.validated(nil))
        XCTAssertEqual(ActiveOrder.decode("{}"), [])
    }

    func testAnOverlongOrderKeepsTheFrontThatFits() {
        let keys = (0..<2_000).map { "workspace:\(String(repeating: "x", count: 10))-\($0)" }
        let encoded = ActiveOrder.encode(keys)

        XCTAssertLessThanOrEqual(encoded.count, ActiveOrder.maxChars)
        XCTAssertEqual(ActiveOrder.decode(encoded).first, keys.first)
    }
}

/// Row colours share the tab-colors map under `row:<row key>`.
final class RowColorTests: XCTestCase {
    func testRowEntriesAreReadUnderTheirPrefix() {
        let colors = [
            "row:workspace:ws-1": "green",
            "workspace:ws-1": "red",
            "row:workspace:ws-2": "teal",
        ]

        XCTAssertEqual(RowColorStore.color(forRowKey: "workspace:ws-1", in: colors), .green)
        // A swatch this build does not know reads as none, but stays stored.
        XCTAssertNil(RowColorStore.color(forRowKey: "workspace:ws-2", in: colors))
        XCTAssertEqual(RowColor.allCases.map(\.rawValue), [
            "red", "orange", "yellow", "green", "blue", "purple", "pink",
        ])
    }

    func testLocalIntentLaysOverTheServerMapWithoutDroppingOtherEntries() {
        let merged = RowColorStore.merged(
            ["tab-session": "blue", "row:workspace:a": "red", "row:workspace:b": "pink"],
            pending: ["row:workspace:a": .remove, "row:workspace:c": .set("green")]
        )

        XCTAssertEqual(merged, [
            "tab-session": "blue",
            "row:workspace:b": "pink",
            "row:workspace:c": "green",
        ])
    }

    @MainActor
    func testAppliedMapKeepsTabColoursAndUnknownKeys() {
        let store = RowColorStore()
        store.applyHydrated(["os-1": "red", "row:wt:/tmp/x": "purple", "row:future": "teal"])

        XCTAssertEqual(store.colors.count, 3)
        XCTAssertEqual(store.colors["os-1"], "red")
    }

    func testAMacSessionRowSharesItsWorkspaceKey() {
        var session = Session(id: "os-1")
        session.workspaceId = "ws-1"
        let macRow = SidebarWorkspace(
            id: "session:os-1", title: "t", sessions: [session], mainSession: session
        )
        let solo = SidebarWorkspace(
            id: "session:os-2", title: "t", sessions: [Session(id: "os-2")],
            mainSession: Session(id: "os-2")
        )

        XCTAssertEqual(SidebarRowKeys.sharedRowKey(for: macRow), "workspace:ws-1")
        XCTAssertEqual(SidebarRowKeys.sharedRowKey(for: solo), "os-2")
    }
}

/// Archived search matches every word anywhere, across branch separators.
final class ArchivedSearchTests: XCTestCase {
    private func session(_ json: String) throws -> Session {
        try JSONDecoder().decode(Session.self, from: Data(json.utf8))
    }

    func testWordsMatchAcrossBranchSeparatorsAndFields() throws {
        let row = try session(
            #"{"id":"os-abc123","title":"Count GPUs","branch":"how-many-t4_gpus","repo":"acme/api","workspaceName":"Capacity plan","startedBy":"Ada"}"#
        )

        XCTAssertTrue(ArchivedPresentation.matchesSearch(row, query: "t4 gpus"))
        XCTAssertTrue(ArchivedPresentation.matchesSearch(row, query: "capacity ada"))
        XCTAssertTrue(ArchivedPresentation.matchesSearch(row, query: "how-many t4"))
        XCTAssertTrue(ArchivedPresentation.matchesSearch(row, query: "os-abc123"))
        XCTAssertTrue(ArchivedPresentation.matchesSearch(row, query: "  "))
        XCTAssertFalse(ArchivedPresentation.matchesSearch(row, query: "capacity grace"))
    }

    func testAnAutomationNameFindsItsRuns() throws {
        let row = try session(#"{"id":"os-1","title":"Nightly","automation":"docs-sync"}"#)

        XCTAssertTrue(ArchivedPresentation.matchesSearch(row, query: "docs sync"))
    }
}

/// PR review runs stay out of the tab strip unless they are the open session.
final class ReviewTabProjectionTests: XCTestCase {
    func testReviewRunsTakeNoTabUnlessOpenedDirectly() throws {
        let sessions = try decodeSessions(
            """
            [{"id":"main","workspaceId":"ws","createdAt":"2026-09-01T00:00:00Z"},
             {"id":"bks-ghpr-acme-api-42-review","workspaceId":"ws","createdAt":"2026-09-02T00:00:00Z"},
             {"id":"bks-ghpr-acme-api-42-adversarial","workspaceId":"ws","createdAt":"2026-09-03T00:00:00Z"},
             {"id":"bks-ghpr-acme-api-42-autofix","workspaceId":"ws","createdAt":"2026-09-04T00:00:00Z"},
             {"id":"sibling","workspaceId":"ws","createdAt":"2026-09-05T00:00:00Z"}]
            """
        )

        XCTAssertEqual(
            SessionsListViewModel.tabSessions(in: sessions, containing: sessions[0]).map(\.id),
            ["main", "bks-ghpr-acme-api-42-autofix", "sibling"]
        )
        XCTAssertEqual(
            SessionsListViewModel.tabSessions(in: sessions, containing: sessions[1]).map(\.id),
            ["main", "bks-ghpr-acme-api-42-review", "bks-ghpr-acme-api-42-autofix", "sibling"]
        )
    }

    func testReviewRunIdsFollowTheWebPattern() {
        XCTAssertTrue(SessionsListViewModel.isPrReviewSession(Session(id: "bks-ghpr-x-review")))
        XCTAssertTrue(SessionsListViewModel.isPrReviewSession(Session(id: "bks-ghpr-x-adversarial")))
        XCTAssertFalse(SessionsListViewModel.isPrReviewSession(Session(id: "bks-ghpr--review")))
        XCTAssertFalse(SessionsListViewModel.isPrReviewSession(Session(id: "bks-ghpr-x-reviewer")))
        XCTAssertFalse(SessionsListViewModel.isPrReviewSession(Session(id: "os-review")))
    }
}

#if os(macOS)
/// The Mac palette offers archived workspaces and sessions, below live work.
final class CommandPaletteArchiveTests: XCTestCase {
    private func archived() throws -> [Session] {
        try decodeSessions(
            """
            [{"id":"os-1","title":"Capacity plan","workspaceId":"ws-old","workspaceName":"Capacity plan","archived":true,"lastActivity":"2026-09-01T00:00:00Z"},
             {"id":"os-2","title":"Count GPUs","workspaceId":"ws-old","workspaceName":"Capacity plan","archived":true,"lastActivity":"2026-09-03T00:00:00Z"},
             {"id":"os-3","title":"Capacity follow-up","workspaceId":"ws-live","workspaceName":"Live work","archived":true,"lastActivity":"2026-09-02T00:00:00Z"}]
            """
        )
    }

    func testArchivedWorkspacesAndUncoveredSessionsBecomeEntries() throws {
        let entries = CommandPaletteArchive.entries(
            archived: try archived(),
            liveWorkspaceIds: ["ws-live"],
            workspaceNames: [:]
        )

        XCTAssertEqual(entries.filter(\.searchable).map(\.id), [
            "archived-workspace:ws-old",
            "archived:os-2",
            "archived:os-3",
        ])
        XCTAssertTrue(entries.allSatisfy { $0.kind == .archived })
        // The session its same-named workspace row covers stays reachable by
        // a conversation hit, mapped to its own session.
        let covered = entries.first { $0.id == "archived:os-1" }
        XCTAssertEqual(covered?.searchable, false)
        XCTAssertEqual(covered?.sessionId, "os-1")
        XCTAssertEqual(CommandPaletteArchive.target(for: "archived:os-1", in: try archived()), .session("os-1"))
    }

    func testArchivedRowsNeedAQueryAndRankBelowLiveSessions() throws {
        let live = CommandPaletteEntry(
            id: "session:live", title: "Capacity dashboard", kind: .session, recency: .distantPast
        )
        let entries = [live] + CommandPaletteArchive.entries(
            archived: try archived(), liveWorkspaceIds: [], workspaceNames: [:]
        )

        XCTAssertEqual(
            CommandPaletteRanking.results(entries, query: "").map(\.id),
            ["session:live"]
        )
        let ranked = CommandPaletteRanking.results(entries, query: "capacity").map(\.id)
        XCTAssertEqual(ranked.first, "session:live")
        XCTAssertTrue(ranked.contains("archived-workspace:ws-old"))
    }

    func testAWorkspaceResultOpensItsNewestSession() throws {
        let list = try archived()

        XCTAssertEqual(
            CommandPaletteArchive.target(for: "archived-workspace:ws-old", in: list),
            .session("os-2")
        )
        XCTAssertEqual(CommandPaletteArchive.target(for: "archived:os-3", in: list), .session("os-3"))
        XCTAssertNil(CommandPaletteArchive.target(for: "archived:gone", in: list))
    }
}
#endif

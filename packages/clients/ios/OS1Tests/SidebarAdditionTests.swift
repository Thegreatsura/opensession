import XCTest
@testable import OS1

final class SidebarAdditionTests: XCTestCase {
    private func session(_ json: String) throws -> Session {
        try JSONDecoder().decode(Session.self, from: Data(json.utf8))
    }

    private func lens(
        claims: Set<String> = [],
        mentions: Set<String> = [],
        collaborators: [String: [String]] = [:]
    ) -> PeopleLens {
        PeopleLens(
            names: ["kent de bruin", "kent", "kentdebruin"],
            claims: claims,
            mentions: mentions,
            collaborators: collaborators,
            viewerName: "Kent de Bruin",
            viewerLogin: "kentdebruin"
        )
    }

    private func row(_ sessions: [Session]) -> SidebarWorkspace {
        SidebarAddition.row(for: sessions[0], siblings: sessions)
    }

    /// One table for the row menu (`PeopleLens.membership`) and the open
    /// session's Add to sidebar entry (`SidebarAddition.intent`): the two
    /// must never disagree about whether a row is already yours.
    func testMembershipTable() throws {
        let teammate = #"{"id":"team","workspaceId":"ws","startedBy":"Michiel"}"#
        struct Case {
            let name: String
            let sessions: [String]
            var claims: Set<String> = []
            var mentions: Set<String> = []
            var collaborators: [String: [String]] = [:]
            var hidden = false
            let membership: SidebarMembership
            let intent: SidebarAddition.Intent?
        }
        let cases: [Case] = [
            Case(name: "owned", sessions: [#"{"id":"mine","startedBy":"Kent"}"#],
                 membership: .hide, intent: nil),
            Case(name: "owned by login prefix",
                 sessions: [#"{"id":"mine","startedBy":"kentdebruin-laptop"}"#],
                 membership: .hide, intent: nil),
            Case(name: "owned sibling covers the row",
                 sessions: [teammate, #"{"id":"mine","workspaceId":"ws","startedBy":"Kent"}"#],
                 membership: .hide, intent: nil),
            Case(name: "spawned by the viewer",
                 sessions: [#"{"id":"child","startedBy":"Kent","spawnedBy":"parent"}"#],
                 membership: .hide, intent: nil),
            Case(name: "collaborated", sessions: [teammate],
                 collaborators: ["ws": ["Kent"]],
                 membership: .hide, intent: nil),
            Case(name: "mentioned", sessions: [teammate], mentions: ["team"],
                 membership: .hide, intent: nil),
            Case(name: "claimed", sessions: [teammate], claims: ["team"],
                 membership: .hide, intent: nil),
            Case(name: "claimed automation run",
                 sessions: [#"{"id":"auto","startedBy":"Kent","automation":"triage"}"#],
                 claims: ["auto"], membership: .hide, intent: nil),
            Case(name: "hidden teammate row", sessions: [teammate], claims: ["team"],
                 hidden: true, membership: .restore, intent: .restore),
            Case(name: "hidden own row", sessions: [#"{"id":"mine","startedBy":"Kent"}"#],
                 hidden: true, membership: .restore, intent: .restore),
            Case(name: "unkept teammate row", sessions: [teammate],
                 collaborators: ["ws": ["Linus"]],
                 membership: .keep, intent: .claim),
            Case(name: "unkept automation run",
                 sessions: [#"{"id":"auto","startedBy":"Kent","automation":"triage"}"#],
                 membership: .keep, intent: .claim),
            Case(name: "mention of someone else's session", sessions: [teammate],
                 mentions: ["other"], membership: .keep, intent: .claim),
        ]
        for test in cases {
            let sessions = try test.sessions.map(session)
            let lens = lens(
                claims: test.claims,
                mentions: test.mentions,
                collaborators: test.collaborators
            )
            XCTAssertEqual(
                lens.membership(of: row(sessions), hidden: test.hidden),
                test.membership,
                test.name
            )
            XCTAssertEqual(
                SidebarAddition.intent(
                    for: sessions[0],
                    siblings: sessions,
                    lens: lens,
                    hidden: test.hidden
                ),
                test.intent,
                test.name
            )
        }
    }

    func testMembershipMatchesTheMeLens() throws {
        let rows = try [
            [#"{"id":"a","startedBy":"Kent","spawnedBy":"p"}"#],
            [#"{"id":"b","startedBy":"Michiel"}"#],
        ].map { try row($0.map(session)) }
        let lens = lens()
        for row in rows {
            XCTAssertEqual(
                lens.membership(of: row, hidden: false) == .hide,
                lens.matches(row, person: SidebarPersonLens.me, agentKey: "agent")
            )
        }
    }

    func testArchivedSessionOffersNothing() throws {
        let archived = try session(#"{"id":"old","startedBy":"Michiel","archived":true}"#)
        XCTAssertNil(SidebarAddition.intent(
            for: archived, siblings: [archived], lens: lens(), hidden: true
        ))
    }

    func testOpenSessionMissingFromItsSiblingsStillCounts() throws {
        let child = try session(#"{"id":"child","startedBy":"Kent","spawnedBy":"parent"}"#)
        let parent = try session(#"{"id":"parent","startedBy":"Michiel"}"#)
        XCTAssertEqual(
            SidebarAddition.row(for: child, siblings: [parent]).sessions.map(\.id),
            ["child", "parent"]
        )
        XCTAssertNil(SidebarAddition.intent(
            for: child, siblings: [parent], lens: lens(), hidden: false
        ))
    }
}

/// A Mac row is one session, but the web hides the whole workspace row, so
/// a hide or restore from either client must read and write the same key.
@MainActor
final class SessionRowHideTests: XCTestCase {
    private func macRow() throws -> SidebarWorkspace {
        let session = try JSONDecoder().decode(
            Session.self,
            from: Data(#"{"id":"s1","workspaceId":"ws","startedBy":"Kent"}"#.utf8)
        )
        return SidebarWorkspace(
            id: "session:s1", title: "", sessions: [session], mainSession: session
        )
    }

    func testMacSessionRowHidesUnderTheWorkspaceKey() throws {
        let row = try macRow()
        XCTAssertEqual(SidebarRowKeys.hideKeys(for: row), ["s1", "workspace:ws"])

        let store = HideStore()
        store.applyHydrated([:], persist: false)
        store.hide(row)
        XCTAssertEqual(Array(store.hides.keys), ["workspace:ws"])
        XCTAssertTrue(store.isHidden(row))

        store.restore(row)
        XCTAssertFalse(store.isHidden(row))
    }

    func testAWebHideCoversTheMacRow() throws {
        let store = HideStore()
        store.applyHydrated(["workspace:ws": "2026-10-01T00:00:00Z"], persist: false)
        XCTAssertTrue(store.isHidden(try macRow()))
    }
}

@MainActor
final class LaneStoreWriteTests: XCTestCase {
    func testPreHydrationClaimIsReplayedOverRemoteState() {
        let store = LaneStore()
        store.claim([Session(id: "local")])

        store.applyHydrated(["remote": "review"], persist: false)

        XCTAssertEqual(store.claims, ["local", "remote"])
    }

    func testWriteResponseAcknowledgesOnlyCapturedChanges() {
        let store = LaneStore()
        store.claim([Session(id: "first"), Session(id: "later")])
        store.applyHydrated([:], persist: false)

        store.applySaved(
            ["first": "mine", "remote": "pending"],
            acknowledging: ["first": "mine"]
        )

        XCTAssertEqual(store.claims, ["first", "later", "remote"])
    }
}

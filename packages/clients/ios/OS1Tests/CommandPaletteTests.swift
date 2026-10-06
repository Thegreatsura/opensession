import XCTest
@testable import OS1

final class CommandPaletteTests: XCTestCase {
    private func command(_ id: String, _ title: String, keywords: [String] = [])
        -> CommandPaletteEntry {
        CommandPaletteEntry(id: id, title: title, keywords: keywords, kind: .command)
    }

    private func session(
        _ id: String,
        _ title: String,
        keywords: [String] = [],
        minutesAgo: Int = 0
    ) -> CommandPaletteEntry {
        CommandPaletteEntry(
            id: id,
            title: title,
            keywords: keywords,
            kind: .session,
            recency: Date(timeIntervalSince1970: 1_800_000_000 - Double(minutesAgo) * 60)
        )
    }

    private func ids(
        _ entries: [CommandPaletteEntry], _ query: String, limit: Int = 40
    ) -> [String] {
        CommandPaletteRanking.results(entries, query: query, sessionLimit: limit)
            .map(\.id)
    }

    func testEmptyQueryKeepsCommandsInOrderAndSessionsByRecency() {
        let entries = [
            command("new", "New session"),
            command("desk", "Open the Desk"),
            session("old", "An older conversation", minutesAgo: 900),
            session("fresh", "Just now", minutesAgo: 1)
        ]
        XCTAssertEqual(ids(entries, ""), ["new", "desk", "fresh", "old"])
        XCTAssertEqual(ids(entries, "   "), ["new", "desk", "fresh", "old"])
    }

    func testEveryTokenHasToMatch() {
        let entries = [session("a", "Fix the sidebar hover wash")]
        XCTAssertEqual(ids(entries, "sidebar hover"), ["a"])
        XCTAssertEqual(ids(entries, "sidebar composer"), [])
    }

    func testATokenCanMatchAcrossTitleAndKeywords() {
        let entries = [session("a", "Fix the hover wash", keywords: ["tella-fusion"])]
        XCTAssertEqual(ids(entries, "hover fusion"), ["a"])
    }

    func testTitleStartBeatsAWordInsideBeatsAKeyword() {
        let entries = [
            session("keyword", "Something else", keywords: ["archive"]),
            session("inside", "Rewrite the archive sweep"),
            session("prefix", "Archive the stale rows")
        ]
        XCTAssertEqual(ids(entries, "archive"), ["prefix", "inside", "keyword"])
    }

    func testAWordBoundaryBeatsAMatchInsideAWord() {
        let entries = [
            session("inner", "Unarchived rows keep their lane"),
            session("boundary", "Sweep the archive index")
        ]
        XCTAssertEqual(ids(entries, "archive"), ["boundary", "inner"])
    }

    func testCommandsRankAboveSessionsEvenOnAWeakerMatch() {
        let entries = [
            session("session", "Archived rows that need a sweep"),
            command("archived", "Archived sessions", keywords: ["closed"])
        ]
        XCTAssertEqual(ids(entries, "archived"), ["archived", "session"])
    }

    func testMatchingIgnoresCaseAndAccents() {
        let entries = [session("a", "Café deploy checklist")]
        XCTAssertEqual(ids(entries, "CAFE"), ["a"])
        XCTAssertEqual(ids(entries, "café"), ["a"])
    }

    func testASessionIsFoundByItsRepoOrBranch() {
        let entries = [
            session(
                "a",
                "Stop the composer repainting",
                keywords: ["opensession", "fix-composer-repaint", "Michiel"]
            )
        ]
        XCTAssertEqual(ids(entries, "opensession"), ["a"])
        XCTAssertEqual(ids(entries, "repaint michiel"), ["a"])
    }

    func testTheSessionLimitNeverDropsACommand() {
        var entries = [command("new", "New session")]
        for index in 0..<60 {
            entries.append(session("s\(index)", "Session \(index)", minutesAgo: index))
        }
        let results = ids(entries, "", limit: 5)
        XCTAssertEqual(results.count, 6)
        XCTAssertEqual(results.first, "new")
        // The five kept sessions are the five most recent, newest first.
        XCTAssertEqual(Array(results.dropFirst()), ["s0", "s1", "s2", "s3", "s4"])
    }

    private func hits(_ ids: String...) -> [CommandPaletteConversationHit] {
        ids.map { CommandPaletteConversationHit(sessionId: $0, snippet: "…\($0) snippet…") }
    }

    private func archivedSession(
        _ id: String, _ title: String, minutesAgo: Int = 0, searchable: Bool = true
    ) -> CommandPaletteEntry {
        CommandPaletteEntry(
            id: "archived:\(id)",
            title: title,
            symbol: "archivebox",
            kind: .archived,
            recency: Date(timeIntervalSince1970: 1_800_000_000 - Double(minutesAgo) * 60),
            sessionId: id,
            searchable: searchable
        )
    }

    private func liveSession(_ id: String, _ title: String, minutesAgo: Int = 0)
        -> CommandPaletteEntry {
        var entry = session("session:\(id)", title, minutesAgo: minutesAgo)
        entry.sessionId = id
        return entry
    }

    func testTranscriptOnlyMatchRanksAfterMetadataMatch() {
        let entries = [
            liveSession("content", "Unrelated recent session", minutesAgo: 1),
            liveSession("metadata", "Fix transcript search", minutesAgo: 20),
            command("new", "New session")
        ]
        let results = CommandPaletteRanking.results(
            entries,
            query: "transcript",
            conversationHits: hits("content")
        )
        XCTAssertEqual(results.map(\.id), ["session:metadata", "session:content"])
        XCTAssertNil(results[0].section)
        XCTAssertEqual(results[1].section, .conversations)
        XCTAssertEqual(results[1].subtitle, "…content snippet…")
    }

    func testTranscriptMatchDoesNotAdmitACommand() {
        var entry = command("command", "Unrelated command")
        entry.sessionId = "command"
        XCTAssertTrue(CommandPaletteRanking.results(
            [entry],
            query: "needle",
            conversationHits: hits("command")
        ).isEmpty)
    }

    /// The bug the web fixed in the same way: a strong archived conversation
    /// match sat below every passing live mention, sorted by recency.
    func testAnArchivedConversationHitKeepsTheServersRankAboveRecentLiveHits() {
        var entries = (0..<30).map { liveSession("live\($0)", "Live work \($0)", minutesAgo: $0) }
        entries.append(liveSession("named", "Pi Durable rollout", minutesAgo: 500))
        entries.append(archivedSession("best", "Old investigation", minutesAgo: 90_000))
        entries.append(archivedSession("titled", "pi_durable notes", minutesAgo: 80_000))
        // The server ranked the archived session first, then the live ones.
        let serverOrder = ["best"] + (0..<30).map { "live\($0)" }
        let results = CommandPaletteRanking.results(
            entries,
            query: "pi-durable",
            conversationHits: serverOrder.map {
                CommandPaletteConversationHit(sessionId: $0, snippet: "…\($0)…")
            }
        )
        let ids = results.map(\.id)
        // Live title match, then conversations in server order, then the
        // archived title match.
        XCTAssertEqual(ids.first, "session:named")
        XCTAssertEqual(ids[1], "archived:best")
        XCTAssertEqual(results[1].section, .conversations)
        XCTAssertEqual(results[1].kind, .archived)
        XCTAssertEqual(Array(ids[2..<21]), (0..<19).map { "session:live\($0)" })
        XCTAssertEqual(ids.count, 1 + 20 + 1)
        XCTAssertEqual(ids.last, "archived:titled")
        XCTAssertEqual(results.last?.section, .archived)
    }

    func testAConversationHitIsNotListedTwice() {
        let entries = [
            liveSession("a", "Pi Durable rollout"),
            archivedSession("b", "pi durable archive"),
            archivedSession("c", "Elsewhere"),
        ]
        let results = CommandPaletteRanking.results(
            entries,
            query: "pi-durable",
            conversationHits: hits("a", "b", "c", "c", "gone")
        )
        XCTAssertEqual(results.map(\.id), ["session:a", "archived:c", "archived:b"])
        XCTAssertEqual(results.map(\.section), [nil, .conversations, .archived])
    }

    func testAnUnsearchableArchivedRowOnlyAnswersAConversationHit() {
        let entries = [archivedSession("covered", "Capacity plan", searchable: false)]
        XCTAssertTrue(CommandPaletteRanking.results(entries, query: "capacity").isEmpty)
        XCTAssertEqual(
            CommandPaletteRanking.results(
                entries, query: "capacity", conversationHits: hits("covered")
            ).map(\.id),
            ["archived:covered"]
        )
    }

    func testConversationHitsNeedAQuery() {
        let entries = [liveSession("a", "Anything")]
        XCTAssertEqual(
            CommandPaletteRanking.results(entries, query: "", conversationHits: hits("a"))
                .map(\.section),
            [nil]
        )
    }

    func testATypoStillFindsTheRow() {
        let entries = [
            session("release", "Release notes"),
            command("workspace", "New session in this workspace")
        ]
        XCTAssertEqual(ids(entries, "relase"), ["release"])
        XCTAssertEqual(ids(entries, "wrokspace"), ["workspace"])
    }

    func testAnExactTitleOutranksATypoOutranksAKeyword() {
        let entries = [
            session("keyword", "Something else", keywords: ["release"]),
            session("typo", "Relase notes"),
            session("exact", "Release notes")
        ]
        XCTAssertEqual(ids(entries, "release"), ["exact", "typo", "keyword"])
    }

    func testShortTermsStayStrict() {
        XCTAssertEqual(ids([session("a", "Cut the rows")], "cat"), [])
    }

    func testNoMatchesReturnsNothingRatherThanEverything() {
        let entries = [command("new", "New session"), session("a", "A conversation")]
        XCTAssertEqual(ids(entries, "zzzz"), [])
    }
}

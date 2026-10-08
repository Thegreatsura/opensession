import XCTest
@testable import OS1

final class SlackMentionsTests: XCTestCase {
    private let alex = SlackMentionUser(id: "UALEX01", name: "Alex Kim")
    private let alexToo = SlackMentionUser(id: "UALEX02", name: "Alex Kim", realName: "Alexandra Kim")
    private let sam = SlackMentionUser(id: "USAM001", name: "Sam")

    private func length(_ text: String) -> Int { (text as NSString).length }

    private func picking(_ user: SlackMentionUser, typing typed: String, into draft: inout SlackMentionDraft) {
        draft.edit(to: draft.text + typed)
        let trigger = draft.trigger(caret: draft.length)
        XCTAssertNotNil(trigger, "no picker for \(typed)")
        guard let trigger else { return }
        let caret = draft.pick(user, replacing: trigger.range)
        XCTAssertEqual(caret, draft.length)
    }

    func testDecodesKnownTokensAndKeepsUnknownOnes() {
        let draft = SlackMentionDraft(
            encoded: "Thanks <@UALEX01|alex> and <@UNOBODY1> & <#C1|x>",
            users: [alex]
        )
        XCTAssertEqual(draft.text, "Thanks @Alex Kim and <@UNOBODY1> & <#C1|x>")
        XCTAssertEqual(draft.encoded, "Thanks <@UALEX01> and <@UNOBODY1> & <#C1|x>")
    }

    func testPickWritesNameAndEncodesToken() {
        var draft = SlackMentionDraft(encoded: "Ping ")
        picking(alex, typing: "@al", into: &draft)
        XCTAssertEqual(draft.text, "Ping @Alex Kim ")
        XCTAssertEqual(draft.encoded, "Ping <@UALEX01> ")
        // The picked name is not a search any more.
        XCTAssertNil(draft.trigger(caret: draft.length))
        XCTAssertNil(draft.trigger(caret: length("Ping @Alex")))
    }

    func testTriggerRulesMatchTheWeb() {
        let draft = SlackMentionDraft(encoded: "mail a@b and @jamie riv\n@x")
        XCTAssertNil(draft.trigger(caret: length("mail a@b")))
        XCTAssertEqual(draft.trigger(caret: length("mail a@b and @jamie riv"))?.query, "jamie riv")
        XCTAssertEqual(draft.trigger(caret: draft.length)?.query, "x")
        XCTAssertNil(SlackMentionDraft(encoded: "<@U1234>").trigger(caret: 3))
    }

    func testDuplicateNamesKeepTheirOwnIds() {
        var draft = SlackMentionDraft(encoded: "")
        picking(alex, typing: "@alex", into: &draft)
        picking(alexToo, typing: "and @alexandra", into: &draft)
        XCTAssertEqual(draft.text, "@Alex Kim and @Alex Kim ")
        XCTAssertEqual(draft.encoded, "<@UALEX01> and <@UALEX02> ")
    }

    func testEditsAroundMentionsMoveThem() {
        var draft = SlackMentionDraft(encoded: "hi <@UALEX01> and <@USAM001>", users: [alex, sam])
        draft.edit(to: "Oh hi @Alex Kim and @Sam")
        XCTAssertEqual(draft.encoded, "Oh hi <@UALEX01> and <@USAM001>")
        // One keystroke is one edit.
        draft.edit(to: "Oh hi @Alex Kim, and @Sam")
        draft.edit(to: "Oh hi @Alex Kim, and @Sam!")
        XCTAssertEqual(draft.encoded, "Oh hi <@UALEX01>, and <@USAM001>!")
    }

    func testEditingInsideOrDeletingANameMakesItPlainText() {
        var draft = SlackMentionDraft(encoded: "<@UALEX01> <@USAM001>", users: [alex, sam])
        draft.edit(to: "@Alex Ki @Sam")
        XCTAssertEqual(draft.encoded, "@Alex Ki <@USAM001>")
        draft.edit(to: "@Alex Ki @Samuel")
        XCTAssertEqual(draft.encoded, "@Alex Ki @Samuel")
        draft.edit(to: "")
        XCTAssertTrue(draft.mentions.isEmpty)
    }

    func testTypingStraightAfterANameRunsItOn() {
        var draft = SlackMentionDraft(encoded: "<@USAM001>", users: [sam])
        draft.edit(to: "@Sam's")
        XCTAssertEqual(draft.encoded, "<@USAM001>'s")
        draft.edit(to: "@Samx's")
        XCTAssertEqual(draft.encoded, "@Samx's")
    }

    func testLateRosterResolvesInPlaceKeepingEditsAndCaret() {
        var draft = SlackMentionDraft(encoded: "Hey <@UALEX01>, see <@UGONE01>")
        XCTAssertEqual(draft.text, "Hey <@UALEX01>, see <@UGONE01>")
        // The person types before the roster lands.
        draft.edit(to: "Hey <@UALEX01>, see <@UGONE01> soon")
        let caret = draft.length
        let rewrites = draft.resolve(users: [alex, sam])
        XCTAssertEqual(draft.text, "Hey @Alex Kim, see <@UGONE01> soon")
        XCTAssertEqual(draft.encoded, "Hey <@UALEX01>, see <@UGONE01> soon")
        XCTAssertEqual(SlackMentionDraft.adjust(caret, by: rewrites), draft.length)
        XCTAssertEqual(SlackMentionDraft.adjust(2, by: rewrites), 2)
        // A caret inside the raw token lands after the name.
        XCTAssertEqual(SlackMentionDraft.adjust(7, by: rewrites), length("Hey @Alex Kim"))
        // Resolving again changes nothing.
        XCTAssertEqual(draft.resolve(users: [alex]), [])
    }

    func testLengthLimitCountsShownTextAndTrimsOnlyTheInsertion() {
        var draft = SlackMentionDraft(encoded: String(repeating: "a", count: 495))
        let end = draft.edit(to: draft.text + "bcdefghij")
        XCTAssertEqual(draft.length, 500)
        XCTAssertEqual(end, 500)
        XCTAssertTrue(draft.text.hasSuffix("abcdef"))
        // An emoji is never split.
        var near = SlackMentionDraft(encoded: String(repeating: "a", count: 499))
        near.edit(to: near.text + "👋")
        XCTAssertEqual(near.length, 499)
        // A pick that would not fit is refused.
        var full = SlackMentionDraft(encoded: String(repeating: "a", count: 495) + " @al")
        XCTAssertNil(full.pick(alex, replacing: full.trigger(caret: full.length)!.range))
        XCTAssertEqual(full.length, 499)
    }

    func testResolvedNamesPastTheLimitStayButCannotGrow() {
        let long = SlackMentionUser(id: "ULONG01", name: String(repeating: "N", count: 40))
        let encoded = String(repeating: "a", count: 480) + " <@ULONG01>"
        var draft = SlackMentionDraft(encoded: encoded, users: [long])
        XCTAssertGreaterThan(draft.length, 500)
        let before = draft.text
        draft.edit(to: draft.text + "x")
        XCTAssertEqual(draft.text, before)
        draft.edit(to: String(draft.text.dropFirst()))
        XCTAssertEqual(draft.encoded, String(repeating: "a", count: 479) + " <@ULONG01>")
    }

    func testDraftRoundTripsThroughTheSavedRequest() throws {
        var draft = SlackMentionDraft(encoded: "Shipped, thanks ")
        picking(alexToo, typing: "@alexandra", into: &draft)
        let connection = ServerConnection(
            accountID: "work",
            baseURL: URL(string: "https://example.test")!,
            token: "token"
        )
        let request = try SlackAPI.composerDraftRequest(
            connection: connection,
            sessionId: "os-1",
            requestId: "r-1",
            channelId: "C1",
            message: draft.encoded,
            screenshots: []
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let saved = try XCTUnwrap(json["message"] as? String)
        XCTAssertEqual(saved, "Shipped, thanks <@UALEX02> ")

        let reopened = SlackMentionDraft(encoded: saved, users: [alex, alexToo])
        XCTAssertEqual(reopened.text, "Shipped, thanks @Alex Kim ")
        XCTAssertEqual(reopened.encoded, saved)
    }

    func testMatchesRankByNameAndRealName() {
        let users = [alex, alexToo, sam]
        XCTAssertEqual(SlackMentionDraft.matches("", in: users).count, 3)
        XCTAssertEqual(SlackMentionDraft.matches("sam", in: users).first, sam)
        XCTAssertEqual(SlackMentionDraft.matches("alexandra", in: users).first, alexToo)
        XCTAssertTrue(SlackMentionDraft.matches("zzzz", in: users).isEmpty)
    }

    func testDecodesTheRosterShape() throws {
        let data = Data(#"[{"id":"U1A","name":"Alex","realName":"Alex K","image":"https://example.test/a.png"},{"id":"U2B","name":"Sam"}]"#.utf8)
        let users = try JSONDecoder().decode([SlackMentionUser].self, from: data)
        XCTAssertEqual(users.map(\.id), ["U1A", "U2B"])
        XCTAssertNil(users[1].realName)
    }
}

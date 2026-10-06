import XCTest
@testable import OS1

/// Comment threads on a session: wire decoding, live frames and their echoes,
/// anchors, thread links, unsent drafts and the composer's quote lines.
@MainActor
final class CommentThreadTests: XCTestCase {
    private func decode(_ json: String) throws -> CommentThread {
        try JSONDecoder().decode(CommentThread.self, from: Data(json.utf8))
    }

    private func thread(
        _ id: String = "th-1",
        anchor: TextAnchor? = nil,
        status: CommentThread.Status = .open,
        updatedAt: Double = 2_000,
        replies: Int = 0,
        ts: Double = 1_000
    ) -> CommentThread {
        var comments = [ThreadComment(id: id, user: "Ada", text: "Is this right?", ts: ts)]
        for index in 0..<replies {
            comments.append(ThreadComment(id: "\(id)-r\(index)", user: "Grace", text: "Reply \(index)", ts: ts + Double(index + 1)))
        }
        return CommentThread(
            id: id,
            sessionId: "bks-1",
            anchor: anchor,
            status: status,
            createdBy: "Ada",
            ts: ts,
            updatedAt: updatedAt,
            comments: comments
        )
    }

    // MARK: - Decoding

    func testAnAnchoredThreadDecodesWithRepliesAssigneeAndAgentAnswer() throws {
        let decoded = try decode(#"""
        {"id":"th-1","sessionId":"bks-1","status":"resolved","createdBy":"Ada","ts":1000,"updatedAt":3000,
         "resolvedBy":"Grace","resolvedAt":3000,"assignee":"Grace","assigneeTodoId":"todo-1",
         "agentPendingSince":2500,"future":"ignored",
         "anchor":{"entryId":"e-7","exact":"Tests pass.","prefix":"Sunday. ","suffix":" Run"},
         "comments":[
           {"id":"th-1","user":"Ada","text":"Why?","ts":1000,"images":["/media?path=a.png"]},
           {"id":"c-2","user":"Opie","text":"Because **this**.","ts":2000,"agent":true,"editedAt":2100}
         ]}
        """#)
        XCTAssertEqual(decoded.anchor, TextAnchor(entryId: "e-7", exact: "Tests pass.", prefix: "Sunday. ", suffix: " Run"))
        XCTAssertEqual(decoded.status, .resolved)
        XCTAssertEqual(decoded.resolvedBy, "Grace")
        XCTAssertEqual(decoded.assignee, "Grace")
        XCTAssertEqual(decoded.comments.count, 2)
        XCTAssertEqual(decoded.root.images, ["/media?path=a.png"])
        XCTAssertTrue(decoded.comments[1].agent)
        XCTAssertEqual(decoded.comments[1].editedAt, 2100)
        XCTAssertEqual(decoded.agentName, "Opie")
        XCTAssertEqual(decoded.replyCount, 1)
        XCTAssertFalse(decoded.legacy)
    }

    func testDecodingIsTolerant() throws {
        // A comment of the wrong shape drops itself, not the thread; missing
        // fields fall back to the opening comment; an unknown status is open.
        let decoded = try decode(#"""
        {"id":"th-2","status":"archived","comments":[{"id":"c-1","user":"Ada","text":"Hi","ts":5},{"user":"no id"}]}
        """#)
        XCTAssertEqual(decoded.status, .open)
        XCTAssertEqual(decoded.createdBy, "Ada")
        XCTAssertEqual(decoded.ts, 5)
        XCTAssertEqual(decoded.updatedAt, 5)
        XCTAssertNil(decoded.anchor)
        XCTAssertEqual(decoded.comments.map(\.id), ["c-1"])

        XCTAssertThrowsError(try decode(#"{"id":"th-3","comments":[]}"#), "a thread is its opening comment")

        let list = try JSONDecoder().decode(OS1API.ThreadList.self, from: Data(#"""
        {"threads":[{"id":"a","comments":[{"id":"a","user":"Ada","text":"x","ts":1}]},{"id":"b"},7]}
        """#.utf8))
        XCTAssertEqual(list.threads.map(\.id), ["a"])
    }

    func testThreadFramesDecodeAndAMalformedThreadIsIgnored() {
        let frame = #"{"type":"comment_thread","sessionId":"bks-1","thread":{"id":"th-1","sessionId":"bks-1","status":"open","createdBy":"Ada","ts":1,"updatedAt":1,"comments":[{"id":"th-1","user":"Ada","text":"Hi","ts":1}]}}"#
        guard case .commentThread(let sessionId, let decoded) = ServerEvent.parse(Data(frame.utf8)) else {
            return XCTFail("expected .commentThread")
        }
        XCTAssertEqual(sessionId, "bks-1")
        XCTAssertEqual(decoded.id, "th-1")

        guard case .commentThreadDeleted(let deletedSession, let threadId) = ServerEvent.parse(
            Data(#"{"type":"comment_thread_deleted","sessionId":"bks-1","threadId":"th-1"}"#.utf8)
        ) else { return XCTFail("expected .commentThreadDeleted") }
        XCTAssertEqual(deletedSession, "bks-1")
        XCTAssertEqual(threadId, "th-1")

        guard case .ignored = ServerEvent.parse(
            Data(#"{"type":"comment_thread","sessionId":"bks-1","thread":{"id":"x","comments":"nope"}}"#.utf8)
        ) else { return XCTFail("a thread this build cannot read is ignored") }
    }

    // MARK: - Echoes and deletion

    func testARequestAndItsEchoLandOnceInEitherOrder() {
        let store = SessionComments()
        let older = thread(updatedAt: 1_000)
        let newer = thread(updatedAt: 2_000, replies: 1)
        XCTAssertTrue(store.apply(newer))
        XCTAssertFalse(store.apply(newer), "the echo of the response is a no-op")
        XCTAssertFalse(store.apply(older), "an older copy never replaces a newer one")
        XCTAssertEqual(store.threads.count, 1)
        XCTAssertEqual(store.threads[0].replyCount, 1)
    }

    func testALegacyNoteEchoNeverDuplicatesItsThread() {
        let store = SessionComments()
        let note = SessionNote(id: "th-1", user: "Ada", text: "Is this right?", ts: 1_000)
        store.apply(thread(replies: 2))
        XCTAssertFalse(store.applyLegacyNote(note, sessionId: "bks-1"))
        XCTAssertEqual(store.threads.count, 1)
        XCTAssertEqual(store.threads[0].replyCount, 2, "the note echo did not strip the replies")

        // Once the server is known to speak threads, notes are always echoes.
        let fresh = SessionComments()
        fresh.merge([], since: fresh.snapshotToken())
        XCTAssertFalse(fresh.applyLegacyNote(note, sessionId: "bks-1"))
        XCTAssertTrue(fresh.threads.isEmpty)

        // An old server only has notes: they show as legacy threads, and the
        // real thread replaces one when it arrives.
        let old = SessionComments()
        old.markUnsupported()
        XCTAssertTrue(old.applyLegacyNote(note, sessionId: "bks-1"))
        XCTAssertTrue(old.threads[0].legacy)
        let unknown = SessionComments()
        XCTAssertTrue(unknown.applyLegacyNote(note, sessionId: "bks-1"))
        XCTAssertTrue(unknown.apply(thread(updatedAt: 500)), "a real thread beats a legacy copy")
        XCTAssertFalse(unknown.threads[0].legacy)
    }

    func testADeletedThreadNeverComesBack() {
        let store = SessionComments()
        let token = store.snapshotToken()
        store.apply(thread())
        store.focus("th-1")
        XCTAssertTrue(store.remove(id: "th-1"))
        XCTAssertNil(store.presentedThreadId, "the sheet closes with its thread")
        XCTAssertFalse(store.apply(thread(updatedAt: 9_000)), "a late echo")
        store.merge([thread()], since: token)
        XCTAssertTrue(store.threads.isEmpty, "a stale snapshot")
        XCTAssertFalse(store.remove(id: "th-1"), "a second delete frame is a no-op")
    }

    func testASnapshotDropsWhatItLacksUnlessAFrameIsNewer() {
        let store = SessionComments()
        store.apply(thread("gone"))
        let token = store.snapshotToken()
        store.apply(thread("live", ts: 3_000))
        store.merge([thread("kept", ts: 2_000)], since: token)
        XCTAssertEqual(store.threads.map(\.id), ["kept", "live"])
        XCTAssertEqual(store.threadsSupported, true)
    }

    func testTimelineAndInlineThreadsSplitByAnchor() {
        let store = SessionComments()
        let anchor = TextAnchor(entryId: "e-1", exact: "Tests pass.")
        store.apply(thread("note"))
        store.apply(thread("inline", anchor: anchor, status: .resolved))
        XCTAssertEqual(store.timelineThreads.map(\.id), ["note"])
        XCTAssertEqual(store.inlineThreads(in: ["e-0", "e-1"]).map(\.id), ["inline"])
        XCTAssertTrue(store.inlineThreads(in: ["e-2"]).isEmpty)
        XCTAssertEqual(store.openCount, 1)
        XCTAssertEqual(CommentThreadFilter.resolved.apply(store.threads, me: "Ada").map(\.id), ["inline"])
    }

    func testTheViewModelRendersOneNoteForAThreadAndItsLegacyEcho() {
        let viewModel = SessionViewModel(session: Session(id: "bks-1"))
        let note = thread("th-9", ts: Date.distantFuture.timeIntervalSince1970 * 1_000)
        viewModel.handle(.commentThread(sessionId: "bks-1", thread: note))
        viewModel.handle(.sessionNote(
            sessionId: "bks-1",
            note: SessionNote(id: "th-9", user: "Ada", text: "Is this right?", ts: note.ts)
        ))
        viewModel.handle(.commentThread(sessionId: "other", thread: thread("elsewhere")))
        XCTAssertEqual(viewModel.displayBlocks.filter { if case .note = $0 { true } else { false } }.count, 1)

        viewModel.handle(.commentThreadDeleted(sessionId: "bks-1", threadId: "th-9"))
        viewModel.handle(.sessionNoteDeleted(sessionId: "bks-1", noteId: "th-9"))
        XCTAssertTrue(viewModel.comments.threads.isEmpty)
        XCTAssertFalse(viewModel.displayBlocks.contains { if case .note = $0 { true } else { false } })
    }

    func testAThreadMapsToTheBlockThatShowsIt() {
        let items = TranscriptGrouping.displayItems(from: [
            TranscriptEntry(id: "a1", type: "assistant", content: "Tests pass.", timestamp: "2026-01-01T00:00:00Z"),
        ])
        let note = thread("n", ts: Date.distantFuture.timeIntervalSince1970 * 1_000)
        let blocks = TranscriptGrouping.blocks(from: items, live: false, worktreeDir: nil, notes: [note])
        XCTAssertEqual(SessionComments.blockId(for: note, in: blocks), "note:n")
        let inline = thread("i", anchor: TextAnchor(entryId: "a1", exact: "Tests pass."))
        XCTAssertEqual(SessionComments.blockId(for: inline, in: blocks), "a1")
        XCTAssertNil(SessionComments.blockId(for: thread("x", anchor: TextAnchor(entryId: "zz", exact: "gone")), in: blocks))
    }

    // MARK: - Anchors (ported from the web's comment-anchor.test.ts)

    private let sample = "Run it on Sunday. Tests pass. Run it on Sunday again later."

    private func offset(_ needle: String, last: Bool = false) -> Int {
        let ns = sample as NSString
        return (last ? ns.range(of: needle, options: .backwards) : ns.range(of: needle)).location
    }

    func testAnAnchorCapturesTheWordsWithContextAndTrimsWhitespace() {
        let start = offset("Tests") - 1
        let anchor = CommentAnchor.anchor(text: sample, range: NSRange(location: start, length: 12), entryId: "e1")
        XCTAssertEqual(anchor, TextAnchor(
            entryId: "e1",
            exact: "Tests pass.",
            prefix: "Run it on Sunday. ",
            suffix: " Run it on Sunday again later."
        ))
        XCTAssertNil(CommentAnchor.anchor(text: sample, range: NSRange(location: 0, length: 1), entryId: "e1"))
        XCTAssertNil(CommentAnchor.anchor(text: "a   b", range: NSRange(location: 1, length: 3), entryId: "e1"))
    }

    func testRepeatedWordsResolveByContext() {
        let second = offset("Run it on Sunday", last: true)
        let later = CommentAnchor.anchor(text: sample, range: NSRange(location: second, length: 16), entryId: "e1")!
        XCTAssertEqual(CommentAnchor.locate(later, in: sample), NSRange(location: second, length: 16))
        let first = CommentAnchor.anchor(text: sample, range: NSRange(location: 0, length: 16), entryId: "e1")!
        XCTAssertEqual(CommentAnchor.locate(first, in: sample), NSRange(location: 0, length: 16))
    }

    func testDriftedContextStillFindsTheWordsAndMissingWordsFindNothing() {
        let drifted = TextAnchor(entryId: "e1", exact: "Tests pass", prefix: "Sunday. ", suffix: ". Run")
        XCTAssertEqual(CommentAnchor.locate(drifted, in: "Now: Tests pass, mostly."), NSRange(location: 5, length: 10))
        XCTAssertNil(CommentAnchor.locate(TextAnchor(entryId: "e1", exact: "Monday"), in: sample))
    }

    func testAnchorsCountUTF16LikeTheWeb() {
        // An emoji is two UTF-16 units in both clients, so context lengths agree.
        let text = String(repeating: "\u{1F600}", count: 20) + " target words"
        let ns = text as NSString
        let range = ns.range(of: "target")
        let anchor = CommentAnchor.anchor(text: text, range: range, entryId: "e")!
        XCTAssertEqual((anchor.prefix as NSString).length, CommentAnchor.context)
        XCTAssertEqual(CommentAnchor.locate(anchor, in: text), range)
    }

    // MARK: - Links and notifications

    func testAThreadLinkNamesItsThread() {
        XCTAssertEqual(CommentThreads.threadId(inLink: "/session/os-1?thread=th-2"), "th-2")
        XCTAssertEqual(CommentThreads.threadId(inLink: "https://acme.example.test/session/os-1?x=1&thread=th%203#c"), "th 3")
        XCTAssertNil(CommentThreads.threadId(inLink: "/session/os-1"))
        XCTAssertNil(CommentThreads.threadId(inLink: "/session/os-1?thread="))
        XCTAssertEqual(InboxDestination.route("/session/os-1?thread=th-2"), .session("os-1"))
        XCTAssertEqual(CommentThreads.link(sessionId: "os-1", threadId: "th-2"), "/session/os-1?thread=th-2")
    }

    func testThreadFocusWaitsForItsSessionAndThread() {
        let focus = ThreadFocus.shared
        _ = focus.take(sessionId: "any", available: { _ in true })
        focus.note(link: "/session/os-1?thread=th-2", sessionId: "os-1")
        XCTAssertNil(focus.take(sessionId: "os-9", available: { _ in true }), "another session")
        XCTAssertNil(focus.take(sessionId: "os-1", available: { _ in false }), "not loaded yet")
        XCTAssertEqual(focus.take(sessionId: "os-1", available: { $0 == "th-2" }), "th-2")
        XCTAssertNil(focus.take(sessionId: "os-1", available: { _ in true }), "taken once")
        focus.note(link: "/session/os-1", sessionId: "os-1")
        XCTAssertNil(focus.pending, "a link without a thread asks for nothing")
    }

    func testFocusingAThreadOpensItAndRevealsItOnce() {
        let store = SessionComments()
        store.apply(thread("th-1"))
        store.focus("th-1")
        XCTAssertEqual(store.presentedThreadId, "th-1")
        XCTAssertEqual(store.takeRevealRequest(), "th-1")
        XCTAssertNil(store.takeRevealRequest(), "a remounted transcript does not scroll again")
    }

    func testCommentNotificationsFollowTheMentionsGroupAndFocusTheirThread() throws {
        XCTAssertEqual(InboxKind.comment.alertGroup, .mentions)
        XCTAssertEqual(InboxKind.mention.alertGroup, .mentions)
        XCTAssertEqual(InboxKind.reviewDone.alertGroup, .reviews)

        let payload = try JSONDecoder().decode(InboxPayload.self, from: Data(#"""
        {"threads":[{"id":"session:os-1","subject":{"type":"session","id":"os-1","title":"Fix login"},
          "kind":"comment","reason":"Grace replied to a comment","url":"/session/os-1?thread=th-4",
          "updatedAt":5,"unread":true,"done":false}]}
        """#.utf8))
        let row = try XCTUnwrap(payload.threads.first)
        XCTAssertEqual(row.knownKind, .comment)
        XCTAssertEqual(row.commentThreadId, "th-4")

        let info = NotificationTap.userInfo(thread: row, scope: InboxScope(server: "https://acme.example.test", user: "Ada"))
        let target = try XCTUnwrap(NotificationTap.target(from: info))
        XCTAssertEqual(target.url, "/session/os-1?thread=th-4")
    }

    // MARK: - Drafts

    func testUnsentCommentsSurviveARemount() {
        let drafts = CommentDrafts.shared
        let anchor = TextAnchor(entryId: "e-1", exact: "Tests pass.")
        drafts.set("half a reply", session: "bks-1", key: CommentDrafts.replyKey("th-1"))
        drafts.set("half a comment", session: "bks-1", key: CommentDrafts.newKey(anchor))
        // A fresh view reads the same store.
        XCTAssertEqual(drafts.text(session: "bks-1", key: CommentDrafts.replyKey("th-1")), "half a reply")
        XCTAssertEqual(drafts.text(session: "bks-1", key: CommentDrafts.newKey(anchor)), "half a comment")
        XCTAssertEqual(drafts.text(session: "bks-1", key: CommentDrafts.replyKey("th-2")), "", "per thread")
        XCTAssertEqual(drafts.text(session: "bks-2", key: CommentDrafts.replyKey("th-1")), "", "per session")
        drafts.clear(session: "bks-1", key: CommentDrafts.replyKey("th-1"))
        XCTAssertEqual(drafts.text(session: "bks-1", key: CommentDrafts.replyKey("th-1")), "")
        drafts.clear(session: "bks-1", key: CommentDrafts.newKey(anchor))
    }

    func testThePendingPassageSurvivesTheViewModel() {
        let viewModel = SessionViewModel(session: Session(id: "bks-1"))
        viewModel.handle(.transcriptAppend(sessionId: "bks-1", entries: [
            TranscriptEntry(id: "a1", type: "assistant", content: "Run it on Sunday. Tests pass.", timestamp: "2026-01-01T00:00:00Z"),
        ]))
        XCTAssertEqual(viewModel.entryId(containing: " Tests pass. "), "a1")
        XCTAssertNil(viewModel.entryId(containing: "Monday"))
        viewModel.quoteSelection.stage("Tests pass.")
        viewModel.commentOnSelection()
        XCTAssertEqual(viewModel.comments.pendingAnchor?.entryId, "a1")
        XCTAssertEqual(viewModel.comments.pendingAnchor?.exact, "Tests pass.")
        XCTAssertNil(viewModel.quoteSelection.text)
    }

    func testSendToSessionQuotesThePassageAndNamesTheThread() {
        let anchored = thread("th-5", anchor: TextAnchor(entryId: "e", exact: "Tests pass.\nAll of them."))
        let text = anchored.sendToSessionText
        XCTAssertTrue(text.hasPrefix("> Tests pass.\n> All of them.\n\nFrom a comment thread on this session:"))
        XCTAssertTrue(text.contains("**Ada:** Is this right?"))
        XCTAssertTrue(text.contains("threadId `th-5`"))
    }

    // MARK: - Composer quote lines (ported from composer-highlight.test.ts)

    func testQuoteLinesDimOutsideFencesOnly() {
        let draft = "> Heads up \u{00b7} `x`\n>\nwhy?\n"
        let lines = ComposerQuoteLines.lines(in: draft)
        XCTAssertEqual(lines.count, 2)
        let ns = draft as NSString
        XCTAssertEqual(ns.substring(with: lines[0].line), "> Heads up \u{00b7} `x`")
        XCTAssertEqual(ns.substring(with: lines[0].marker), ">")
        XCTAssertEqual(ns.substring(with: lines[1].line), ">")

        XCTAssertTrue(ComposerQuoteLines.lines(in: "a > b").isEmpty, "a > mid-line is not a quote")
        XCTAssertTrue(ComposerQuoteLines.lines(in: "```\n> no\n```").isEmpty, "inside a fence")
        XCTAssertTrue(ComposerQuoteLines.lines(in: "```\n> still typing a fence").isEmpty, "inside an open fence")
        XCTAssertEqual(ComposerQuoteLines.lines(in: "```\nx\n```\n> yes").count, 1, "after a closed fence")
        XCTAssertEqual(
            ComposerQuoteLines.lines(in: "   > three spaces").first?.marker,
            NSRange(location: 0, length: 4)
        )
        XCTAssertTrue(ComposerQuoteLines.lines(in: "    > four is code").isEmpty)
        XCTAssertTrue(ComposerQuoteLines.lines(in: String(repeating: "> long\n", count: 2_000)).isEmpty)
    }

    func testAskAboutThisQuotesTheNoteAboveTheQuestion() {
        let note = YouShouldKnowNote(
            title: "You should know \u{00b7} The retry test waits on the queue",
            explanation: "It adds up to 30 seconds."
        )
        let draft = note.chatText + "Why 30?"
        let ns = draft as NSString
        let quoted = ComposerQuoteLines.lines(in: draft).map { ns.substring(with: $0.line) }
        XCTAssertFalse(quoted.isEmpty)
        XCTAssertTrue(quoted.allSatisfy { $0.hasPrefix(">") })
        XCTAssertFalse(quoted.contains { $0.contains("Why 30?") }, "the question stays undimmed")
        XCTAssertFalse(quoted.contains { $0.contains("About this note") }, "the lead-in reads as the question's")
    }
}

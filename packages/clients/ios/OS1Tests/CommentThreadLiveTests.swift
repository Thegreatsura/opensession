import XCTest
@testable import OS1

/// The comment-thread REST client against a real server. Skipped unless
/// `OS1_LIVE_COMMENTS_SESSION` names a session on the server in `OS1_SERVER`
/// (pass both with xcodebuild's `TEST_RUNNER_` prefix). Point it only at a
/// disposable development instance: it writes comments there.
@MainActor
final class CommentThreadLiveTests: XCTestCase {
    func testCreateReplyAssignResolveEditDeleteAndAskTheAgent() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let sessionId = env["OS1_LIVE_COMMENTS_SESSION"], env["OS1_SERVER"] != nil else {
            throw XCTSkip("set OS1_SERVER and OS1_LIVE_COMMENTS_SESSION to run against a server")
        }
        let entryId = env["OS1_LIVE_COMMENTS_ENTRY"] ?? ""
        let me = ServerConfig.shared.userName

        // An inline comment on a passage.
        let words = env["OS1_LIVE_COMMENTS_EXACT"] ?? "only two attempts happen"
        var anchored = try await OS1API.createCommentThread(
            sessionId: sessionId,
            text: "Is two attempts the whole bug, or is the backoff off too?",
            anchor: entryId.isEmpty ? nil : TextAnchor(entryId: entryId, exact: words, prefix: "", suffix: "")
        )
        XCTAssertEqual(anchored.anchor?.exact, entryId.isEmpty ? nil : words)
        XCTAssertEqual(anchored.createdBy, me)
        XCTAssertEqual(anchored.status, .open)

        // Reply, then assign and unassign (null on the wire).
        anchored = try await OS1API.replyToCommentThread(sessionId: sessionId, threadId: anchored.id, text: "Checking the backoff now.")
        XCTAssertEqual(anchored.comments.count, 2)
        anchored = try await OS1API.updateCommentThread(sessionId: sessionId, threadId: anchored.id, patch: .init(assignee: .some("Grace")))
        XCTAssertEqual(anchored.assignee, "Grace")
        anchored = try await OS1API.updateCommentThread(sessionId: sessionId, threadId: anchored.id, patch: .init(assignee: .some(nil)))
        XCTAssertNil(anchored.assignee)

        // Resolve and reopen.
        anchored = try await OS1API.updateCommentThread(sessionId: sessionId, threadId: anchored.id, patch: .init(status: .resolved))
        XCTAssertEqual(anchored.status, .resolved)
        XCTAssertEqual(anchored.resolvedBy, me)
        anchored = try await OS1API.updateCommentThread(sessionId: sessionId, threadId: anchored.id, patch: .init(status: .open))
        XCTAssertEqual(anchored.status, .open)

        // Edit and delete a reply; the thread survives.
        let reply = anchored.comments[1]
        anchored = try await OS1API.editThreadComment(sessionId: sessionId, threadId: anchored.id, commentId: reply.id, text: "Checked: the backoff is fine.")
        XCTAssertNotNil(anchored.comments[1].editedAt)
        let afterDelete = try await OS1API.deleteThreadComment(sessionId: sessionId, threadId: anchored.id, commentId: reply.id)
        XCTAssertEqual(afterDelete?.comments.count, 1)

        // A thread with no passage is a team note; deleting its opener takes it.
        let note = try await OS1API.createCommentThread(sessionId: sessionId, text: "Scratch note", assignee: "Grace")
        XCTAssertNil(note.anchor)
        XCTAssertEqual(note.assignee, "Grace")
        let gone = try await OS1API.deleteThreadComment(sessionId: sessionId, threadId: note.id, commentId: note.root.id)
        XCTAssertNil(gone)

        // Asking the agent is accepted at once; its answer arrives as a frame.
        try await OS1API.askAgentInThread(sessionId: sessionId, threadId: anchored.id)

        let listed = try await OS1API.commentThreads(sessionId: sessionId)
        XCTAssertTrue(listed.contains { $0.id == anchored.id })
        XCTAssertFalse(listed.contains { $0.id == note.id })
    }
}

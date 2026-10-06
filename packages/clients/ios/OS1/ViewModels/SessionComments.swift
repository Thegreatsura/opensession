import Foundation
import Observation

/// One session's comment threads, merged from the REST snapshot and live
/// frames. Owned by `SessionViewModel` but observed on its own, so a reply
/// landing re-renders the rows that show threads and not the whole transcript
/// (see the performance invariants in AGENTS.md).
///
/// Every mutation is broadcast back to the session's viewers as
/// `comment_thread`, so the response to a request and its echo can land in
/// either order: an older copy never replaces a newer one, and a deleted
/// thread never comes back. A legacy `session_note` echo of a session-level
/// thread is dropped whenever the server speaks threads, since the
/// `comment_thread` frame for the same id already carries the whole thread.
@Observable
@MainActor
final class SessionComments {
    /// Every thread, oldest first.
    private(set) var threads: [CommentThread] = []
    /// Whether the server has the threads API. Nil until the first load
    /// answers; false for a server that only knows the old notes routes.
    private(set) var threadsSupported: Bool?

    /// The thread open in the thread sheet.
    var presentedThreadId: String?
    /// The comments list is up.
    var showingList = false
    /// A passage someone chose to comment on, while they write the comment.
    /// Survives the transcript remounting under it, like the web's draft.
    var pendingAnchor: TextAnchor?
    /// Bumped whenever the transcript should bring a thread into view.
    private(set) var revealRequest: RevealRequest?

    struct RevealRequest: Equatable {
        let threadId: String
        let seq: Int
    }

    @ObservationIgnored private var deleted: Set<String> = []
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var touchedAt: [String: Int] = [:]
    @ObservationIgnored private var revealSeq = 0

    // MARK: Reading

    func thread(id: String) -> CommentThread? { threads.first { $0.id == id } }

    /// Threads with no passage: the team notes the timeline interleaves.
    var timelineThreads: [CommentThread] { threads.filter { $0.anchor == nil } }

    /// Threads attached to a passage of the transcript.
    var inlineThreads: [CommentThread] { threads.filter { $0.anchor != nil } }

    /// Inline threads whose passage sits in one of these entries.
    func inlineThreads(in entryIds: [String]) -> [CommentThread] {
        guard !entryIds.isEmpty else { return [] }
        let ids = Set(entryIds)
        return threads.filter { thread in
            guard let anchor = thread.anchor else { return false }
            return ids.contains(anchor.entryId)
        }
    }

    var openCount: Int { threads.lazy.filter { !$0.isResolved }.count }

    /// What the transcript's block list depends on: which notes exist and
    /// where they sit. Replies and resolves change neither.
    var timelineSignature: [String] {
        timelineThreads.map { "\($0.id)@\($0.ts)" }
    }

    // MARK: Writing

    /// Insert or replace by id. Returns whether anything changed.
    @discardableResult
    func apply(_ next: CommentThread) -> Bool {
        guard !deleted.contains(next.id) else { return false }
        revision += 1
        touchedAt[next.id] = revision
        if let index = threads.firstIndex(where: { $0.id == next.id }) {
            let current = threads[index]
            if !current.legacy, next.legacy { return false }
            if !current.legacy, current.updatedAt > next.updatedAt { return false }
            guard current != next else { return false }
            threads[index] = next
        } else {
            threads.append(next)
            threads.sort { $0.ts < $1.ts }
        }
        return true
    }

    /// A legacy `session_note` frame. On a threads server the `comment_thread`
    /// frame for the same id is the truth, so the note is an echo; on an old
    /// server it is the only word there is.
    @discardableResult
    func applyLegacyNote(_ note: SessionNote, sessionId: String) -> Bool {
        if threadsSupported == true { return false }
        if let current = thread(id: note.id), !current.legacy { return false }
        return apply(CommentThread(legacyNote: note, sessionId: sessionId))
    }

    @discardableResult
    func remove(id: String) -> Bool {
        deleted.insert(id)
        revision += 1
        touchedAt[id] = revision
        let before = threads.count
        threads.removeAll { $0.id == id }
        if presentedThreadId == id { presentedThreadId = nil }
        return threads.count != before
    }

    /// Where a snapshot request starts: anything a frame changes after this
    /// point beats the snapshot.
    func snapshotToken() -> Int { revision }

    /// Fold in a full list. Threads the snapshot lacks are dropped unless a
    /// frame touched them after the request began (they are newer than it).
    func merge(_ snapshot: [CommentThread], since token: Int, supported: Bool = true) {
        threadsSupported = supported
        let incoming = Set(snapshot.map(\.id))
        threads.removeAll { thread in
            !incoming.contains(thread.id) && (touchedAt[thread.id] ?? 0) <= token
        }
        for thread in snapshot { apply(thread) }
    }

    func markUnsupported() { threadsSupported = false }

    // MARK: Focus

    /// Open a thread and bring its passage or note into view.
    func focus(_ threadId: String) {
        presentedThreadId = threadId
        revealSeq += 1
        revealRequest = RevealRequest(threadId: threadId, seq: revealSeq)
    }

    /// The thread the transcript should scroll to, once. Clears the request
    /// so a remounted transcript does not scroll there again.
    func takeRevealRequest() -> String? {
        defer { revealRequest = nil }
        return revealRequest?.threadId
    }

    /// The block id that shows a thread, given the transcript's blocks.
    static func blockId(for thread: CommentThread, in blocks: [TranscriptBlock]) -> String? {
        guard let anchor = thread.anchor else {
            return blocks.first { if case .note(let note) = $0 { note.id == thread.id } else { false } }?.id
        }
        return blocks.first { $0.entryIds.contains(anchor.entryId) }?.id
    }
}

/// Comments being written, per session, kept for the life of the process.
/// A sheet or a transcript row can remount while someone types (the view
/// model cache can even evict the session), and an unsent comment must
/// survive that the way the web's `comment-draft` store does.
@MainActor
final class CommentDrafts {
    static let shared = CommentDrafts()

    private var drafts: [String: [String: String]] = [:]

    static func replyKey(_ threadId: String) -> String { "reply:\(threadId)" }
    static func newKey(_ anchor: TextAnchor?) -> String {
        guard let anchor else { return "new" }
        return "new:\(anchor.entryId):\(anchor.exact.hashValue)"
    }

    func text(session: String, key: String) -> String { drafts[session]?[key] ?? "" }

    func set(_ text: String, session: String, key: String) {
        if text.isEmpty {
            drafts[session]?[key] = nil
            if drafts[session]?.isEmpty == true { drafts[session] = nil }
        } else {
            drafts[session, default: [:]][key] = text
        }
    }

    func clear(session: String, key: String) { set("", session: session, key: key) }
}

/// "Open this comment thread": the `?thread=<id>` on a session link, from a
/// notification or a banner. The session view takes it once that thread has
/// loaded (web `lib/thread-focus.ts`).
@Observable
@MainActor
final class ThreadFocus {
    static let shared = ThreadFocus()

    private(set) var pending: (sessionId: String?, threadId: String)?
    private(set) var generation = 0

    /// Remember the thread a link points at, if it points at one.
    func note(link url: String, sessionId: String?) {
        guard let id = CommentThreads.threadId(inLink: url) else { return }
        pending = (sessionId, id)
        generation += 1
    }

    /// The requested thread, if it belongs to this session and is one it has.
    /// Clears the request.
    func take(sessionId: String, available: (String) -> Bool) -> String? {
        guard let pending else { return nil }
        if let wanted = pending.sessionId, wanted != sessionId { return nil }
        guard available(pending.threadId) else { return nil }
        self.pending = nil
        return pending.threadId
    }
}

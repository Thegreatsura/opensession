import Foundation

// Memory repositories (git, Agent Memory Repo format) as Settings sees them:
// the list, one repository's remote and sync state, its history, one change's
// diff, and its files. Wire shapes mirror `src/server/routes/memory-repo.ts`
// and `src/frontend/lib/memory-repo.ts`; every field stays optional so a
// server change never breaks an older build.

struct MemoryRemoteConflict: Codable, Sendable, Equatable {
    var files: [String]?
    var at: String?
}

struct MemoryRemoteStatus: Codable, Sendable, Equatable {
    var url: String?
    var lastSyncAt: String?
    var ok: Bool?
    var error: String?
    var conflict: MemoryRemoteConflict?

    enum State: Equatable {
        /// No remote configured: the repository lives on this server only.
        case localOnly
        /// A remote is saved but has never synced.
        case notSynced
        case synced
        case failed
        /// A merge with the remote did not apply cleanly.
        case conflict
    }

    /// The same precedence as the web chip: a conflict outranks a failure.
    var state: State {
        guard let url, !url.isEmpty else { return .localOnly }
        if conflict != nil { return .conflict }
        if ok == false { return .failed }
        if ok == true { return .synced }
        return .notSynced
    }

    var stateLabel: String {
        switch state {
        case .localOnly: "Local only"
        case .notSynced: "Not synced yet"
        case .synced: "Synced"
        case .failed: "Sync failed"
        case .conflict: "Conflict"
        }
    }

    var conflictFiles: [String] { (conflict?.files ?? []).filter { !$0.isEmpty } }
}

struct MemoryRepo: Codable, Sendable, Identifiable, Equatable {
    var name: String
    var label: String?
    var head: String?
    var remote: MemoryRemoteStatus?

    var id: String { name }
    var title: String { label?.isEmpty == false ? label! : name }
    var remoteStatus: MemoryRemoteStatus { remote ?? MemoryRemoteStatus() }
}

struct MemoryReposResponse: Codable, Sendable {
    var repos: [MemoryRepo]?
}

struct MemoryCommitFile: Codable, Sendable, Equatable {
    var status: String?
    var path: String?

    /// git's name-status letter, spelled out.
    var statusLabel: String {
        switch status?.first {
        case "A": "Added"
        case "D": "Deleted"
        case "M": "Modified"
        case "R": "Renamed"
        case "C": "Copied"
        case "T": "Type changed"
        default: status ?? ""
        }
    }
}

struct MemoryCommit: Codable, Sendable, Identifiable, Equatable {
    var sha: String
    var author: String?
    var date: String?
    var subject: String?
    var body: String?
    var files: [MemoryCommitFile]?
    /// The session that pushed (or whose trailer names) this change.
    var sessionId: String?
    var pushedBy: String?

    var id: String { sha }
    var shortSha: String { String(sha.prefix(8)) }
    var title: String { subject?.isEmpty == false ? subject! : "Change \(shortSha)" }
    var fileCount: Int { files?.count ?? 0 }
    var fileCountLabel: String { fileCount == 1 ? "1 file" : "\(fileCount) files" }
    var openableSessionId: String? {
        guard let sessionId, !sessionId.isEmpty else { return nil }
        return sessionId
    }
}

struct MemoryHistoryResponse: Codable, Sendable {
    var repo: String?
    var commits: [MemoryCommit]?
}

struct MemoryCommitDiffResponse: Codable, Sendable {
    var repo: String?
    var sha: String?
    var diff: String?
}

struct MemoryRevertResponse: Codable, Sendable {
    var ok: Bool?
    var head: String?
}

struct MemoryFilesResponse: Codable, Sendable {
    var repo: String?
    var files: [String]?
}

struct MemoryFileResponse: Codable, Sendable {
    var repo: String?
    var path: String?
    var content: String?
}

struct MemoryRemoteResponse: Codable, Sendable {
    var repo: String?
    var remote: MemoryRemoteStatus?
}

/// `/api/memory/scopes`: every scope the signed-in person can see, including
/// empty ones, so there is always somewhere to add an entry.
struct MemoryScopesResponse: Codable, Sendable {
    struct Item: Codable, Sendable {
        var scope: MemoryScopeInfo?
        var count: Int?
        var repo: String?
    }
    var scopes: [Item]?
}

/// `GET /api/memory`: one page of entry summaries.
struct MemoryEntriesPage: Codable, Sendable {
    var items: [MemoryEntry]?
    var nextCursor: String?
}

/// One line of a unified diff, tagged for colouring like the web's
/// `diffLineTone`.
enum MemoryDiffTone: Equatable {
    case add, remove, meta, plain

    static func of(_ line: Substring) -> MemoryDiffTone {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .meta }
        if line.hasPrefix("@@") || line.hasPrefix("diff --git") { return .meta }
        if line.hasPrefix("+") { return .add }
        if line.hasPrefix("-") { return .remove }
        return .plain
    }
}

struct MemoryDiffLine: Identifiable, Equatable {
    let id: Int
    let text: String
    let tone: MemoryDiffTone

    static func lines(_ diff: String) -> [MemoryDiffLine] {
        diff.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { MemoryDiffLine(id: $0.offset, text: String($0.element), tone: .of($0.element)) }
    }
}

enum MemoryRepoCopy {
    /// Placeholder only: never a real remote.
    static let remotePlaceholder = "git@example.test:acme/memory-team.git"
}

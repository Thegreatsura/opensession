import Foundation
import XCTest
@testable import OS1

/// Settings → Memory against `src/server/routes/memory-repo.ts`: decoding of
/// the repository, history, diff, file and remote shapes, and the exact route,
/// method and body every call sends. Placeholder names and hosts only.
@MainActor
final class MemoryRepoSettingsTests: XCTestCase {
    private let connection = SettingsAPI.Connection(
        baseURL: URL(string: "https://os.example.test")!,
        token: "test-token"
    )
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        MemoryStubProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MemoryStubProtocol.self]
        session = URLSession(configuration: configuration)
    }

    // MARK: - Decoding

    func testReposDecodeWithRemoteStates() throws {
        let json = #"""
        {"repos":[
          {"name":"team","label":"Team","head":"abc123","remote":{}},
          {"name":"user-U0ACME01","label":"Alex","head":null,
           "remote":{"url":"git@example.test:acme/memory-alex.git","lastSyncAt":"2026-10-05T20:00:00.000Z","ok":true}},
          {"name":"channel-C0ACME","label":"#acme","head":"def456",
           "remote":{"url":"git@example.test:acme/memory-ch.git","ok":false,"error":"The remote and this server changed the same lines.",
                     "conflict":{"files":["MEMORY.md","notes/a.md"],"at":"2026-10-05T20:01:00.000Z"}}},
          {"name":"repos-x","remote":{"url":"git@example.test:acme/x.git","ok":false,"error":"denied"}},
          {"name":"fresh","remote":{"url":"git@example.test:acme/fresh.git"}}
        ],"extra":true}
        """#
        let repos = try JSONDecoder().decode(MemoryReposResponse.self, from: Data(json.utf8)).repos ?? []
        XCTAssertEqual(repos.map(\.name), ["team", "user-U0ACME01", "channel-C0ACME", "repos-x", "fresh"])
        XCTAssertEqual(repos[0].title, "Team")
        XCTAssertEqual(repos[3].title, "repos-x", "a missing label falls back to the name")
        XCTAssertNil(repos[1].head)
        XCTAssertEqual(repos.map(\.remoteStatus.state), [.localOnly, .synced, .conflict, .failed, .notSynced])
        XCTAssertEqual(repos[2].remoteStatus.stateLabel, "Conflict")
        XCTAssertEqual(repos[2].remoteStatus.conflictFiles, ["MEMORY.md", "notes/a.md"])
        XCTAssertEqual(repos[3].remoteStatus.stateLabel, "Sync failed")
    }

    func testHistoryDecodesFilesSessionAndPusher() throws {
        let json = #"""
        {"repo":"team","commits":[
          {"sha":"0123456789abcdef0123456789abcdef01234567","author":"Alex","date":"2026-10-05T20:09:55+00:00",
           "subject":"Remember the deploy window","body":"Session: https://os.example.test/session/os-0001",
           "files":[{"status":"M","path":"MEMORY.md"},{"status":"A","path":"notes/deploys.md"}],
           "sessionId":"os-0001","pushedBy":"alex"},
          {"sha":"fedcba9876543210","author":"Sam","date":"2026-10-04T10:00:00+00:00","subject":"","body":"","files":[]}
        ]}
        """#
        let commits = try JSONDecoder().decode(MemoryHistoryResponse.self, from: Data(json.utf8)).commits ?? []
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].shortSha, "01234567")
        XCTAssertEqual(commits[0].fileCountLabel, "2 files")
        XCTAssertEqual(commits[0].files?.map(\.statusLabel), ["Modified", "Added"])
        XCTAssertEqual(commits[0].openableSessionId, "os-0001")
        XCTAssertEqual(commits[0].pushedBy, "alex")
        XCTAssertNotNil(Session.parseISO(commits[0].date), "git's %aI dates parse")
        XCTAssertNil(commits[1].openableSessionId)
        XCTAssertEqual(commits[1].title, "Change fedcba98")
        XCTAssertEqual(commits[1].fileCountLabel, "0 files")
    }

    func testEntriesDecodeBothShapes() throws {
        let legacy = try JSONDecoder().decode(
            MemoryEntry.self,
            from: Data(#"{"id":"m-1","text":"Use bun","by":"Alex","at":"2026-01-01"}"#.utf8)
        )
        XCTAssertEqual(legacy.displayText, "Use bun")
        XCTAssertEqual(legacy.byline, "Alex · 2026-01-01")

        let summary = try JSONDecoder().decode(
            MemoryEntry.self,
            from: Data(#"""
            {"id":"m-2a3b4c5d6e","scopeKey":"repo-acme","summary":"Run checks before pushing","hasDetails":false,
             "kind":"constraint","tier":"retrievable","state":"active","source":{"type":"settings"},"supersedes":[],"tags":[],
             "updatedAt":"2026-10-05T00:00:00.000Z","path":"repos/acme/constraints.md","repo":"team"}
            """#.utf8)
        )
        XCTAssertEqual(summary.displayText, "Run checks before pushing")
        XCTAssertEqual(summary.repo, "team")
        XCTAssertEqual(summary.byline, "constraint · 2026-10-05")
    }

    func testCachedScopesFromAnOlderBuildStillDecode() throws {
        let old = #"[{"scope":{"key":"workspace","kind":"workspace","label":"Team"},"entries":[{"id":"m-1","text":"Hi"}]}]"#
        let scopes = try JSONDecoder().decode([MemoryScope].self, from: Data(old.utf8))
        XCTAssertEqual(scopes.first?.entries?.first?.displayText, "Hi")
        XCTAssertNil(scopes.first?.repo)
    }

    func testDiffLinesAreToned() {
        let diff = "diff --git a/MEMORY.md b/MEMORY.md\n--- a/MEMORY.md\n+++ b/MEMORY.md\n@@ -1 +1 @@\n-old\n+new\n context\n"
        let lines = MemoryDiffLine.lines(diff)
        XCTAssertEqual(lines.map(\.tone), [.meta, .meta, .meta, .meta, .remove, .add, .plain, .plain])
        XCTAssertEqual(lines.map(\.id), Array(0..<8))
    }

    func testMissingRouteMeansNoRepositories() {
        XCTAssertTrue(MemorySettingsModel.isMissingRoute(OS1API.APIError.http(404)))
        XCTAssertTrue(MemorySettingsModel.isMissingRoute(OS1API.APIError.server("entry not found")))
        XCTAssertFalse(MemorySettingsModel.isMissingRoute(OS1API.APIError.http(500)))
        XCTAssertFalse(MemorySettingsModel.isMissingRoute(OS1API.APIError.server("repository not found")))
    }

    /// Responses captured from a repo-mode server (placeholder content, hosts
    /// rewritten to example.test): what the app really receives.
    func testCapturedServerResponsesDecode() throws {
        let repos = try fixture("memory-repos", as: MemoryReposResponse.self).repos ?? []
        XCTAssertEqual(repos.map(\.name), ["team", "user-alex"])
        XCTAssertEqual(repos.map(\.remoteStatus.state), [.synced, .localOnly])

        let commits = try fixture("memory-history", as: MemoryHistoryResponse.self).commits ?? []
        XCTAssertEqual(commits.map(\.openableSessionId), ["bks-demo-pr", "bks-demo-live"])
        XCTAssertEqual(commits.first?.files?.map(\.path), ["MEMORY.md", "notes/deploys.md"])

        let diff = try fixture("memory-commit", as: MemoryCommitDiffResponse.self).diff ?? ""
        let lines = MemoryDiffLine.lines(diff)
        XCTAssertTrue(lines.contains { $0.tone == .add && $0.text == "+- [[notes/deploys]]" })
        XCTAssertTrue(lines.contains { $0.tone == .meta && $0.text.hasPrefix("diff --git") })

        let scopes = try fixture("memory-scopes", as: MemoryScopesResponse.self).scopes ?? []
        XCTAssertTrue(scopes.contains { $0.scope?.key == "workspace" && $0.repo == "team" })

        let page = try fixture("memory-entries", as: MemoryEntriesPage.self)
        XCTAssertFalse(page.items?.isEmpty ?? true, "summaries with an object `source` still decode")
        XCTAssertTrue(page.items?.allSatisfy { !$0.displayText.isEmpty && $0.repo == "team" } ?? false)
    }

    private func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    // MARK: - Routes and mutations

    func testReadRoutes() async throws {
        MemoryStubProtocol.respond { request in
            switch request.url?.path {
            case "/api/memory/repos": return (200, #"{"repos":[{"name":"team","label":"Team","head":"a","remote":{}}]}"#)
            case "/api/memory/history": return (200, #"{"repo":"team","commits":[{"sha":"abcdef12","files":[]}]}"#)
            case "/api/memory/commit": return (200, #"{"repo":"team","sha":"abcdef12","diff":"+x"}"#)
            case "/api/memory/files": return (200, #"{"repo":"team","files":["MEMORY.md","notes/a.md"]}"#)
            case "/api/memory/file": return (200, #"{"repo":"team","path":"notes/a.md","content":"- a"}"#)
            default: return (404, #"{"error":"nope"}"#)
            }
        }
        let repos = try await SettingsAPI.memoryRepos(connection: connection, session: session)
        let commits = try await SettingsAPI.memoryHistory(repo: "team", connection: connection, session: session)
        let diff = try await SettingsAPI.memoryCommitDiff(repo: "team", sha: "abcdef12", connection: connection, session: session)
        let files = try await SettingsAPI.memoryFiles(repo: "user-U0ACME01", connection: connection, session: session)
        let content = try await SettingsAPI.memoryFile(repo: "team", path: "notes/a.md", connection: connection, session: session)

        XCTAssertEqual(repos.map(\.name), ["team"])
        XCTAssertEqual(commits.map(\.sha), ["abcdef12"])
        XCTAssertEqual(diff, "+x")
        XCTAssertEqual(files, ["MEMORY.md", "notes/a.md"])
        XCTAssertEqual(content, "- a")

        let seen = MemoryStubProtocol.requests
        XCTAssertEqual(seen.map(\.method), Array(repeating: "GET", count: 5))
        XCTAssertEqual(seen.map(\.path), [
            "/api/memory/repos", "/api/memory/history", "/api/memory/commit", "/api/memory/files", "/api/memory/file",
        ])
        XCTAssertEqual(seen[1].query, ["repo": "team", "limit": "40"])
        XCTAssertEqual(seen[2].query, ["repo": "team", "sha": "abcdef12"])
        XCTAssertEqual(seen[3].query, ["repo": "user-U0ACME01"])
        XCTAssertEqual(seen[4].query, ["repo": "team", "path": "notes/a.md"])
        XCTAssertTrue(seen.allSatisfy { $0.authorization == "Bearer test-token" })
    }

    func testRevertPostsRepoAndSha() async throws {
        MemoryStubProtocol.respond { _ in (200, #"{"ok":true,"head":"9999"}"#) }
        let result = try await SettingsAPI.revertMemoryCommit(
            repo: "team", sha: "abcdef12", connection: connection, session: session
        )
        XCTAssertEqual(result.ok, true)
        XCTAssertEqual(result.head, "9999")
        let request = try XCTUnwrap(MemoryStubProtocol.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/memory/revert")
        XCTAssertEqual(request.body as? [String: String], ["repo": "team", "sha": "abcdef12"])
    }

    func testRevertConflictSurfacesTheServerMessage() async {
        let message = "This change cannot be reverted automatically because later changes touched the same lines."
        MemoryStubProtocol.respond { _ in (409, #"{"error":"\#(message)"}"#) }
        do {
            _ = try await SettingsAPI.revertMemoryCommit(repo: "team", sha: "abcdef12", connection: connection, session: session)
            XCTFail("a 409 must throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, message)
        }
    }

    func testRemoteSaveTrimsAndSyncPosts() async throws {
        MemoryStubProtocol.respond { request in
            request.url?.path == "/api/memory/remote/sync"
                ? (200, #"{"repo":"team","remote":{"url":"/tmp/acme.git","ok":false,"error":"conflict","conflict":{"files":["MEMORY.md"],"at":"2026-10-05T00:00:00Z"}}}"#)
                : (200, #"{"repo":"team","remote":{"url":"/tmp/acme.git","ok":true,"lastSyncAt":"2026-10-05T00:00:00Z"}}"#)
        }
        let saved = try await SettingsAPI.saveMemoryRemote(
            repo: "team", url: "  /tmp/acme.git \n", connection: connection, session: session
        )
        XCTAssertEqual(saved.state, .synced)
        let synced = try await SettingsAPI.syncMemoryRemote(repo: "team", connection: connection, session: session)
        XCTAssertEqual(synced.state, .conflict, "a conflict is a 200 with ok:false, not a thrown error")
        XCTAssertEqual(synced.conflictFiles, ["MEMORY.md"])

        let seen = MemoryStubProtocol.requests
        XCTAssertEqual(seen.map(\.method), ["PUT", "POST"])
        XCTAssertEqual(seen.map(\.path), ["/api/memory/remote", "/api/memory/remote/sync"])
        XCTAssertEqual(seen[0].body as? [String: String], ["repo": "team", "url": "/tmp/acme.git"])
        XCTAssertEqual(seen[1].body as? [String: String], ["repo": "team"])
    }

    func testRemovingTheRemoteSendsAnEmptyURL() async throws {
        MemoryStubProtocol.respond { _ in (200, #"{"repo":"team","remote":{}}"#) }
        let status = try await SettingsAPI.saveMemoryRemote(repo: "team", url: "", connection: connection, session: session)
        XCTAssertEqual(status.state, .localOnly)
        XCTAssertEqual(MemoryStubProtocol.requests.first?.body as? [String: String], ["repo": "team", "url": ""])
    }

    func testEntryScopesPageEachScope() async throws {
        MemoryStubProtocol.respond { request in
            let query = MemoryStubProtocol.query(of: request)
            if request.url?.path == "/api/memory/scopes" {
                return (200, #"""
                {"scopes":[
                  {"scope":{"key":"workspace","kind":"workspace","label":"Team"},"count":3,"repo":"team"},
                  {"scope":{"key":"repo-acme","kind":"repo","label":"acme"},"count":0,"repo":"team"}
                ],"stats":{"mode":"repo"}}
                """#)
            }
            switch query["cursor"] {
            case nil: return (200, #"{"items":[{"id":"m-1","summary":"one","source":{"type":"settings"}},{"id":"m-2","summary":"two"}],"nextCursor":"c1"}"#)
            default: return (200, #"{"items":[{"id":"m-3","summary":"three"}]}"#)
            }
        }
        let scopes = try await SettingsAPI.memoryScopes(connection: connection, session: session)
        XCTAssertEqual(scopes.map { $0.scope?.key }, ["workspace", "repo-acme"])
        XCTAssertEqual(scopes[0].entries?.map(\.displayText), ["one", "two", "three"])
        XCTAssertEqual(scopes[0].repo, "team")
        XCTAssertEqual(scopes[1].entries?.count, 0, "an empty scope is not fetched but still listed")

        let entryCalls = MemoryStubProtocol.requests.filter { $0.path == "/api/memory" }
        XCTAssertEqual(entryCalls.count, 2)
        XCTAssertEqual(entryCalls[0].query, ["scopeKey": "workspace", "state": "active", "limit": "50"])
        XCTAssertEqual(entryCalls[1].query["cursor"], "c1")
    }

    func testEntryPagingStopsOnARepeatedCursor() async throws {
        MemoryStubProtocol.respond { request in
            request.url?.path == "/api/memory/scopes"
                ? (200, #"{"scopes":[{"scope":{"key":"workspace"},"count":1}]}"#)
                : (200, #"{"items":[{"id":"m-1","summary":"x"}],"nextCursor":"same"}"#)
        }
        let scopes = try await SettingsAPI.memoryScopes(connection: connection, session: session)
        XCTAssertEqual(scopes.first?.entries?.count, 2, "first page, then the repeated cursor stops it")
    }

    func testEntryMutationsKeepTheirCompatibilityShapes() async throws {
        MemoryStubProtocol.respond { request in
            request.httpMethod == "DELETE"
                ? (200, #"{"ok":true}"#)
                : (200, #"{"entry":{"id":"m-1","summary":"Use bun","scopeKey":"workspace","repo":"team"}}"#)
        }
        let added = try await SettingsAPI.addMemory(
            scopeKey: "workspace", text: "Use bun", by: "Alex", connection: connection, session: session
        )
        let updated = try await SettingsAPI.updateMemory(
            scopeKey: "workspace", id: "m-1", text: "Use bun", connection: connection, session: session
        )
        let deleted = try await SettingsAPI.deleteMemory(
            scopeKey: "workspace", id: "m-1", connection: connection, session: session
        )
        XCTAssertEqual(added.entry?.displayText, "Use bun")
        XCTAssertEqual(updated.entry?.repo, "team")
        XCTAssertEqual(deleted.ok, true)

        let seen = MemoryStubProtocol.requests
        XCTAssertEqual(seen.map(\.method), ["POST", "PUT", "DELETE"])
        XCTAssertTrue(seen.allSatisfy { $0.path == "/api/memory" })
        XCTAssertEqual(seen[0].body as? [String: String], ["scopeKey": "workspace", "text": "Use bun", "by": "Alex"])
        XCTAssertEqual(seen[1].body as? [String: String], ["scopeKey": "workspace", "id": "m-1", "text": "Use bun"])
        XCTAssertEqual(seen[2].body as? [String: String], ["scopeKey": "workspace", "id": "m-1"])
    }
}

/// Answers every request from a closure and records what was sent.
final class MemoryStubProtocol: URLProtocol {
    struct Seen {
        var method: String
        var path: String
        var query: [String: String]
        var body: Any?
        var authorization: String?
    }

    nonisolated(unsafe) private static var handler: (URLRequest) -> (Int, String) = { _ in (500, "{}") }
    nonisolated(unsafe) private(set) static var requests: [Seen] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        requests = []
        handler = { _ in (500, "{}") }
    }

    static func respond(_ next: @escaping (URLRequest) -> (Int, String)) {
        lock.lock(); defer { lock.unlock() }
        handler = next
    }

    static func query(of request: URLRequest) -> [String: String] {
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let bodyData = request.httpBody ?? request.httpBodyStream.map(Self.drain)
        let body = bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        Self.lock.lock()
        Self.requests.append(Seen(
            method: request.httpMethod ?? "GET",
            path: request.url?.path ?? "",
            query: Self.query(of: request),
            body: body,
            authorization: request.value(forHTTPHeaderField: "Authorization")
        ))
        let handler = Self.handler
        Self.lock.unlock()
        let (status, text) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

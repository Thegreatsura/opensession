import Foundation

/// REST calls behind the session action cards. Every answer names the session
/// it is for, so the server can refuse an answer aimed at another session's
/// card. A credential's secret appears in exactly one place: the body of
/// `registerCredential`. It is never logged, cached, or kept after the call.
///
/// Injected as closures so `SessionActionCardsModel` can be tested without a
/// server; `.live` is the real transport.
@MainActor
struct SessionActionsClient {
    var registration: @MainActor (_ sessionId: String) async throws -> PendingCredentialRegistration?
    var registerCredential: @MainActor (_ sessionId: String, _ requestId: String, _ secret: String) async throws -> Void
    var declineCredential: @MainActor (_ sessionId: String, _ requestId: String) async throws -> Void
    var keychainAsks: @MainActor (_ sessionId: String) async throws -> [SessionKeychainAsk]
    var answerKeychainAsk: @MainActor (_ askId: String, _ decision: SessionKeychainAsk.Decision) async throws -> Void
    var forceMerge: @MainActor (_ sessionId: String) async throws -> PendingForceMerge?
    var confirmForceMerge: @MainActor (_ sessionId: String, _ requestId: String) async throws -> ForceMergeOutcome?
    var cancelForceMerge: @MainActor (_ sessionId: String, _ requestId: String) async throws -> Void
    var scriptRuns: @MainActor (_ sessionId: String) async throws -> [ScriptRun]
    var scriptOutput: @MainActor (_ sessionId: String, _ runId: String) async throws -> String
    var stopScript: @MainActor (_ sessionId: String, _ runId: String) async throws -> Void
    var rememberYouShouldKnow: @MainActor (_ user: String, _ line: String) async throws -> Void
    var setYouShouldKnow: @MainActor (_ user: String, _ enabled: Bool) async throws -> Bool

    static let live = SessionActionsClient(
        registration: { sessionId in
            let response: CredentialRegistrationResponse = try await SessionActionsAPI.send(
                "/api/keychain/registrations", query: ["sessionId": sessionId]
            )
            return response.pending
        },
        registerCredential: { sessionId, requestId, secret in
            let _: SessionActionsAPI.Empty = try await SessionActionsAPI.send(
                "/api/keychain/registrations/\(SessionActionsAPI.segment(requestId))",
                method: "POST",
                body: ["sessionId": sessionId, "secret": secret],
                fallback: "Couldn't save the credential"
            )
        },
        declineCredential: { sessionId, requestId in
            let _: SessionActionsAPI.Empty = try await SessionActionsAPI.send(
                "/api/keychain/registrations/\(SessionActionsAPI.segment(requestId))/decline",
                method: "POST",
                body: ["sessionId": sessionId],
                fallback: "Couldn't decline the request"
            )
        },
        keychainAsks: { sessionId in
            let response: SessionKeychainAsksResponse = try await SessionActionsAPI.send(
                "/api/keychain/asks", query: ["sessionId": sessionId]
            )
            return response.asks
        },
        answerKeychainAsk: { askId, decision in
            let _: SessionActionsAPI.Empty = try await SessionActionsAPI.send(
                "/api/keychain/asks/\(SessionActionsAPI.segment(askId))/answer",
                method: "POST",
                body: ["decision": decision.rawValue],
                fallback: "Couldn't answer the request"
            )
        },
        forceMerge: { sessionId in
            let response: ForceMergeResponse = try await SessionActionsAPI.send(
                "/api/force-merge", query: ["sessionId": sessionId]
            )
            return response.pending
        },
        confirmForceMerge: { sessionId, requestId in
            // A refusal can come back as an error status that still carries
            // the settled result; that is an answer, not a transport failure.
            struct Response: Decodable, Sendable { let result: ForceMergeOutcome? }
            let response: Response = try await SessionActionsAPI.send(
                "/api/force-merge/\(SessionActionsAPI.segment(requestId))/confirm",
                method: "POST",
                body: ["sessionId": sessionId],
                fallback: "Couldn't answer the force merge",
                acceptsErrorBody: { (try? JSONDecoder().decode(Response.self, from: $0))?.result != nil }
            )
            return response.result
        },
        cancelForceMerge: { sessionId, requestId in
            let _: SessionActionsAPI.Empty = try await SessionActionsAPI.send(
                "/api/force-merge/\(SessionActionsAPI.segment(requestId))/cancel",
                method: "POST",
                body: ["sessionId": sessionId],
                fallback: "Couldn't answer the force merge"
            )
        },
        scriptRuns: { sessionId in
            let response: ScriptRunsResponse = try await SessionActionsAPI.send(
                "/api/scripts", query: ["sessionId": sessionId]
            )
            return response.runs
        },
        scriptOutput: { sessionId, runId in
            let response: ScriptRunDetailResponse = try await SessionActionsAPI.send(
                "/api/scripts/\(SessionActionsAPI.segment(runId))",
                query: ["sessionId": sessionId]
            )
            return response.run?.outputTail ?? ""
        },
        stopScript: { sessionId, runId in
            let _: SessionActionsAPI.Empty = try await SessionActionsAPI.send(
                "/api/scripts/\(SessionActionsAPI.segment(runId))/stop",
                method: "POST",
                body: ["sessionId": sessionId],
                fallback: "Couldn't stop."
            )
        },
        rememberYouShouldKnow: { user, line in
            let _: SessionActionsAPI.Empty = try await SessionActionsAPI.send(
                "/api/personal-you-should-know/known",
                method: "POST",
                body: ["user": user, "line": line],
                fallback: "Failed to save"
            )
        },
        setYouShouldKnow: { user, enabled in
            try await SessionActionsAPI.setYouShouldKnow(user: user, enabled: enabled)
        }
    )
}

enum SessionActionsAPI {
    struct Empty: Decodable, Sendable {}

    private struct EnabledResponse: Decodable, Sendable { let enabled: Bool? }
    private struct ErrorBody: Decodable { let error: String? }

    /// Settings → Preferences reads this. On by default server-side.
    static func youShouldKnow(user: String) async throws -> Bool {
        let response: EnabledResponse = try await send(
            "/api/personal-you-should-know", query: ["user": user]
        )
        return response.enabled ?? true
    }

    static func setYouShouldKnow(user: String, enabled: Bool) async throws -> Bool {
        let response: EnabledResponse = try await send(
            "/api/personal-you-should-know",
            method: "PUT",
            body: ["user": user, "enabled": enabled],
            fallback: "Failed to save You should know"
        )
        return response.enabled ?? enabled
    }

    static func segment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// One authorized request. The body is serialized straight into the
    /// request and dropped with it; nothing here logs a body or an error body.
    @MainActor
    static func send<T: Decodable & Sendable>(
        _ path: String,
        method: String = "GET",
        query: [String: String] = [:],
        body: [String: Any]? = nil,
        fallback: String? = nil,
        acceptsErrorBody: ((Data) -> Bool)? = nil
    ) async throws -> T {
        let config = ServerConfig.shared
        guard let base = config.baseURL, config.isConfigured else {
            throw OS1API.APIError.notConfigured
        }
        guard var components = URLComponents(string: base.absoluteString + path) else {
            throw OS1API.APIError.badURL
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw OS1API.APIError.badURL }
        var request = config.authorizedRequest(url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode),
           acceptsErrorBody?(data) != true {
            if let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error,
               !message.isEmpty {
                throw OS1API.APIError.server(message)
            }
            if let fallback { throw OS1API.APIError.server(fallback) }
            throw OS1API.APIError.http(http.statusCode)
        }
        return try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(T.self, from: data)
        }.value
    }
}

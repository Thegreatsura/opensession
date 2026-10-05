import Foundation

/// Where a "Ready for review" request goes. The server has two routes, the
/// same pair the web panel uses: a session's own PR (optionally one of its
/// attached-repo or series PRs, picked by repo and branch) and a sessionless
/// preview, which names the repo and branch outright.
enum PrReadyTarget: Equatable, Hashable, Sendable {
    case session(id: String, repo: String? = nil, branch: String? = nil)
    case preview(repo: String, branch: String)

    var path: String {
        switch self {
        case .session(let id, _, _):
            let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
            return "/api/sessions/\(encoded)/pr-ready"
        case .preview:
            return "/api/pr-preview-ready"
        }
    }

    /// Only the fields the route reads. A session target with neither leaves
    /// the server to resolve the session's primary PR.
    var body: [String: String] {
        switch self {
        case .session(_, let repo, let branch):
            var body: [String: String] = [:]
            if let repo, !repo.isEmpty { body["repo"] = repo }
            if let branch, !branch.isEmpty { body["branch"] = branch }
            return body
        case .preview(let repo, let branch):
            return ["repo": repo, "branch": branch]
        }
    }
}

extension Session {
    /// The same session with one PR taken out of draft, so the row and chip
    /// stop reading Draft before the next list poll catches up. Only the
    /// matching target changes; every other PR keeps its own state.
    func markingPrReady(_ target: SessionPrTarget) -> Session {
        var next = self
        if effectiveRepo == target.repo, branch == target.branch {
            next.prIsDraft = false
        }
        next.prs = prs?.map { ref in
            guard ref.repo == target.repo, ref.branch == target.branch else { return ref }
            var ready = ref
            ready.isDraft = false
            return ready
        }
        return next
    }
}

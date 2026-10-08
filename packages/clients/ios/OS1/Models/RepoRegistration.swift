import Foundation
import Observation

/// Where a new project comes from. The three entries of the sidebar's
/// workspace options → Add project submenu, and the three rows under
/// Settings → Repositories. Mirrors the web's `AddRepoMode` (SetupRepos.tsx).
enum AddRepositorySource: String, CaseIterable, Identifiable, Sendable {
    /// Clone a GitHub or code.storage repository onto the server.
    case remote
    /// Register a Git checkout that already sits on the SERVER's disk. Not a
    /// folder on this device: nothing is uploaded or bridged.
    case local
    /// Start an empty repository on the server, or connect one just created
    /// on GitHub.
    case new

    var id: String { rawValue }

    /// The menu row that opens this source.
    var menuLabel: String {
        switch self {
        case .remote: "Clone repository…"
        case .local: "Local folder…"
        case .new: "New repository…"
        }
    }

    /// The title of the screen the row opens.
    var title: String {
        switch self {
        case .remote: "Clone repository"
        case .local: "Add local folder"
        case .new: "New repository"
        }
    }

    var systemImage: String {
        switch self {
        case .remote: "arrow.down.circle"
        case .local: "folder"
        case .new: "plus"
        }
    }
}

/// One `POST /api/setup/repos` request, with everything the screens say about
/// it. Built only through the validating constructors, so a form never sends
/// a body the route would refuse (src/server/routes/setup-repos.ts).
struct RepoRegistration: Equatable, Hashable, Sendable, Identifiable {
    enum Action: Equatable, Hashable, Sendable {
        /// The server clones a remote. Slow: as long as the repo is large.
        case clone
        /// The server registers a checkout already on its disk, in place.
        case register
        /// The server starts an empty repository of its own.
        case create
    }

    /// What the person sees: `owner/name`, a server path, or a new name.
    let label: String
    let action: Action
    /// The JSON body, every value a string.
    let body: [String: String]

    /// Also the duplicate key: one registration per body.
    var id: String {
        body.keys.sorted().map { "\($0)=\(body[$0] ?? "")" }.joined(separator: "&")
    }

    /// "Cloning acme/widget…": the wait state while the request runs.
    var pendingText: String {
        let verb = switch action {
        case .clone: "Cloning"
        case .register: "Registering"
        case .create: "Creating"
        }
        return "\(verb) \(label)…"
    }

    var confirmTitle: String {
        switch action {
        case .clone: "Add \(label)?"
        case .register: "Register \(label)?"
        case .create: "Create \(label)?"
        }
    }

    var confirmButton: String {
        switch action {
        case .clone: "Add"
        case .register: "Register"
        case .create: "Create"
        }
    }

    /// What the confirmation says before the tap. Every action changes what
    /// the whole instance can work in, and no client route takes one back.
    var confirmMessage: String {
        switch action {
        case .clone:
            "The server clones it, which can take a minute on a large repo."
        case .register:
            "The server registers this checkout where it is. Sessions branch into worktrees of it."
        case .create:
            "The server starts an empty repository with a first commit on main. Sessions get branches and diffs, but no GitHub pull requests."
        }
    }

    // MARK: - Constructors

    /// A GitHub `owner/name` to clone. Also how a repository just created on
    /// GitHub is connected: the server refuses to create one there itself.
    static func github(fullName: String) -> RepoRegistration? {
        let name = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validGithubFullName(name) else { return nil }
        return RepoRegistration(label: name, action: .clone, body: ["fullName": name])
    }

    /// A code.storage repository from its listed path.
    static func codeStorage(fullName: String) -> RepoRegistration? {
        let name = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return RepoRegistration(
            label: name,
            action: .clone,
            body: ["source": "codestorage", "fullName": name]
        )
    }

    /// An absolute path to a Git checkout on the server.
    static func local(path: String) -> RepoRegistration? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validServerPath(trimmed) else { return nil }
        return RepoRegistration(
            label: trimmed,
            action: .register,
            body: ["source": "local", "path": trimmed]
        )
    }

    /// A new repository: on this server alone when `owner` is nil, otherwise
    /// the connect half of a repository the person created on GitHub (same
    /// split as the web's `newRepoRegistration`).
    static func new(name: String, owner: String?) -> RepoRegistration? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validNewRepoName(trimmed) else { return nil }
        if let owner {
            let login = owner.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validGithubOwner(login) else { return nil }
            return github(fullName: "\(login)/\(trimmed)")
        }
        return RepoRegistration(
            label: trimmed,
            action: .create,
            body: ["source": "new", "name": trimmed]
        )
    }

    // MARK: - Rules shared with the server and the web

    /// `GITHUB_FULL_NAME_RE` in setup-repos.ts: `[\w.-]+/[\w.-]+`.
    static func validGithubFullName(_ value: String) -> Bool {
        value.wholeMatch(of: #/[A-Za-z0-9_.\-]+\/[A-Za-z0-9_.\-]+/#) != nil
    }

    /// `validGithubOwner` in lib/new-repo.ts: a GitHub login, not a URL.
    static func validGithubOwner(_ value: String) -> Bool {
        value.wholeMatch(of: #/[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}/#) != nil
    }

    /// `validNewRepoName` in shared/repo-name.ts.
    static func validNewRepoName(_ value: String) -> Bool {
        guard value.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9._\-]{0,99}/#) != nil else {
            return false
        }
        if value.contains("..") { return false }
        if value.lowercased().hasSuffix(".git") { return false }
        return !["__proto__", "prototype", "constructor"].contains(value.lowercased())
    }

    /// The route wants an absolute path; it inspects the rest itself.
    static func validServerPath(_ value: String) -> Bool {
        value.hasPrefix("/") && value.count > 1
    }

    /// GitHub's new-repository page, prefilled. Prefill only: the person
    /// reviews visibility and confirms there (`githubNewRepoUrl`).
    static func githubNewRepoURL(owner: String, name: String) -> URL? {
        var components = URLComponents(string: "https://github.com/new")
        components?.queryItems = [
            URLQueryItem(name: "owner", value: owner),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "visibility", value: "private"),
            URLQueryItem(name: "readme", value: "1"),
        ]
        return components?.url
    }
}

/// The pending, error and duplicate state of the add-a-project flow, apart
/// from the views so it can be tested. One registration at a time: the server
/// takes a config lock for each, so a second would queue behind the first
/// with no way to say so.
@MainActor
@Observable
final class RepoRegistrationModel {
    /// The request that sends one registration.
    let post: @MainActor (RepoRegistration) async throws -> Void

    /// The registration running right now, if any.
    private(set) var pending: RepoRegistration?
    /// The server's own text for the last failure.
    var error: String?
    /// Registered from this screen, so their rows read "Added".
    private(set) var added: Set<String> = []

    init(post: @escaping @MainActor (RepoRegistration) async throws -> Void = {
        try await OS1API.registerRepo($0)
    }) {
        self.post = post
    }

    var isBusy: Bool { pending != nil }

    func wasAdded(_ registration: RepoRegistration) -> Bool {
        added.contains(registration.id)
    }

    /// Send one registration. True when the server registered it. Refuses a
    /// second while one runs and one already added here, so a double tap never
    /// sends the same clone twice.
    @discardableResult
    func register(
        _ registration: RepoRegistration,
        onAdded: @MainActor () async -> Void = {}
    ) async -> Bool {
        guard pending == nil, !added.contains(registration.id) else { return false }
        pending = registration
        error = nil
        defer { pending = nil }
        do {
            try await post(registration)
        } catch {
            self.error = error.localizedDescription
            return false
        }
        added.insert(registration.id)
        await onAdded()
        return true
    }
}

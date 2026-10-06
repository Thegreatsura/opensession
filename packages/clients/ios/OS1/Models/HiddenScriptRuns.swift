import Foundation

/// Script run cards the viewer closed on this device. Hiding is a view
/// choice, not a state of the run, so it never reaches the server. Entries
/// expire after a week: ended cards leave on their own long before that, and
/// a running script hidden for longer has outlived anyone's memory of hiding
/// it.
///
/// Scoped to one server and account, so a run id from one configured server
/// never hides a card on another, and two people sharing a device keep their
/// own hides.
struct HiddenScriptRuns {
    static let ttl: TimeInterval = 7 * 24 * 60 * 60

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String) {
        self.defaults = defaults
        self.key = key
    }

    static func storageKey(server: String, user: String) -> String {
        "dev.tella.os1.hidden-script-runs.v1:\(server):\(user)"
    }

    /// The store for the account the app is signed in to right now.
    static var current: HiddenScriptRuns {
        let config = ServerConfig.shared
        let server = config.baseURL?.absoluteString ?? config.baseURLString
        let user = config.githubLogin.isEmpty ? config.userName : config.githubLogin
        return HiddenScriptRuns(key: storageKey(server: server, user: user))
    }

    /// The hides still in force: run id → when it was hidden.
    func load(at now: Date) -> [String: Date] {
        guard let stored = defaults.dictionary(forKey: key) else { return [:] }
        var hides: [String: Date] = [:]
        for (id, value) in stored {
            guard let seconds = (value as? NSNumber)?.doubleValue, seconds.isFinite else { continue }
            let at = Date(timeIntervalSince1970: seconds)
            if Self.inForce(at, now: now) { hides[id] = at }
        }
        return hides
    }

    /// Records the hide and drops every expired entry. Returns what is now in
    /// force, so the caller does not read the store twice.
    @discardableResult
    func hide(_ id: String, at now: Date) -> [String: Date] {
        var hides = load(at: now)
        hides[id] = now
        defaults.set(hides.mapValues { $0.timeIntervalSince1970 }, forKey: key)
        return hides
    }

    static func inForce(_ hiddenAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(hiddenAt) < ttl
    }
}

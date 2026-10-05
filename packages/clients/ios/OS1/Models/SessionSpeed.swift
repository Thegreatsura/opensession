import Foundation

/// Service speed for ChatGPT subscription runs, the server's `SessionSpeed`
/// (`packages/core/protocol/src/session.ts`). "fast" is OpenAI's priority
/// tier; "ultrafast" is served only for the model the catalog marks
/// `ultrafastSupported` and only on a Pro $500 ("promax") login.
enum SessionSpeed: String, CaseIterable, Identifiable, Sendable {
    case standard, fast, ultrafast

    var id: String { rawValue }

    /// Same wording as the web menu.
    var label: String {
        switch self {
        case .standard: "Standard"
        case .fast: "Fast"
        case .ultrafast: "Ultrafast"
        }
    }

    var symbol: String {
        switch self {
        case .standard: "gauge.with.needle"
        case .fast: "bolt"
        case .ultrafast: "bolt.fill"
        }
    }

    /// The legacy boolean older servers and saved sessions carry.
    var fastMode: Bool { self != .standard }

    /// A session's speed. Records and servers from before `speed` existed
    /// carry only `fastMode`, which still means Fast.
    init(speed: String?, fastMode: Bool?) {
        self = speed.flatMap(Self.init(rawValue:)) ?? (fastMode == true ? .fast : .standard)
    }
}

/// The speed a session is set to, as this build understands it, plus the
/// server's own value when it is one this build cannot name. A send echoes
/// the stored speed back, so an unknown value is kept off the wire until
/// the person picks a speed here: the legacy `fastMode: true` alone never
/// downgrades a faster stored tier on the server.
struct SpeedSetting: Equatable, Sendable {
    var speed: SessionSpeed
    /// A `speed` from a newer server that this build does not know.
    var unknownWire: String?

    init(_ speed: SessionSpeed = .standard) {
        self.speed = speed
        unknownWire = nil
    }

    init(speed raw: String?, fastMode: Bool?) {
        speed = SessionSpeed(speed: raw, fastMode: fastMode)
        unknownWire = raw.flatMap { SessionSpeed(rawValue: $0) == nil ? $0 : nil }
    }

    /// `speed` for a payload; nil leaves the stored value alone.
    var wireSpeed: String? { unknownWire == nil ? speed.rawValue : nil }
    /// `fastMode` mirror for servers that predate `speed`.
    var wireFastMode: Bool { unknownWire != nil || speed.fastMode }
}

/// Which speeds the model menu offers, and the account each faster tier
/// would pin. Mirrors the web `ModelEffortSelect` rules.
struct SpeedChoices: Equatable, Sendable {
    /// ChatGPT plan that serves Ultrafast (Pro $500).
    static let ultrafastPlan = "promax"

    var fast = false
    var ultrafast = false
    /// What picking Fast on Auto pins: the first usable subscription login.
    var subscriptionAccount: ProviderAccount?
    /// What picking Ultrafast on Auto pins: a usable Pro $500 login.
    var ultrafastAccount: ProviderAccount?

    var options: [SessionSpeed] {
        [.standard] + (fast ? [.fast] : []) + (ultrafast ? [.ultrafast] : [])
    }

    /// Nothing but Standard to pick, so the menu hides the row.
    var isEmpty: Bool { !fast }

    /// - Parameters:
    ///   - accounts: the model's own pool, already narrowed to accounts the
    ///     viewer may use. Empty means the pool is not known yet (or the
    ///     server predates account listing); Fast then follows the catalog
    ///     alone, while Ultrafast still needs a Pro $500 login it can see.
    ///   - accountId: the pinned account, "" for Auto.
    init(model: ModelOption?, accounts: [ProviderAccount], accountId: String) {
        guard model?.fastModeSupported == true else { return }
        let pinned = accountId.isEmpty ? nil : accounts.first { $0.id == accountId }
        subscriptionAccount = accounts.first { $0.kind != "api_key" && $0.usable != false }
        ultrafastAccount = accounts.first(where: Self.servesUltrafast)
        if let pinned {
            fast = pinned.kind != "api_key"
            ultrafast = fast && model?.ultrafastSupported == true && pinned.plan == Self.ultrafastPlan
        } else if !accountId.isEmpty {
            // Pinned to an account this list does not carry (still loading,
            // or another viewer's): it is not provably an API key.
            fast = true
        } else {
            fast = accounts.isEmpty || subscriptionAccount != nil
            ultrafast = fast && model?.ultrafastSupported == true && ultrafastAccount != nil
        }
    }

    init() {}

    static func servesUltrafast(_ account: ProviderAccount) -> Bool {
        account.plan == ultrafastPlan && account.kind != "api_key" && account.usable != false
    }

    /// What the next turn runs at: a stored tier the current model, pin or
    /// pool cannot serve reads one step down. The stored value is untouched.
    func effective(_ speed: SessionSpeed) -> SessionSpeed {
        switch speed {
        case .ultrafast where ultrafast: .ultrafast
        case .ultrafast, .fast: fast ? .fast : .standard
        case .standard: .standard
        }
    }

    /// The account to pin when `speed` is picked while on Auto, so the turn
    /// runs on the login that can actually serve it.
    func pin(for speed: SessionSpeed, accountId: String) -> ProviderAccount? {
        guard accountId.isEmpty else { return nil }
        switch speed {
        case .standard: return nil
        case .fast: return subscriptionAccount
        case .ultrafast: return ultrafastAccount
        }
    }

    /// The speed to keep after switching to `next`: Ultrafast exists on one
    /// model, so others keep Fast where they have it.
    static func afterModelChange(_ speed: SessionSpeed, next: ModelOption?) -> SessionSpeed {
        guard speed != .standard, let next, next.fastModeSupported == true else {
            return .standard
        }
        if speed == .ultrafast, next.ultrafastSupported != true { return .fast }
        return speed
    }

    /// The speed to keep after pinning `account` (nil = Auto). An API key
    /// carries no subscription tier; only a Pro $500 login serves Ultrafast.
    static func afterPin(_ speed: SessionSpeed, account: ProviderAccount?) -> SessionSpeed {
        guard let account else { return speed }
        if account.kind == "api_key" { return .standard }
        if speed == .ultrafast, account.plan != ultrafastPlan { return .fast }
        return speed
    }

    /// The model's pool as `init` wants it: accounts from the pool the
    /// model spends from that `viewer` may use.
    static func pool(
        for model: String, catalog: ModelCatalog?, accounts: [PooledAccount], viewer: String
    ) -> [ProviderAccount] {
        guard let kind = WeeklyRemaining.provider(forModel: model, catalog: catalog) else { return [] }
        return accounts
            .filter { $0.kind == kind && WeeklyRemaining.isAvailable($0.account, to: viewer) }
            .map(\.account)
    }
}

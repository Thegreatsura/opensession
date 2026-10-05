import Observation
import SwiftUI

/// One of the shared swatches a person can tint a sidebar row with.
///
/// The KEYS are the contract with the web (`TAB_COLORS` in
/// src/frontend/lib/tab-colors.ts, validated by src/server/tab-colors.ts); the
/// colours are not. Each swatch draws in the platform's own system colour, so
/// it adapts to light and dark, to Increase Contrast, and to the iOS and macOS
/// palettes instead of carrying the browser's hex values across.
enum RowColor: String, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, blue, purple, pink

    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        }
    }

    /// How strongly the row is washed. The web mixes 13% of its swatch into
    /// a dark sidebar; the system colours are brighter and the iOS list sits
    /// on a lighter plate, so each surface takes its own calibrated amount.
    static var washOpacity: Double {
        #if os(iOS)
        0.16
        #else
        0.13
        #endif
    }
}

/// Per-user sidebar row colours, in the same per-user map the web keeps its
/// session tab colours in (`GET/PUT /api/tab-colors`). Row entries live under
/// `row:<row key>` so a row's colour never also paints a tab that happens to
/// share its id (`src/frontend/lib/row-colors.ts`).
///
/// The whole map is held, tab colours and unknown keys included, and writes
/// are per-key deltas, so this client can never erase an entry another one
/// made. Shaped like `HideStore`: local intent survives an older hydrate.
@Observable
@MainActor
final class RowColorStore {
    static let shared = RowColorStore()

    /// Every entry in the map: `row:<key>` and bare session ids alike.
    private(set) var colors: [String: String] = [:]

    enum Change: Equatable {
        case set(String)
        case remove
    }

    private var pendingChanges: [String: Change] = [:]
    private var hydratedContext: NativePreferences.Context?
    private(set) var hasHydrated = false
    private var isSaving = false
    private var hydrations = HydrationClock()

    init() {}

    nonisolated static func storeKey(_ rowKey: String) -> String { "row:\(rowKey)" }

    /// The swatch stored for a row key, or nil when none (or one this build
    /// does not know) is.
    nonisolated static func color(
        forRowKey rowKey: String,
        in colors: [String: String]
    ) -> RowColor? {
        colors[storeKey(rowKey)].flatMap(RowColor.init(rawValue:))
    }

    func color(for workspace: SidebarWorkspace) -> RowColor? {
        Self.color(forRowKey: SidebarRowKeys.sharedRowKey(for: workspace), in: colors)
    }

    func setColor(_ color: RowColor?, for workspace: SidebarWorkspace) {
        let rowKey = SidebarRowKeys.sharedRowKey(for: workspace)
        guard SidebarRowKeys.isPersistable(rowKey) else { return }
        let key = Self.storeKey(rowKey)
        if let color {
            guard colors[key] != color.rawValue else { return }
            colors[key] = color.rawValue
            pendingChanges[key] = .set(color.rawValue)
        } else {
            guard colors[key] != nil else { return }
            colors.removeValue(forKey: key)
            pendingChanges[key] = .remove
        }
        save()
    }

    func hydrate() async {
        let requestContext = NativePreferences.context()
        resetForNewContext(requestContext)
        let ticket = hydrations.begin()
        guard let loaded = try? await SettingsAPI.tabColors(user: requestContext.user) else {
            return
        }
        guard NativePreferences.context() == requestContext else { return }
        applyHydrated(loaded, ticket: ticket)
    }

    private func resetForNewContext(_ context: NativePreferences.Context) {
        guard let hydratedContext else {
            self.hydratedContext = context
            return
        }
        guard hydratedContext != context else { return }
        self.hydratedContext = context
        colors = [:]
        pendingChanges.removeAll()
        hasHydrated = false
        isSaving = false
    }

    /// Internal for tests: the server's map with this device's unsent intent
    /// laid over it.
    func applyHydrated(
        _ loaded: [String: String],
        ticket: HydrationClock.Ticket? = nil,
        persist: Bool = true
    ) {
        if let ticket, !hydrations.isCurrent(ticket) { return }
        colors = Self.merged(loaded, pending: pendingChanges)
        hasHydrated = true
        if persist, !pendingChanges.isEmpty { save() }
    }

    nonisolated static func merged(
        _ loaded: [String: String],
        pending: [String: Change]
    ) -> [String: String] {
        var merged = loaded
        for (key, change) in pending {
            switch change {
            case .set(let value): merged[key] = value
            case .remove: merged.removeValue(forKey: key)
            }
        }
        return merged
    }

    private func save() {
        guard hasHydrated,
              !isSaving,
              !pendingChanges.isEmpty,
              let requestContext = hydratedContext,
              NativePreferences.context() == requestContext else { return }
        let captured = pendingChanges
        let set = captured.compactMapValues { change -> String? in
            if case .set(let value) = change { return value }
            return nil
        }
        let remove = captured.compactMap { key, change in
            if case .remove = change { return key }
            return nil
        }
        let mark = hydrations.mark()
        isSaving = true
        Task { [weak self] in
            let saved = try? await SettingsAPI.saveTabColors(
                user: requestContext.user,
                set: set,
                remove: remove
            )
            guard let self,
                  self.hydratedContext == requestContext,
                  NativePreferences.context() == requestContext else { return }
            self.isSaving = false
            guard let saved else { return }
            for (key, change) in captured where self.pendingChanges[key] == change {
                self.pendingChanges.removeValue(forKey: key)
            }
            let needsHydration = self.hydrations.hasHydrationBegun(since: mark)
            self.hydrations.confirmWrite()
            if needsHydration {
                await self.hydrate()
            } else {
                self.applyHydrated(saved, persist: false)
            }
            self.save()
        }
    }
}

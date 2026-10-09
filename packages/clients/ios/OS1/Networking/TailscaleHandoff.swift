import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Switching Tailscale accounts when switching organizations.
///
/// iOS gives an app no way to see or change another app's VPN, so the switch
/// itself always happens in Tailscale. This decides when to ask for it and
/// how: a Shortcuts shortcut the person set up (which switches and opens this
/// app again), or Tailscale itself.
@MainActor
enum TailscaleHandoff {
    private static let reachedDefaultsKey = "os1.lastReachedTailnet"

    /// Tailscale's App Store id, the fallback when its own URL doesn't open.
    nonisolated static let appStoreURL = URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!
    nonisolated static let appURL = URL(string: "tailscale://")!

    /// What identifies an account's tailnet: the name the person gave it, or
    /// the tailnet part of a MagicDNS server name (`host.tail1234.ts.net`).
    nonisolated static func tailnetKey(for account: ServerAccount) -> String? {
        if let named = account.tailscaleAccount?.trimmingCharacters(in: .whitespaces),
           !named.isEmpty {
            return named.lowercased()
        }
        return magicDNSTailnet(account.url)
    }

    nonisolated static func magicDNSTailnet(_ raw: String) -> String? {
        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        guard let host = URL(string: candidate)?.host()?.lowercased(),
              Reachability.isTailnetHostname(host)
        else { return nil }
        let labels = host.split(separator: ".")
        guard labels.count >= 4 else { return nil }
        return labels.dropFirst().joined(separator: ".")
    }

    /// The name to show in "Switch Tailscale to …".
    nonisolated static func displayName(for account: ServerAccount) -> String? {
        if let named = account.tailscaleAccount?.trimmingCharacters(in: .whitespaces),
           !named.isEmpty {
            return named
        }
        return magicDNSTailnet(account.url)
    }

    /// The tailnet this device last reached a server on. A successful load
    /// proves which account Tailscale is on; nothing else can tell us.
    static var lastReachedTailnet: String? {
        UserDefaults.standard.string(forKey: reachedDefaultsKey)
    }

    static func noteReached(_ account: ServerAccount) {
        guard let key = tailnetKey(for: account) else { return }
        UserDefaults.standard.set(key, forKey: reachedDefaultsKey)
    }

    /// True when `account` needs a different Tailscale account than the one
    /// this device was last on.
    static func needsSwitch(to account: ServerAccount) -> Bool {
        guard let wanted = tailnetKey(for: account), let current = lastReachedTailnet else {
            return false
        }
        return wanted != current
    }

    /// The person's shortcut, run through the Shortcuts app.
    nonisolated static func shortcutURL(for account: ServerAccount) -> URL? {
        guard let name = account.tailscaleShortcut?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty
        else { return nil }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }

    /// Where the switch button goes: the shortcut when there is one, else
    /// Tailscale.
    nonisolated static func switchURL(for account: ServerAccount) -> URL {
        shortcutURL(for: account) ?? appURL
    }

    /// Send the person to make the switch: their shortcut, else Tailscale,
    /// else Tailscale's App Store page when it isn't installed.
    static func open(for account: ServerAccount) {
        let primary = switchURL(for: account)
        launch(primary) { opened in
            if !opened, primary != appStoreURL { launch(appStoreURL) { _ in } }
        }
    }

    /// Run the shortcut on an organization switch that needs another
    /// Tailscale account. Without a shortcut nothing happens here: the list
    /// says what to do once it can't reach the server.
    static func switchIfNeeded(to account: ServerAccount) {
        guard needsSwitch(to: account), let url = shortcutURL(for: account) else { return }
        launch(url) { _ in }
    }

    private static func launch(_ url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        #if os(iOS)
        UIApplication.shared.open(url) { opened in
            Task { @MainActor in completion(opened) }
        }
        #else
        completion(NSWorkspace.shared.open(url))
        #endif
    }
}

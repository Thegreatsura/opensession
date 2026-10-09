import Foundation

/// Why a request never reached the server, in words that name the fix.
///
/// An Open Session server usually sits on a tailnet, and a device that has dropped off
/// it gets no refusal: packets addressed to a 100.x node go nowhere, so
/// URLSession waits out its full timeout and reports "The request timed out."
/// That reads as a broken server when the truth is a switched-off VPN — so
/// everything that surfaces a network error asks here for the wording first.
@MainActor
enum Reachability {

    // MARK: - Tailscale's address space

    /// Tailscale numbers every node out of 100.64.0.0/10 — the CGNAT range —
    /// and out of fd7a:115c:a1e0::/48, and uses nothing else. An address in
    /// either range marks one end of a connection as living on a tailnet.
    nonisolated static func isTailnetIPv4(_ address: UInt32) -> Bool {
        address & 0xFFC0_0000 == 0x6440_0000
    }

    nonisolated static func isTailnetIPv6(_ address: [UInt8]) -> Bool {
        address.prefix(6).elementsEqual([0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0])
    }

    /// MagicDNS names — `host.tailnet-name.ts.net` — resolve on the tailnet
    /// and nowhere else, so the name settles it without a lookup (which is
    /// just as well: off the tailnet the lookup fails).
    nonisolated static func isTailnetHostname(_ host: String) -> Bool {
        host.lowercased().hasSuffix(".ts.net")
    }

    // MARK: - Diagnosis

    /// What to show for a failed request: the tailnet diagnosis when it
    /// applies, the system's own wording otherwise.
    static func describe(_ error: Error) async -> String {
        guard blamesTheNetwork(error), let hint = await tailnetHint() else {
            return error.localizedDescription
        }
        return hint
    }

    /// A failed request in the terms a screen needs: a headline naming the
    /// problem, a sentence naming the fix where there is one, the system's
    /// own words for the places that want them, and whether nothing came back
    /// at all.
    ///
    /// `isConnection` decides what the screen offers. A request that never
    /// left the device is fixed out here — a VPN toggle, a signal, a wait —
    /// so retrying is the whole answer; anything else the server said back is
    /// a different conversation.
    ///
    /// `fix` is deliberately not the error's own wording. "The request timed
    /// out" and "a server with the specified hostname could not be found"
    /// are the same news to anyone who isn't debugging: the difference that
    /// matters is that one wants patience and the other wants a corrected
    /// address, and that is what this says instead.
    struct Diagnosis: Equatable, Sendable {
        let title: String
        let fix: String?
        let detail: String
        let isConnection: Bool
        /// The single thing worth offering. A screen that lists every door it
        /// knows about — retry, settings, help — makes the reader choose
        /// between them; the diagnosis already knows which one is the answer,
        /// so it says so and the screen shows that one.
        var remedy: Remedy = .retry
    }

    enum Remedy: Equatable, Sendable {
        /// Wait it out: the connection is the problem, and the list polls
        /// anyway — the button is for the person who just fixed their end.
        case retry
        /// The server address or the token is what's wrong, and neither
        /// heals by being asked again.
        case settings
        /// The fix is in Tailscale: turn it on, or switch its account.
        case tailscale
    }

    static func diagnose(_ error: Error) async -> Diagnosis {
        let code = (error as? URLError)?.code
        // Nothing was ever going to be reached: no server set, or one that
        // won't have us. Retrying is theatre — the fix is in Settings.
        if let api = error as? OS1API.APIError {
            switch api {
            case .notConfigured:
                return Diagnosis(
                    title: "No server yet",
                    fix: "Add your \(AppBrand.productName) server and token in Settings.",
                    detail: api.localizedDescription,
                    isConnection: false,
                    remedy: .settings
                )
            case .http(401):
                return Diagnosis(
                    title: "Not signed in",
                    fix: "Check your access token in Settings.",
                    detail: api.localizedDescription,
                    isConnection: false,
                    remedy: .settings
                )
            default:
                break
            }
        }
        // "Offline" is its own headline: no server is reachable, so naming
        // this one would be beside the point.
        if code == .notConnectedToInternet {
            return Diagnosis(
                title: "No internet connection",
                fix: "Reconnect, then try again.",
                detail: error.localizedDescription,
                isConnection: true
            )
        }
        // A server set as http:// on a remote host never leaves the device:
        // App Transport Security stops it, and says so in a sentence about
        // policy that names neither the server nor the scheme that fixes it.
        if code == .appTransportSecurityRequiresSecureConnection {
            return Diagnosis(
                title: "This server needs HTTPS",
                fix: "It's set as http://. Change it to https:// in Settings.",
                detail: error.localizedDescription,
                isConnection: false,
                remedy: .settings
            )
        }
        guard blamesTheNetwork(error) else {
            return Diagnosis(
                title: "Couldn't load",
                fix: nil,
                detail: error.localizedDescription,
                isConnection: false
            )
        }
        // Ahead of the name check on purpose: a MagicDNS name stops
        // resolving when the tunnel drops, and "check the address" is the
        // wrong advice for an address that is perfectly correct.
        if let tailnet = await tailnetDiagnosis() { return tailnet }
        // On a tailnet, but not reaching a server that lives on one: the
        // likeliest cause is Tailscale signed in to another account.
        if deviceIsOnTailnet(),
           let target = TailscaleHandoff.displayName(for: ServerConfig.shared.activeAccount) {
            return wrongTailnet(target)
        }
        if code == .cannotFindHost || code == .dnsLookupFailed {
            return Diagnosis(
                title: "Can't find that server",
                fix: "Check the server address in Settings.",
                detail: error.localizedDescription,
                isConnection: true,
                remedy: .settings
            )
        }
        return Diagnosis(
            title: "Can't reach the server",
            fix: nil,
            detail: error.localizedDescription,
            isConnection: true
        )
    }

    /// The tailnet diagnosis on its own, for callers holding no error yet —
    /// the sessions list asks while its first request is still in flight,
    /// because a minute of spinner is a long way to go to be told "timed out".
    ///
    /// Two cases, both needing Tailscale: this device is off the tailnet, or
    /// it is on the tailnet of the organization it last reached and this one
    /// lives on another (switching organizations does not switch Tailscale).
    static func tailnetDiagnosis() async -> Diagnosis? {
        let account = ServerConfig.shared.activeAccount
        let target = TailscaleHandoff.displayName(for: account)
        if let hint = await tailnetHint() {
            return Diagnosis(
                title: hint,
                fix: target.map { "This server answers on the \($0) tailnet. Turn Tailscale on, then come back." }
                    ?? "This server only answers on your tailnet. Turn Tailscale on, then try again.",
                detail: "The server is on a tailnet this device isn't on.",
                isConnection: true,
                remedy: .tailscale
            )
        }
        guard deviceIsOnTailnet(), let target, TailscaleHandoff.needsSwitch(to: account) else {
            return nil
        }
        return wrongTailnet(target)
    }

    private static func wrongTailnet(_ target: String) -> Diagnosis {
        Diagnosis(
            title: "Switch Tailscale to \(target)",
            fix: "This organization is on another Tailscale account. Switch in Tailscale, then come back.",
            detail: "Tailscale is connected to a different account.",
            isConnection: true,
            remedy: .tailscale
        )
    }

    /// The tailnet diagnosis as one line, for the places that have room for
    /// one — a banner, a settings check.
    ///
    /// Four words on purpose: naming the host or explaining tailnets adds
    /// nothing to do, because the fix is the VPN toggle either way.
    static func tailnetHint() async -> String? {
        guard let host = ServerConfig.shared.baseURL?.host(), !host.isEmpty,
              !deviceIsOnTailnet(),
              await serverIsOnTailnet(host)
        else { return nil }
        return "Not connected to Tailscale"
    }

    /// Errors that mean nothing came back. A refusal, a TLS failure or any
    /// HTTP status proves packets made the trip, so those keep their own
    /// wording — and so does "the Internet connection appears to be offline",
    /// which is already the whole story.
    nonisolated static func blamesTheNetwork(_ error: Error) -> Bool {
        switch (error as? URLError)?.code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .networkConnectionLost:
            true
        default:
            false
        }
    }

    // MARK: - This device

    /// Is one of our own interfaces on a tailnet? Carriers hand out 100.x
    /// addresses too — CGNAT is not Tailscale's alone, and a phone on cellular
    /// usually has one — so a v4 address only counts on a tunnel interface.
    /// The fd7a prefix is Tailscale's own and counts anywhere.
    nonisolated static func deviceIsOnTailnet() -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return false }
        defer { freeifaddrs(head) }
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = interface.pointee.ifa_addr else { continue }
            let tunnel = String(cString: interface.pointee.ifa_name).hasPrefix("utun")
            if isTailnetAddress(address, countingIPv4: tunnel) { return true }
        }
        return false
    }

    // MARK: - The server

    private static var tailnetHosts: [String: (answer: Bool, asked: Date)] = [:]

    /// Does the server's name land on a tailnet? A tailnet-only host still
    /// publishes its address, so this resolves from anywhere — including with
    /// the tunnel down, which is exactly when it's asked. Cached: the answer
    /// only changes when the server moves.
    private static func serverIsOnTailnet(_ host: String) async -> Bool {
        if isTailnetHostname(host) { return true }
        if let cached = tailnetHosts[host], Date().timeIntervalSince(cached.asked) < 300 {
            return cached.answer
        }
        let answer = await Task.detached(priority: .utility) {
            resolvesOntoTailnet(host)
        }.value
        tailnetHosts[host] = (answer, Date())
        return answer
    }

    /// Blocking name resolution — always off the main actor.
    private nonisolated static func resolvesOntoTailnet(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0, let first = head else { return false }
        defer { freeaddrinfo(head) }
        return sequence(first: first, next: { $0.pointee.ai_next }).contains {
            guard let address = $0.pointee.ai_addr else { return false }
            return isTailnetAddress(address, countingIPv4: true)
        }
    }

    private nonisolated static func isTailnetAddress(
        _ address: UnsafePointer<sockaddr>,
        countingIPv4: Bool
    ) -> Bool {
        switch Int32(address.pointee.sa_family) {
        case AF_INET where countingIPv4:
            address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                isTailnetIPv4(UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
            }
        case AF_INET6:
            address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                withUnsafeBytes(of: pointer.pointee.sin6_addr) {
                    isTailnetIPv6(Array($0.prefix(6)))
                }
            }
        default:
            false
        }
    }
}

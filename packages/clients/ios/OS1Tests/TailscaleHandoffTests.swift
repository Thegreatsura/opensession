import XCTest
@testable import OS1

final class TailscaleHandoffTests: XCTestCase {
    private func account(
        url: String,
        tailscale: String? = nil,
        shortcut: String? = nil
    ) -> ServerAccount {
        ServerAccount(
            id: "a",
            label: "Acme",
            url: url,
            userName: "ios",
            githubLogin: "",
            tailscaleAccount: tailscale,
            tailscaleShortcut: shortcut
        )
    }

    func testMagicDNSNameGivesTheTailnet() {
        XCTAssertEqual(
            TailscaleHandoff.magicDNSTailnet("https://box.tail1234.ts.net"),
            "tail1234.ts.net"
        )
        XCTAssertEqual(TailscaleHandoff.magicDNSTailnet("box.tail1234.ts.net:3850"), "tail1234.ts.net")
        XCTAssertNil(TailscaleHandoff.magicDNSTailnet("https://sessions.example.test"))
    }

    func testANamedAccountWinsOverTheHost() {
        let named = account(url: "https://box.tail1234.ts.net", tailscale: "Acme.test")
        XCTAssertEqual(TailscaleHandoff.tailnetKey(for: named), "acme.test")
        XCTAssertEqual(TailscaleHandoff.displayName(for: named), "Acme.test")
        XCTAssertNil(TailscaleHandoff.tailnetKey(for: account(url: "https://example.test")))
    }

    func testShortcutURLRunsTheNamedShortcut() {
        let url = TailscaleHandoff.shortcutURL(for: account(url: "", shortcut: "Tailscale Acme"))
        XCTAssertEqual(url?.absoluteString, "shortcuts://run-shortcut?name=Tailscale%20Acme")
        XCTAssertNil(TailscaleHandoff.shortcutURL(for: account(url: "", shortcut: "  ")))
        XCTAssertEqual(
            TailscaleHandoff.switchURL(for: account(url: "")),
            TailscaleHandoff.appURL
        )
    }

    func testAccountsSavedBeforeTailscaleFieldsStillDecode() throws {
        let json = #"[{"id":"a","label":"Acme","url":"https://x","userName":"u","githubLogin":""}]"#
        let decoded = try JSONDecoder().decode([ServerAccount].self, from: Data(json.utf8))
        XCTAssertNil(decoded[0].tailscaleAccount)
        XCTAssertNil(decoded[0].tailscaleShortcut)
    }
}

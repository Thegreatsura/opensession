import XCTest
@testable import OS1

final class AccountShortcutsTests: XCTestCase {
    func testCodecCanonicalizesAliasesOrderAndDuplicates() {
        let shortcuts = AccountShortcuts(rawValue: """
        {"session-new":["shift+CMD+n","mod+shift+n","option+control+k"]}
        """)

        XCTAssertEqual(
            shortcuts.rawValue,
            #"{"session-new":["mod+shift+n","ctrl+alt+k"]}"#
        )
    }

    func testCodecDropsMalformedEntriesButPreservesFutureBindings() {
        let shortcuts = AccountShortcuts(rawValue: """
        {
          "future-command":["mod+f7"],
          "session-new":["n","shift+n","mod+banana","mod+n+x",42]
        }
        """)

        XCTAssertEqual(
            shortcuts.rawValue,
            #"{"future-command":["mod+f7"],"session-new":["n","shift+n","mod+banana"]}"#
        )
    }

    func testMalformedJSONFallsBackToNoOverrides() {
        XCTAssertEqual(AccountShortcuts.validatedRawValue("[1,2,3]"), "{}")
        XCTAssertEqual(AccountShortcuts.validatedRawValue("{"), "{}")
        XCTAssertEqual(AccountShortcuts.validatedRawValue(nil), "{}")
    }

    func testAbsentOverrideUsesNativeDefaultAndEmptyOverrideUnassigns() {
        var shortcuts = AccountShortcuts(rawValue: "{}")
        XCTAssertEqual(shortcuts.primaryBinding(for: .newSession)?.rawValue, "mod+n")

        shortcuts.removeBindings(for: .newSession)
        XCTAssertNil(shortcuts.primaryBinding(for: .newSession))

        shortcuts.reset(.newSession)
        XCTAssertEqual(shortcuts.primaryBinding(for: .newSession)?.rawValue, "mod+n")
    }

    func testReopenArchivedSkipsTheWebsTextUndoDefault() {
        XCTAssertEqual(
            AccountShortcuts(rawValue: "{}").primaryBinding(for: .reopenArchived)?.rawValue,
            "mod+shift+t"
        )
        // The web registry's defaults, if ever written as an override: Command-Z
        // stays text undo on the Mac, so the native binding is the alias.
        let web = AccountShortcuts(rawValue: #"{"session-reopen":["mod+z","mod+shift+t"]}"#)
        XCTAssertEqual(web.primaryBinding(for: .reopenArchived)?.rawValue, "mod+shift+t")
    }

    func testSettingPrimaryKeepsExistingAliases() {
        var shortcuts = AccountShortcuts(rawValue: #"{"command-menu":["mod+k","ctrl+k"]}"#)
        let replacement = AccountShortcutChord(rawValue: "mod+shift+p")!

        shortcuts.setPrimaryBinding(replacement, for: .commandMenu)

        XCTAssertEqual(
            shortcuts.bindings(for: .commandMenu).map(\.rawValue),
            ["mod+shift+p", "mod+k", "ctrl+k"]
        )
    }

    func testMatchingIsExactOnKeyAndModifiers() {
        let shortcuts = AccountShortcuts(rawValue: #"{"command-menu":["mod+shift+k"]}"#)

        XCTAssertTrue(shortcuts.matches(.commandMenu, key: "k", modifiers: [.command, .shift]))
        XCTAssertFalse(shortcuts.matches(.commandMenu, key: "k", modifiers: [.command]))
        XCTAssertFalse(shortcuts.matches(.commandMenu, key: "k", modifiers: [.command, .shift, .option]))
        XCTAssertFalse(shortcuts.matches(.commandMenu, key: "j", modifiers: [.command, .shift]))
    }

    func testGlyphsFollowAppleModifierOrder() {
        let chord = AccountShortcutChord(rawValue: "shift+option+ctrl+cmd+arrowup")
        XCTAssertEqual(chord?.rawValue, "mod+ctrl+alt+shift+arrowup")
        XCTAssertEqual(chord?.glyphs, ["⌘", "⌃", "⌥", "⇧", "↑"])
    }

    func testNativeMatchingSkipsUnsupportedAndReservedPrimaryBindings() {
        let unsupported = AccountShortcuts(rawValue: #"{"command-menu":["mod+banana","mod+j"]}"#)
        XCTAssertEqual(unsupported.primaryBinding(for: .commandMenu)?.rawValue, "mod+j")

        let reserved = AccountShortcuts(rawValue: #"{"command-menu":["mod+q","mod+j"]}"#)
        XCTAssertEqual(reserved.primaryBinding(for: .commandMenu)?.rawValue, "mod+j")
    }
}

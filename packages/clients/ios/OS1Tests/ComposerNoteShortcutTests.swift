import XCTest
@testable import OS1

final class ComposerNoteShortcutTests: XCTestCase {
    // MARK: - Binding

    func testDefaultIsCommandShiftNBesideNewSession() {
        let shortcuts = AccountShortcuts(rawValue: "{}")
        XCTAssertEqual(AccountShortcutCommand.composerNote.rawValue, "composer-note")
        XCTAssertEqual(shortcuts.primaryBinding(for: .composerNote)?.rawValue, "mod+shift+n")
        XCTAssertEqual(shortcuts.primaryBinding(for: .composerNote)?.label, "⌘⇧N")
        XCTAssertTrue(shortcuts.matches(.composerNote, key: "n", modifiers: [.command, .shift]))
        XCTAssertFalse(shortcuts.matches(.composerNote, key: "n", modifiers: [.command]))
        // New session commands keep their own chords.
        XCTAssertEqual(shortcuts.primaryBinding(for: .newSession)?.rawValue, "mod+n")
        XCTAssertEqual(shortcuts.primaryBinding(for: .newSessionInWorkspace)?.rawValue, "mod+alt+n")
    }

    func testDefaultsDoNotCollide() {
        let shortcuts = AccountShortcuts(rawValue: "{}")
        let chords = AccountShortcutCommand.allCases.compactMap { shortcuts.primaryBinding(for: $0) }
        XCTAssertEqual(chords.count, AccountShortcutCommand.allCases.count)
        XCTAssertEqual(Set(chords).count, chords.count)
    }

    func testSharedAccountOverrideRebinds() {
        let shortcuts = AccountShortcuts(rawValue: #"{"composer-note":["ctrl+alt+n"]}"#)
        XCTAssertEqual(shortcuts.primaryBinding(for: .composerNote)?.rawValue, "ctrl+alt+n")
        XCTAssertTrue(shortcuts.matches(.composerNote, key: "n", modifiers: [.control, .option]))
        XCTAssertFalse(shortcuts.matches(.composerNote, key: "n", modifiers: [.command, .shift]))
        XCTAssertNotNil(shortcuts.keyboardShortcut(for: .composerNote))
    }

    func testRebindingFromSettingsKeepsOtherAndUnknownOverrides() {
        var shortcuts = AccountShortcuts(rawValue: """
        {"future-command":["mod+f7"],"session-new":["mod+shift+o"]}
        """)
        shortcuts.setPrimaryBinding(AccountShortcutChord(rawValue: "mod+alt+t")!, for: .composerNote)
        XCTAssertEqual(
            shortcuts.rawValue,
            #"{"composer-note":["mod+alt+t"],"future-command":["mod+f7"],"session-new":["mod+shift+o"]}"#
        )

        shortcuts.resetSupportedCommands()
        XCTAssertEqual(shortcuts.rawValue, #"{"future-command":["mod+f7"]}"#)
        XCTAssertEqual(shortcuts.primaryBinding(for: .composerNote)?.rawValue, "mod+shift+n")
    }

    func testEmptyOverrideDisablesTheCommand() {
        var shortcuts = AccountShortcuts(rawValue: #"{"composer-note":[]}"#)
        XCTAssertNil(shortcuts.primaryBinding(for: .composerNote))
        XCTAssertNil(shortcuts.keyboardShortcut(for: .composerNote))
        XCTAssertFalse(shortcuts.matches(.composerNote, key: "n", modifiers: [.command, .shift]))
        XCTAssertTrue(shortcuts.isCustomized(.composerNote))

        shortcuts.reset(.composerNote)
        XCTAssertEqual(shortcuts.primaryBinding(for: .composerNote)?.rawValue, "mod+shift+n")

        shortcuts.removeBindings(for: .composerNote)
        XCTAssertEqual(shortcuts.rawValue, #"{"composer-note":[]}"#)
    }

    func testUnusableWebBindingFallsThroughToTheNextOne() {
        let shortcuts = AccountShortcuts(rawValue: #"{"composer-note":["mod+q","n","mod+shift+m"]}"#)
        XCTAssertEqual(shortcuts.primaryBinding(for: .composerNote)?.rawValue, "mod+shift+m")
    }

    // MARK: - Routing

    private let front = ComposerNoteScope(
        windowIsKey: true, appIsActive: true, blockingOverlay: false, isRepeat: false
    )

    func testKeyWindowComposerTakesTheCommand() {
        XCTAssertTrue(front.takesCommand)
    }

    func testSiblingWindowsAndBackgroundAppIgnoreIt() {
        var sibling = front
        sibling.windowIsKey = false
        XCTAssertFalse(sibling.takesCommand, "only the key window's composer toggles")

        var background = front
        background.appIsActive = false
        XCTAssertFalse(background.takesCommand)
    }

    func testBlockingOverlaySuppressesIt() {
        var covered = front
        covered.blockingOverlay = true
        XCTAssertFalse(covered.takesCommand)
    }

    func testHeldChordFiresOnce() {
        var repeating = front
        repeating.isRepeat = true
        XCTAssertFalse(repeating.takesCommand)
    }
}

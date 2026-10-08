import Foundation

/// Whether one composer acts on the "Team note" command (`composer-note`,
/// ⌘⇧N by default). The menu command is app-wide; every open window hears it
/// and exactly one composer may toggle. The platform bridge reads these off
/// the composer's window, so the decision itself is unit-testable.
struct ComposerNoteScope: Equatable, Sendable {
    /// The composer's window is the key window.
    var windowIsKey: Bool
    /// The app is frontmost.
    var appIsActive: Bool
    /// A sheet, alert or app-modal window sits over the composer. The web
    /// equivalent is `blockingOverlayOpen()`.
    var blockingOverlay: Bool
    /// The keystroke that ran the command is an auto-repeat of a held chord.
    var isRepeat: Bool

    /// The composer toggles note mode and takes focus.
    var takesCommand: Bool {
        windowIsKey && appIsActive && !blockingOverlay && !isRepeat
    }
}

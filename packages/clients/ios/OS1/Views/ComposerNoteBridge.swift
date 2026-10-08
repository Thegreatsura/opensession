import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)
extension Notification.Name {
    /// View > Team Note (⌘⇧N by default). The menu and the command palette
    /// post it; only the composer in the key window answers.
    static let os1ComposerNote = Notification.Name("os1.composerNote")
}
#endif

extension View {
    /// Hears the account's "Team note" command for one session composer.
    ///
    /// On macOS the command is a menu item with the account binding; this
    /// installs a zero-sized view that knows the composer's window, so with
    /// two windows open only the key one toggles, and nothing toggles under a
    /// sheet or alert or on a held key's repeats. On iOS (an iPad keyboard)
    /// it is a hidden key command on the default chord; UIKit already routes
    /// key commands away from a view under a presented sheet, and `blocked`
    /// covers the composer's own sheets and alert.
    func composerNoteCommand(blocked: Bool, onToggle: @escaping () -> Void) -> some View {
        modifier(ComposerNoteCommand(blocked: blocked, onToggle: onToggle))
    }
}

private struct ComposerNoteCommand: ViewModifier {
    let blocked: Bool
    let onToggle: () -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        content.background {
            ComposerNoteMonitor(blocked: blocked, onToggle: onToggle)
                .frame(width: 0, height: 0)
        }
        #else
        content.background {
            Button("Team note", action: onToggle)
                .keyboardShortcut(
                    AccountShortcutCommand.composerNote.defaultChord.keyboardShortcut
                )
                .disabled(blocked)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        #endif
    }
}

#if os(macOS)
private struct ComposerNoteMonitor: NSViewRepresentable {
    let blocked: Bool
    let onToggle: () -> Void

    func makeNSView(context: Context) -> ComposerNoteMonitorView {
        let view = ComposerNoteMonitorView()
        view.blocked = blocked
        view.onToggle = onToggle
        return view
    }

    func updateNSView(_ view: ComposerNoteMonitorView, context: Context) {
        view.blocked = blocked
        view.onToggle = onToggle
    }

    static func dismantleNSView(_ view: ComposerNoteMonitorView, coordinator: ()) {
        view.uninstall()
    }
}

final class ComposerNoteMonitorView: NSView {
    var blocked = false
    var onToggle: () -> Void = {}

    private var observer: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            uninstall()
        } else if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .os1ComposerNote, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handle() }
            }
        }
    }

    func uninstall() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    private func handle() {
        guard let window else { return }
        let event = NSApp.currentEvent
        let scope = ComposerNoteScope(
            windowIsKey: window.isKeyWindow,
            appIsActive: NSApp.isActive,
            blockingOverlay: blocked || window.attachedSheet != nil || NSApp.modalWindow != nil,
            isRepeat: event?.type == .keyDown && event?.isARepeat == true
        )
        guard scope.takesCommand else { return }
        onToggle()
    }
}
#endif

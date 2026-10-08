import SwiftUI

extension View {
    /// Cmd+Enter submits a review sheet, the web's Finish review chord, from
    /// anywhere in the sheet including the summary field. Plain Return is
    /// untouched, so the summary still takes newlines.
    ///
    /// The chord rides its own never-drawn button rather than the toolbar's
    /// Submit, so it is independent of where the toolbar puts (or, in a Mac
    /// sheet, drops) that button. It lives inside the sheet, so it is only
    /// heard while the sheet's window is key, and `enabled` mirrors the
    /// visible Submit: a disabled or in-flight Submit swallows nothing and
    /// sends nothing. On an iPad it is listed in the hardware keyboard's
    /// Cmd HUD under its title.
    func reviewSubmitShortcut(enabled: Bool, action: @escaping () -> Void) -> some View {
        background {
            Button("Submit review", action: action)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!enabled)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// A Mac sheet makes its `.confirmationAction` button the default button,
    /// which plain Return presses whenever the summary is not focused. A
    /// review sends on Cmd+Enter only, so the visible Submit gives that up.
    func noDefaultReturnKey() -> some View {
        keyboardShortcut(nil)
    }
}

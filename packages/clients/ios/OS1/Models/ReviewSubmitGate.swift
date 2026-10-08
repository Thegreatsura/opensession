import Foundation

/// The one door both review sheets send through, whether the reviewer taps
/// Submit or presses Cmd+Enter (the web's Finish review chord).
///
/// A review is posted at most once per attempt: a press while one is in
/// flight, or while the Submit button would be disabled, sends nothing. A
/// failed attempt reopens the door so the reviewer can try again with their
/// text intact.
struct ReviewSubmitGate: Equatable {
    private(set) var inFlight = false

    /// GitHub takes a bare approval, but a comment or a change request with no
    /// body is nothing to post, and the server refuses it too.
    static func summaryAllows(event: String, summary: String) -> Bool {
        event == "APPROVE"
            || !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Claims the send. False, and nothing changes, when the Submit action is
    /// disabled, a send is already running, or the keypress is part of text
    /// composition (an input method's marked text owns Enter).
    mutating func begin(enabled: Bool, composing: Bool = false) -> Bool {
        guard enabled, !inFlight, !composing else { return false }
        inFlight = true
        return true
    }

    /// The request settled, success or failure.
    mutating func finish() {
        inFlight = false
    }
}

import Foundation

/// Markdown quote lines in a composer draft, for painting them the way they
/// read once sent: the quoted text dims and its `>` marker fades further. A
/// port of the web composer's `quoteLines` (lib/composer-highlight.ts), so a
/// pasted or quoted passage, such as an "Ask about this" note, is told apart
/// from the question typed under it.
///
/// Ranges are UTF-16, the unit TextKit paints in. Only colour is ever applied
/// over them, so the field keeps its text, glyph metrics and selection.
enum ComposerQuoteLines {
    struct Line: Equatable, Sendable {
        /// The whole line, marker included, newline excluded.
        let line: NSRange
        /// The optional indent and the `>`.
        let marker: NSRange
    }

    /// Past this the draft is pasted bulk, not something being written; the
    /// web skips its highlight mirror at the same size.
    static let maxLength = 8_000

    /// Lines starting with up to three spaces and `>`, outside ``` fences
    /// (closed, or still open while being typed). A `>` mid-line is not a
    /// quote.
    static func lines(in text: String) -> [Line] {
        let ns = text as NSString
        guard ns.length <= maxLength, ns.range(of: ">").location != NSNotFound else { return [] }
        var out: [Line] = []
        var inFence = false
        var at = 0
        while at <= ns.length {
            let rest = NSRange(location: at, length: ns.length - at)
            let newline = ns.range(of: "\n", options: .literal, range: rest)
            let end = newline.location == NSNotFound ? ns.length : newline.location
            let line = NSRange(location: at, length: end - at)
            let content = ns.substring(with: line)
            let fenceCount = content.components(separatedBy: "```").count - 1
            if !inFence, fenceCount == 0, let marker = marker(in: content) {
                out.append(Line(
                    line: line,
                    marker: NSRange(location: at, length: marker)
                ))
            }
            if fenceCount % 2 == 1 { inFence.toggle() }
            guard newline.location != NSNotFound else { break }
            at = end + 1
        }
        return out
    }

    /// UTF-16 length of `^( {0,3}>)` in a line, or nil.
    private static func marker(in line: String) -> Int? {
        var spaces = 0
        for unit in line.utf16 {
            if unit == 0x20, spaces < 3 { spaces += 1; continue }
            return unit == 0x3E ? spaces + 1 : nil
        }
        return nil
    }
}

import Foundation

/// Inline comment anchors: capturing a selection as words, and finding those
/// words again later. A port of the web's `lib/comment-anchor.ts` string half,
/// so an anchor made in either client points at the same words in the other.
///
/// Offsets and lengths are UTF-16 code units, the unit JavaScript strings and
/// `NSString`/TextKit ranges share, so the 32 characters of context mean the
/// same thing on both sides.
enum CommentAnchor {
    /// Characters of context kept either side of the passage.
    static let context = 32

    /// Build an anchor from a UTF-16 range of an entry's rendered text, or nil
    /// when the selection trims to fewer than two characters.
    static func anchor(text: String, range: NSRange, entryId: String) -> TextAnchor? {
        let ns = text as NSString
        var start = max(0, min(range.location, ns.length))
        var end = max(start, min(NSMaxRange(range), ns.length))
        // Trim the selection to its words: a drag often picks up the newline or
        // space at either end, and those make the anchor brittle for no gain.
        while start < end, isSpace(ns.character(at: start)) { start += 1 }
        while end > start, isSpace(ns.character(at: end - 1)) { end -= 1 }
        guard end - start >= 2 else { return nil }
        let before = max(0, start - context)
        return TextAnchor(
            entryId: entryId,
            exact: ns.substring(with: NSRange(location: start, length: end - start)),
            prefix: ns.substring(with: NSRange(location: before, length: start - before)),
            suffix: ns.substring(with: NSRange(location: end, length: min(context, ns.length - end)))
        )
    }

    /// An anchor for words with no surrounding text to read, such as a
    /// selection whose source view is gone. Locates by the words alone.
    static func anchor(exact: String, entryId: String) -> TextAnchor? {
        anchor(text: exact, range: NSRange(location: 0, length: (exact as NSString).length), entryId: entryId)
    }

    /// Where the anchor's words sit in `text`, or nil when they are gone. When
    /// the passage repeats, the occurrence whose surroundings best match the
    /// saved prefix and suffix wins, earliest first on a tie.
    static func locate(_ anchor: TextAnchor, in text: String) -> NSRange? {
        guard !anchor.exact.isEmpty else { return nil }
        let ns = text as NSString
        let exact = anchor.exact as NSString
        let prefix = anchor.prefix as NSString
        let suffix = anchor.suffix as NSString
        var best: (location: Int, score: Int)?
        var from = 0
        while from <= ns.length - exact.length {
            let found = ns.range(
                of: anchor.exact,
                options: [.literal],
                range: NSRange(location: from, length: ns.length - from)
            )
            guard found.location != NSNotFound else { break }
            let at = found.location
            let beforeStart = max(0, at - prefix.length)
            let before = ns.substring(with: NSRange(location: beforeStart, length: at - beforeStart))
            let afterStart = at + exact.length
            let after = ns.substring(with: NSRange(
                location: afterStart,
                length: min(suffix.length, ns.length - afterStart)
            ))
            let score = commonSuffix(before, anchor.prefix) + commonPrefix(after, anchor.suffix)
            if best == nil || score > best!.score { best = (at, score) }
            from = at + 1
        }
        return best.map { NSRange(location: $0.location, length: exact.length) }
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func commonSuffix(_ a: String, _ b: String) -> Int {
        let a = Array(a.utf16), b = Array(b.utf16)
        var n = 0
        while n < a.count, n < b.count, a[a.count - 1 - n] == b[b.count - 1 - n] { n += 1 }
        return n
    }

    private static func commonPrefix(_ a: String, _ b: String) -> Int {
        let a = Array(a.utf16), b = Array(b.utf16)
        var n = 0
        while n < a.count, n < b.count, a[n] == b[n] { n += 1 }
        return n
    }
}

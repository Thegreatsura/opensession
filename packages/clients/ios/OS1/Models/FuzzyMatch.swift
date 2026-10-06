import Foundation

/// Typo-tolerant matching for the small search surfaces: the composer's `@`
/// palette, the Mac command palette, and the sidebar filter.
///
/// A port of the server's `src/shared/fuzzy-match.ts`, rule for rule, so a
/// query ranks the same here as in the web client and in the rows the server
/// scores for the `@` palette. Change both or neither.
///
/// Scores are 0 (no match) to 100 (exact). Every whitespace-separated term
/// must land somewhere in the text: as a substring, as a word within a small
/// edit distance (an adjacent transposition counts as one edit), or as a
/// subsequence of one word. A term with punctuation inside ("pi-durable",
/// "audit/billing") is a phrase: its parts must appear as adjacent words,
/// joined by any separator or none. Accents and case are ignored.
///
/// A list scored on every keystroke should prepare its texts once with
/// `Text` and the query once with `Query`: the query remembers how each term
/// fares against each word it meets, so the typo and abbreviation checks run
/// once per distinct word rather than once per row.
enum FuzzyMatch {
    /// Score `text` against `query`. 0 means no match; higher is a better
    /// match. An empty query matches everything at 1.
    static func score(_ query: String, _ text: String) -> Int {
        Query(query).score(Text(text))
    }

    /// The best score across several fields of one item. 0 means no match.
    static func best(_ query: String, in values: [String?]) -> Int {
        Query(query).best(in: values.compactMap { $0 }.filter { !$0.isEmpty }.map(Text.init))
    }

    fileprivate typealias Scalars = [Unicode.Scalar]

    /// Text normalized and split once, so a list scored per keystroke pays
    /// for accent folding and word splitting when it changes, not per query.
    struct Text: Sendable, Equatable {
        fileprivate let text: Scalars
        /// Distinct words, in first-seen order.
        fileprivate let words: [Scalars]

        init(_ value: String) {
            text = FuzzyMatch.normalize(value)
            var seen = Set<Scalars>()
            words = FuzzyMatch.split(text).filter { seen.insert($0).inserted }
        }
    }

    /// One query term. With `parts`, it is a phrase of adjacent words.
    private struct Term {
        let text: Scalars
        let parts: [Scalars]?
    }

    /// A query normalized once, with a per-term cache of word fits. Not
    /// thread-safe: make one per search pass.
    final class Query {
        fileprivate let q: Scalars
        private let terms: [Term]
        private var fits: [[Scalars: Int]]

        init(_ query: String) {
            q = FuzzyMatch.trimmed(FuzzyMatch.normalize(query))
            terms = q.split(whereSeparator: { $0.properties.isWhitespace })
                .compactMap { raw -> Term? in
                    let raw = Array(raw)
                    let parts = FuzzyMatch.split(raw)
                    if parts.isEmpty { return nil }
                    // Edge punctuation, like a "#" or the hyphen just typed,
                    // is not a phrase.
                    if parts.count == 1 { return Term(text: parts[0], parts: nil) }
                    return Term(text: raw, parts: parts)
                }
            fits = Array(repeating: [:], count: terms.count)
        }

        var isEmpty: Bool { q.isEmpty }

        func score(_ text: Text) -> Int {
            if q.isEmpty { return 1 }
            let t = text.text
            if t.isEmpty { return 0 }
            if t == q { return 100 }
            if t.starts(with: q) { return 90 }
            if text.words.contains(where: { $0.starts(with: q) }) { return 80 }
            if FuzzyMatch.contains(t, q) { return 70 }
            if terms.isEmpty { return 0 }
            var total = 0
            for index in terms.indices {
                let score = termScore(index, text: t, words: text.words)
                if score == 0 { return 0 }
                total += score
            }
            return Int((Double(total) / Double(terms.count)).rounded(.toNearestOrAwayFromZero))
        }

        /// The best score across several prepared fields of one item.
        func best(in values: [Text]) -> Int {
            var best = 0
            for value in values {
                let score = score(value)
                if score > best { best = score }
                if best == 100 { break }
            }
            return best
        }

        private func termScore(_ index: Int, text: Scalars, words: [Scalars]) -> Int {
            let term = terms[index]
            if FuzzyMatch.contains(text, term.text) { return 60 }
            if let parts = term.parts {
                return FuzzyMatch.phraseMatches(parts, in: text) ? 60 : 0
            }
            let budget = FuzzyMatch.editBudget(term.text)
            var best = budget + 1
            var abbreviation = false
            for word in words {
                let fit = wordFit(index, term.text, word, budget: budget)
                let d = fit >> 1
                if d < best { best = d }
                if fit & 1 == 1 { abbreviation = true }
                if best == 0 { break }
            }
            if best <= budget { return 50 - best * 10 }
            // "wksp" for "workspace": abbreviations skip letters but keep
            // their order.
            return abbreviation ? 20 : 0
        }

        /// Edit distance (capped at budget + 1) times two, plus one when the
        /// term is an abbreviation of the word. Cached per distinct word.
        private func wordFit(_ index: Int, _ term: Scalars, _ word: Scalars, budget: Int) -> Int {
            if let fit = fits[index][word] { return fit }
            let d: Int
            if budget > 0, word.count >= term.count - budget {
                // Compare against the whole word and its prefix of the term's
                // length, so "wrokspace" and "relase" both land on their word.
                d = min(
                    FuzzyMatch.editDistance(term, word, max: budget),
                    FuzzyMatch.editDistance(term, Array(word.prefix(term.count)), max: budget)
                )
            } else {
                d = budget + 1
            }
            let abbreviation = term.count >= 3 && FuzzyMatch.isSubsequence(term, of: word)
            let fit = d * 2 + (abbreviation ? 1 : 0)
            fits[index][word] = fit
            return fit
        }
    }

    // MARK: - Rules

    /// Edits a term may absorb: none for short ones, so "cat" never finds
    /// "cut".
    private static func editBudget(_ term: Scalars) -> Int {
        if term.count < 4 { return 0 }
        if term.count < 8 { return 1 }
        return 2
    }

    /// The shared matcher's `(?:^|[^a-z0-9])p1[^a-z0-9]*p2…`: the parts as
    /// consecutive words starting at a word boundary, joined by any run of
    /// separators or by nothing. Every part starts with a word character, so
    /// skipping the whole separator run is the only way the next part can
    /// match and no backtracking is needed.
    private static func phraseMatches(_ parts: [Scalars], in text: Scalars) -> Bool {
        guard let first = parts.first?.first else { return false }
        for start in text.indices
        where text[start] == first && (start == 0 || !isWordScalar(text[start - 1])) {
            var position = start
            var matched = true
            for (index, part) in parts.enumerated() {
                if index > 0 {
                    while position < text.count, !isWordScalar(text[position]) { position += 1 }
                }
                guard position + part.count <= text.count,
                      text[position..<(position + part.count)].elementsEqual(part)
                else {
                    matched = false
                    break
                }
                position += part.count
            }
            if matched { return true }
        }
        return false
    }

    /// Optimal string alignment distance, capped at `max + 1`.
    private static func editDistance(_ a: Scalars, _ b: Scalars, max: Int) -> Int {
        if abs(a.count - b.count) > max { return max + 1 }
        var prev2: [Int] = []
        var prev = Array(0...b.count)
        for i in 1..<(a.count + 1) {
            var row = [i]
            row.reserveCapacity(b.count + 1)
            var rowMin = i
            for j in 1..<(b.count + 1) {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var d = Swift.min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1],
                   prev2[j - 2] + 1 < d {
                    d = prev2[j - 2] + 1
                }
                row.append(d)
                if d < rowMin { rowMin = d }
            }
            if rowMin > max { return max + 1 }
            prev2 = prev
            prev = row
        }
        return prev[b.count]
    }

    private static func isSubsequence(_ term: Scalars, of word: Scalars) -> Bool {
        var i = 0
        for ch in word {
            if i < term.count, ch == term[i] { i += 1 }
            if i == term.count { return true }
        }
        return i == term.count
    }

    // MARK: - Text

    /// Lowercased, compatibility-decomposed, with combining marks stripped:
    /// the same three steps as the shared TypeScript.
    private static func normalize(_ value: String) -> Scalars {
        value.lowercased()
            .decomposedStringWithCompatibilityMapping
            .unicodeScalars
            .filter { !(0x300...0x36F).contains($0.value) }
    }

    private static func trimmed(_ value: Scalars) -> Scalars {
        Array(
            value
                .drop(while: { $0.properties.isWhitespace })
                .reversed()
                .drop(while: { $0.properties.isWhitespace })
                .reversed()
        )
    }

    /// Words are runs of ASCII letters and digits, as in the shared matcher.
    private static func split(_ value: Scalars) -> [Scalars] {
        value.split(whereSeparator: { !isWordScalar($0) }).map(Array.init)
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x61...0x7A, 0x30...0x39: true
        default: false
        }
    }

    private static func contains(_ text: Scalars, _ needle: Scalars) -> Bool {
        if needle.isEmpty { return true }
        guard text.count >= needle.count else { return false }
        for start in 0...(text.count - needle.count)
        where text[start] == needle[0] && text[start..<(start + needle.count)].elementsEqual(needle) {
            return true
        }
        return false
    }
}

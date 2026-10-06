import Foundation

/// Second chance for an ER diagram mermaid refuses, ported from the web's
/// `src/frontend/lib/mermaid-repair.ts` (`quoteErAttributes`).
///
/// An attribute named `pk`, `fk` or `uk` (any case) lexes as a key marker, and
/// a type like `Vec<Track>` is not an attribute word. Backticks make either one
/// a plain word, and change nothing about what renders. The host page parses
/// the source as written first and only tries this when that fails, so a
/// diagram that already parses is never touched.
///
/// Pure text, matching the web's regexes code unit for code unit (its patterns
/// are non-unicode JavaScript regexes, so they see UTF-16). Other diagram types
/// use braces and brackets for their own grammar and are left alone.
enum MermaidRepair {
    /// The repaired source for any diagram type this knows, or nil when there
    /// is nothing to retry.
    static func repairedSource(_ source: String) -> String? {
        quoteErAttributes(source)
    }

    /// The ER diagram with every attribute type and name mermaid would read as
    /// syntax wrapped in backticks, or nil when the source is not an ER diagram
    /// or nothing needed quoting. Only the leading `type name` pair of a line
    /// inside an entity's `{ ... }` block is touched: key markers and the
    /// quoted comment after them already parse.
    static func quoteErAttributes(_ source: String) -> String? {
        let lines = source.utf16.split(separator: newline, omittingEmptySubsequences: false)
            .map { Array($0) }
        guard isERHeader(header(lines)) else { return nil }
        var inBlock = false
        var changed = false
        let repaired = lines.map { line -> [UInt16] in
            let trimmed = trim(line)
            if !inBlock {
                if trimmed.last == brace(open: true), !trimmed.starts(with: comment) {
                    inBlock = true
                }
                return line
            }
            if trimmed.first == brace(open: false) {
                inBlock = false
                return line
            }
            guard !trimmed.starts(with: comment),
                  let attribute = splitAttribute(line),
                  attribute.type.first != quote
            else { return line }
            let type = quoteWord(attribute.type)
            let name = quoteWord(attribute.name)
            if type == attribute.type, name == attribute.name { return line }
            changed = true
            return attribute.indent + type + attribute.gap + name + attribute.rest
        }
        guard changed else { return nil }
        let joined = Array(repaired.joined(separator: [newline]))
        return String(decoding: joined, as: UTF16.self)
    }

    // MARK: - Lexing, in JavaScript's terms

    private static let newline: UInt16 = 0x0A
    private static let quote: UInt16 = 0x22
    private static let backtick: UInt16 = 0x60
    private static let comment: [UInt16] = [0x25, 0x25] // %%

    private static func brace(open: Bool) -> UInt16 { open ? 0x7B : 0x7D }

    /// JavaScript's `\s` (and what `trim()` strips).
    private static func isSpace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// What JavaScript's `.` refuses to match.
    private static func isLineTerminator(_ unit: UInt16) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }

    private static func trim(_ line: [UInt16]) -> ArraySlice<UInt16> {
        guard let start = line.firstIndex(where: { !isSpace($0) }),
              let end = line.lastIndex(where: { !isSpace($0) })
        else { return [] }
        return line[start...end]
    }

    /// The first line that is not blank or a `%%` directive.
    private static func header(_ lines: [[UInt16]]) -> ArraySlice<UInt16> {
        for line in lines {
            let trimmed = trim(line)
            if !trimmed.isEmpty, !trimmed.starts(with: comment) { return trimmed }
        }
        return []
    }

    /// `/^erDiagram\b/`.
    private static func isERHeader(_ header: ArraySlice<UInt16>) -> Bool {
        let keyword = Array("erDiagram".utf16)
        guard header.starts(with: keyword) else { return false }
        let next = header.dropFirst(keyword.count).first
        return next.map { !isWordUnit($0) } ?? true
    }

    private static func isWordUnit(_ unit: UInt16) -> Bool {
        isLetter(unit) || isDigit(unit) || unit == 0x5F
    }

    private static func isLetter(_ unit: UInt16) -> Bool {
        (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }

    private static func isDigit(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit)
    }

    private struct Attribute {
        let indent: [UInt16]
        let type: [UInt16]
        let gap: [UInt16]
        let name: [UInt16]
        let rest: [UInt16]
    }

    /// `/^(\s*)(\S+)(\s+)(\S+)(.*)$/`. Every boundary is forced, so a single
    /// greedy pass finds the only match there is.
    private static func splitAttribute(_ line: [UInt16]) -> Attribute? {
        var index = 0
        func run(_ keep: (UInt16) -> Bool) -> [UInt16] {
            let start = index
            while index < line.count, keep(line[index]) { index += 1 }
            return Array(line[start..<index])
        }
        let indent = run(isSpace)
        let type = run { !isSpace($0) }
        let gap = run(isSpace)
        let name = run { !isSpace($0) }
        let rest = Array(line[index...])
        guard !type.isEmpty, !gap.isEmpty, !name.isEmpty,
              !rest.contains(where: isLineTerminator)
        else { return nil }
        return Attribute(indent: indent, type: type, gap: gap, name: name, rest: rest)
    }

    /// `/^(pk|fk|uk)$/i`.
    private static func isKeyMarker(_ word: [UInt16]) -> Bool {
        guard word.count == 2 else { return false }
        let lower = word.map { isLetter($0) ? $0 | 0x20 : $0 }
        return lower[1] == 0x6B && [0x70, 0x66, 0x75].contains(lower[0]) // pk fk uk
    }

    /// What mermaid's ER lexer accepts as a bare attribute type or name:
    /// `/^[*A-Za-z_À-￿][A-Za-z0-9\-_[\]().,À-￿*]*$/`.
    private static func isAttributeWord(_ word: [UInt16]) -> Bool {
        guard let first = word.first,
              first == 0x2A || isLetter(first) || first == 0x5F || first >= 0xC0
        else { return false }
        let punctuation: Set<UInt16> = Set("-_[]().,*".utf16)
        return word.dropFirst().allSatisfy {
            isLetter($0) || isDigit($0) || punctuation.contains($0) || $0 >= 0xC0
        }
    }

    /// Backtick-quote a type or name the ER lexer would not read as a word.
    private static func quoteWord(_ word: [UInt16]) -> [UInt16] {
        if word.contains(backtick) { return word }
        return isKeyMarker(word) || !isAttributeWord(word)
            ? [backtick] + word + [backtick]
            : word
    }
}

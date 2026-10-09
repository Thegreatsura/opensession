import Foundation

/// Splits a Markdown file into sections at its h1 to h3 headings, so the
/// document view can open a larger gap above a heading than between
/// paragraphs. The renderer spaces every block the same, and a page with no
/// extra air above its headings reads as one long chat message.
///
/// Headings inside fenced code are text, not structure, and never split.
enum MarkdownDocumentSections {
    struct Section: Equatable {
        /// The section's Markdown, starting at its heading.
        let text: String
        /// The level of the heading that opens it; nil for the lead before
        /// the first heading.
        let level: Int?
        /// True when the section is only its heading, as when an h2 sits
        /// directly on an h3.
        let headingOnly: Bool
    }

    static func split(_ text: String) -> [Section] {
        var sections: [Section] = []
        var lines: [Substring] = []
        var level: Int?
        var fence: (marker: Character, length: Int)?

        func flush() {
            let body = lines.joined(separator: "\n")
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let content = lines.dropFirst(level == nil ? 0 : 1)
                let headingOnly = level != nil && content.allSatisfy {
                    $0.trimmingCharacters(in: .whitespaces).isEmpty
                }
                sections.append(Section(text: body, level: level, headingOnly: headingOnly))
            }
            lines = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let open = fence {
                if let run = fenceRun(line), run.marker == open.marker, run.length >= open.length,
                   run.rest.trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                }
            } else if let run = fenceRun(line) {
                fence = (run.marker, run.length)
            } else if let heading = headingLevel(line) {
                flush()
                level = heading
            }
            lines.append(line)
        }
        flush()
        return sections
    }

    /// The gap above a section, in points. The first section sits flush; a
    /// heading straight under another stays close to it.
    static func gap(before section: Section, after previous: Section?) -> CGFloat {
        guard let previous else { return 0 }
        if previous.headingOnly { return 4 }
        switch section.level {
        case 1, 2: return 24
        case 3: return 12
        default: return 0
        }
    }

    /// An ATX heading of level 1 to 3: up to three spaces of indent, the
    /// hashes, then a space or the end of the line.
    static func headingLevel(_ line: Substring) -> Int? {
        let trimmed = line.drop { $0 == " " }
        guard line.count - trimmed.count <= 3 else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...3).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return hashes
    }

    private static func fenceRun(_ line: Substring) -> (marker: Character, length: Int, rest: Substring)? {
        let trimmed = line.drop { $0 == " " }
        guard line.count - trimmed.count <= 3, let marker = trimmed.first,
              marker == "`" || marker == "~" else { return nil }
        let length = trimmed.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        return (marker, length, trimmed.dropFirst(length))
    }
}

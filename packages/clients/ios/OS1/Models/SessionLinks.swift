import Foundation

extension Notification.Name {
    /// Open a session from a surface outside the sessions list (Settings);
    /// the object is the session id. The list closes the settings sheet on
    /// iPhone and selects the session in the main window on Mac.
    static let os1OpenSessionLink = Notification.Name("os1.openSessionLink")
}

/// Session ids inside agent output, turned into links you can follow.
///
/// An orchestrator says "delegated to `os-019f…`" constantly, and on the web
/// that renders as the worker's own title and navigates in-app. Natively it was
/// dead text — forty characters of noise you could not act on. The transcript's
/// markdown is rewritten just before rendering so those ids become ordinary
/// markdown links on a private scheme, which the transcript intercepts through
/// `openURL` (SwiftStreamingMarkdown routes taps through that environment
/// value) and turns into a push.
///
/// The rewrite is deliberately conservative: fenced and indented code stays
/// untouched, and an id already inside a URL is left alone so link targets
/// can't be corrupted.
@MainActor
enum SessionLinks {
    /// Private scheme, so a link can never escape to a browser by accident.
    static let scheme = "os1session"

    /// id → title, refreshed from the polled sessions list. A title is only
    /// ever a nicety: an id we've never seen still links, labelled by its
    /// shortened id.
    private static var titles: [String: String] = [:]

    static func register(titles next: [String: String]) {
        guard next != titles else { return }
        titles = next
        // A transcript already on screen was drawn against the old table —
        // most importantly against an EMPTY one, on a cold deep link.
        TranscriptLinks.shared.invalidate()
    }

    static func title(for id: String) -> String? { titles[id] }

    /// The link that opens a session in this app, for code that has an id
    /// rather than a chip — the sessions list resolves it the same way it
    /// resolves a tapped transcript chip.
    static func url(for id: String) -> URL? {
        URL(string: "\(scheme):\(id)")
    }

    /// Ask the sessions list to open `id`. Settings is a sheet on iPhone and
    /// its own window on Mac, so neither can push onto the list's stack.
    static func requestOpen(_ id: String) {
        NotificationCenter.default.post(name: .os1OpenSessionLink, object: id)
    }

    /// The session id a transcript link points at, or nil for a normal URL.
    static func sessionId(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        // os1session:os-… — the id lands in `path` or `host` depending on
        // how the URL was spelled, so accept either.
        let candidate = url.host ?? url.path
        let id = candidate.hasPrefix("/") ? String(candidate.dropFirst()) : candidate
        return id.hasPrefix("os-") || id.hasPrefix("bks-") ? id : nil
    }

    /// Every minted id is `<prefix>-<uuidv7>`. Only the pre-rename `bks-`
    /// prefix also covers hand-made slug ids (`bks-ghpr-5099-review`), so it
    /// alone keeps the looser shape — `os-` is short enough that a loose form
    /// would turn an ordinary codespan like `os-release` into a session link.
    /// The web draws the line in the same place (`SESSION_ID_EXACT` in
    /// src/frontend/lib/markdown.ts), because an id has to mean the same thing
    /// in both clients.
    private static let uuidV7 =
        "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"

    // A codespan'd id (`os-…`), which is how agents usually write one, or a
    // bare uuidv7-shaped one in prose. The bare form is strict on purpose so
    // it can't misfire on ordinary words.
    private static let pattern = try! NSRegularExpression(
        pattern:
            "`((?:os-\(uuidV7)|bks-[a-z0-9][a-z0-9-]{5,}))`"
            + "|(?<![\\w/-])((?:os|bks)-\(uuidV7))",
        options: [.caseInsensitive]
    )

    private static let shortIdLength = 12
    private static let titleMaxLength = 38

    /// Markdown with every session id rewritten as a link. Returns the input
    /// unchanged when there is nothing to do, which is the common case.
    static func linkify(_ markdown: String) -> String {
        guard mayContainId(markdown) else { return markdown }
        return MarkdownProse.rewrite(markdown) { line in
            // A line with no id is most lines.
            mayContainId(line) ? linkifyLine(line) : line
        }
    }

    private static func mayContainId(_ text: String) -> Bool {
        text.contains("os-") || text.contains("bks-")
    }

    private static func linkifyLine(_ line: String) -> String {
        let ns = line as NSString
        var result = ""
        var cursor = 0
        for match in pattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let idRange = match.range(at: 1).location != NSNotFound
                ? match.range(at: 1)
                : match.range(at: 2)
            guard idRange.location != NSNotFound else { continue }
            let id = ns.substring(with: idRange)
            result += ns.substring(with: NSRange(
                location: cursor,
                length: match.range.location - cursor
            ))
            result += chip(for: id).markdown
            cursor = match.range.location + match.range.length
        }
        guard cursor > 0 else { return line }
        result += ns.substring(from: cursor)
        return result
    }

    /// What a reference to another session draws as: a conversation glyph and
    /// the name of the work it points at. The full id stays in the accessibility label,
    /// because the label above is lossy either way.
    static func chip(for id: String) -> TranscriptChip {
        let label = label(for: id)
        return TranscriptChip(
            kind: .session,
            tone: .neutral,
            title: label,
            accessibilityLabel: label == id ? "Open session \(id)" : "Open \(label) (\(id))",
            destination: "\(scheme):\(id)"
        )
    }

    /// The chip's text: the name registered for that session when we have one
    /// (its workspace's, see SessionsListViewModel), otherwise a shortened id.
    /// Both are lossy, which is fine: the link itself carries the full id.
    static func label(for id: String) -> String {
        if let title = titles[id], !title.isEmpty {
            let title = cleanTitle(title)
            return title.count > titleMaxLength
                ? String(title.prefix(titleMaxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
                : title
        }
        // Legacy `bks-<slug>` ids are already short, and cutting one mid-word
        // reads worse than showing all of it.
        guard id.count > 20 else { return id }
        // Where the cut lands depends on the prefix: `bks-` spends four
        // characters, `os-` three, so the same twelve reach one character
        // further into the uuid and can end on its first hyphen. A label
        // ending in a dangling separator reads as a truncation bug rather
        // than a shortened id.
        let short = String(id.prefix(shortIdLength))
        return short.replacingOccurrences(
            of: "-+$",
            with: "",
            options: .regularExpression
        ) + "…"
    }

    /// A session an automation opened names itself after the job that opened
    /// it: "Simplify · PR #5517 Give floating surfaces a rounder corner". That
    /// prefix is bookkeeping rather than subject, and on a chip clipped at 38
    /// characters it eats the readable half. The web strips it wherever a
    /// title is shown at a width that has to choose (`cleanSessionTitle` in
    /// src/frontend/lib/session-title.ts); this is the same rule, so the same
    /// session reads the same way in both clients. Stripping everything is no
    /// improvement on the boilerplate, so a title that is only a prefix keeps it.
    private static let automationPrefix = try! NSRegularExpression(
        pattern: "^(Review|Auto-fix|Mention|Simplify|Fix)\\s*·\\s*PR\\s*#\\d+\\s*",
        options: [.caseInsensitive]
    )

    static func cleanTitle(_ title: String) -> String {
        let ns = title as NSString
        let stripped = automationPrefix.stringByReplacingMatches(
            in: title,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        ).trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? title : stripped
    }

}

import Foundation

/// A workspace person the Slack composer can mention, as `GET /api/slack/users`
/// sends them.
struct SlackMentionUser: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    /// What Slack shows after the "@": the display name, else the real name.
    let name: String
    let realName: String?
    let image: String?

    init(id: String, name: String, realName: String? = nil, image: String? = nil) {
        self.id = id
        self.name = name
        self.realName = realName
        self.image = image
    }
}

/// The Slack composer's text with its people mentions.
///
/// Slack only notifies someone for a `<@U123>` token; a typed "@Name" is plain
/// text. The field shows readable "@Name" while this keeps, for every person
/// picked or decoded, where their name sits in the shown text. Edits move
/// those ranges, so two people who share a name keep their own ids, and an
/// edit inside a name turns it back into plain text. `encoded` is what saves
/// and sends carry, so a reopened draft decodes back to names.
///
/// Offsets are UTF-16, the space SwiftUI's selection, Foundation and the
/// server's JavaScript length all share.
struct SlackMentionDraft: Equatable {
    struct Mention: Equatable {
        var range: NSRange
        let id: String
        /// The "@Name" shown for it, so a diff that lands ambiguously can
        /// never keep a range over different text.
        let label: String
    }

    /// One in-place rewrite, so a caret after it can be moved along.
    struct Rewrite: Equatable {
        let location: Int
        let removed: Int
        let inserted: Int
    }

    static let limit = 500

    private(set) var text: String
    private(set) var mentions: [Mention] = []

    // The server's token shape (`src/shared/slack-mentions.ts`), label optional.
    private static let token = try! NSRegularExpression(
        pattern: #"<@([UW][A-Z0-9]{2,})(?:\|[^>]*)?>"#
    )

    /// Decode saved or suggested text. Tokens for people outside `users` stay
    /// exactly as they are, for `resolve` to read once the roster arrives.
    init(encoded: String, users: [SlackMentionUser] = []) {
        text = encoded
        resolve(users: users)
    }

    /// Shown length, which the 500-character limit counts.
    var length: Int { text.utf16.count }

    /// The text saves and sends carry: each tracked name as Slack's token.
    var encoded: String {
        let result = NSMutableString(string: text)
        for mention in mentions.reversed() {
            result.replaceCharacters(in: mention.range, with: "<@\(mention.id)>")
        }
        return result as String
    }

    /// Read tokens still raw in the shown text as names, in place, so edits
    /// made before the roster arrived stay. Returns the rewrites in text
    /// order; `adjust` moves a caret across them.
    @discardableResult
    mutating func resolve(users: [SlackMentionUser]) -> [Rewrite] {
        guard !users.isEmpty else { return [] }
        let byId = Dictionary(users.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let source = text as NSString
        let matches = Self.token.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        )
        var rewrites: [Rewrite] = []
        // Back to front, so earlier ranges stay valid while rewriting.
        for match in matches.reversed() {
            let id = source.substring(with: match.range(at: 1))
            guard let user = byId[id],
                  !mentions.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 })
            else { continue }
            let label = "@\(user.name)"
            replace(match.range, with: label, id: id)
            rewrites.append(Rewrite(
                location: match.range.location,
                removed: match.range.length,
                inserted: (label as NSString).length
            ))
        }
        return rewrites.reversed()
    }

    /// Where a caret sits after `rewrites`. A caret inside a rewritten token
    /// moves to the end of its name.
    static func adjust(_ offset: Int, by rewrites: [Rewrite]) -> Int {
        var result = offset
        for rewrite in rewrites.reversed() {
            if offset >= rewrite.location + rewrite.removed {
                result += rewrite.inserted - rewrite.removed
            } else if offset > rewrite.location {
                result = rewrite.location + rewrite.inserted + (result - offset)
            }
        }
        return result
    }

    /// Take the field's new text. Mentions before and after the edit move
    /// with it; one the edit touches, or that no longer stands as its own
    /// word, is plain text again. Growth past the limit is trimmed from the
    /// inserted text, never from what was already there. Returns where the
    /// inserted text ends, for the caret.
    @discardableResult
    mutating func edit(to newText: String) -> Int {
        let old = Array(text.utf16)
        var new = Array(newText.utf16)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        var insertedEnd = new.count - suffix
        let allowed = max(Self.limit, old.count)
        if new.count > allowed {
            var keep = insertedEnd - prefix - (new.count - allowed)
            // Never split a surrogate pair.
            if keep > 0, UTF16.isLeadSurrogate(new[prefix + keep - 1]) { keep -= 1 }
            new.removeSubrange((prefix + max(0, keep))..<insertedEnd)
            insertedEnd = prefix + max(0, keep)
        }
        let removedEnd = old.count - suffix
        let delta = insertedEnd - removedEnd
        text = String(decoding: new, as: UTF16.self)
        mentions = mentions.compactMap { mention in
            // Wholly before the edit (typing right after a name included;
            // `standsAlone` drops it if that ran a word on).
            if NSMaxRange(mention.range) <= prefix { return mention }
            // Wholly after it (typing right before the "@" included).
            if mention.range.location >= removedEnd {
                var moved = mention
                moved.range.location += delta
                return moved
            }
            return nil
        }
        .filter(standsAlone)
        return insertedEnd
    }

    /// Write "@Name " over `range` (the "@" and the query typed after it) and
    /// track it as `user`. Returns the caret after the trailing space, or nil
    /// when the name would not fit in the limit.
    mutating func pick(_ user: SlackMentionUser, replacing range: NSRange) -> Int? {
        let label = "@\(user.name)"
        let labelLength = (label as NSString).length
        let next = length - range.length + labelLength + 1
        guard next <= max(Self.limit, length) else { return nil }
        replace(range, with: label + " ", id: nil)
        mentions.append(Mention(
            range: NSRange(location: range.location, length: labelLength),
            id: user.id,
            label: label
        ))
        mentions.sort { $0.range.location < $1.range.location }
        return range.location + labelLength + 1
    }

    /// The unfinished "@query" before the caret: the "@" starts the text or
    /// follows whitespace, is the nearest on the caret's line, and is not a
    /// name already picked. Like the web, the query may hold spaces; the
    /// picker ends it when nothing matches.
    func trigger(caret: Int) -> ComposerMentionContext? {
        let source = text as NSString
        guard caret >= 0, caret <= source.length else { return nil }
        var index = caret - 1
        while index >= 0 {
            let unit = source.character(at: index)
            if unit == 0x0A || unit == 0x0D { return nil }
            if unit == 0x40 {
                if index > 0,
                   let previous = UnicodeScalar(source.character(at: index - 1)),
                   !CharacterSet.whitespacesAndNewlines.contains(previous) {
                    return nil
                }
                if mentions.contains(where: { $0.range.location == index }) { return nil }
                let range = NSRange(location: index, length: caret - index)
                return ComposerMentionContext(
                    range: range,
                    query: source.substring(with: NSRange(location: index + 1, length: caret - index - 1))
                )
            }
            index -= 1
        }
        return nil
    }

    /// Workspace people matching what follows the "@", best first.
    static func matches(
        _ query: String,
        in users: [SlackMentionUser],
        limit: Int = 8
    ) -> [SlackMentionUser] {
        guard !query.isEmpty else { return Array(users.prefix(limit)) }
        let prepared = FuzzyMatch.Query(query)
        return users
            .map { user in
                (user, prepared.best(in: [user.name, user.realName]
                    .compactMap { $0 }.filter { !$0.isEmpty }.map(FuzzyMatch.Text.init)))
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    private mutating func replace(_ range: NSRange, with replacement: String, id: String?) {
        let delta = (replacement as NSString).length - range.length
        text = (text as NSString).replacingCharacters(in: range, with: replacement)
        mentions = mentions.compactMap { mention in
            if NSMaxRange(mention.range) <= range.location { return mention }
            if mention.range.location >= NSMaxRange(range) {
                var moved = mention
                moved.range.location += delta
                return moved
            }
            return nil
        }
        if let id {
            mentions.append(Mention(
                range: NSRange(location: range.location, length: (replacement as NSString).length),
                id: id,
                label: replacement
            ))
            mentions.sort { $0.range.location < $1.range.location }
        }
    }

    /// A name counts only as its own word, as Slack and the web read it:
    /// the "@" starts the text or follows a non-word character, and no word
    /// character runs on after the name.
    private func standsAlone(_ mention: Mention) -> Bool {
        let source = text as NSString
        guard NSMaxRange(mention.range) <= source.length,
              source.substring(with: mention.range) == mention.label
        else { return false }
        if mention.range.location > 0,
           Self.isWordUnit(source.character(at: mention.range.location - 1)) {
            return false
        }
        let end = NSMaxRange(mention.range)
        if end < source.length, Self.isWordUnit(source.character(at: end)) { return false }
        return true
    }

    private static func isWordUnit(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return true }
        return scalar == "_" || scalar == "@" || CharacterSet.alphanumerics.contains(scalar)
    }
}

import Foundation

#if os(macOS)

/// One row the Mac command palette can show: a command it runs, or a session
/// it switches to.
///
/// Data only, no closure, so ranking is a pure function over values and can be
/// tested without a view — `CommandPaletteItem` is what pairs an entry with
/// what selecting it does.
struct CommandPaletteEntry: Identifiable, Equatable, Sendable {
    enum Kind: Int, Sendable {
        /// Something the app does. Listed above sessions, in declared order.
        case command
        /// Somewhere the app goes. Ranked by how well it matched, then by how
        /// recently it was active.
        case session
        /// An archived workspace or session. Only offered for a query, and
        /// always below live work whatever it scores: live work is what the
        /// palette is for, and the archive is where a forgotten name turns up.
        case archived
    }

    let id: String
    let title: String
    /// The line under the title: what a command does, or where a session lives.
    var subtitle: String?
    /// Words that should find the row without being written on it — a
    /// session's repo, branch and workspace, a command's synonyms.
    var keywords: [String] = []
    /// The keys that run the same thing without opening the palette, one cap
    /// each. Empty when there is no shortcut, rather than a fake one.
    var shortcut: [String] = []
    var symbol: String = "circle"
    var kind: Kind = .command
    /// Breaks ties between sessions. Nil on commands, which keep the order
    /// they were declared in.
    var recency: Date?
}

/// Which rows a query keeps, and in what order.
///
/// Matching is the shared `FuzzyMatch`, the same rules as the web palette:
/// every whitespace-separated term has to land somewhere in the row, exactly,
/// within a small edit distance, or as an abbreviation of one word, so
/// "relase" still finds Release. Where it lands is the rank: a match in the
/// title beats one that needed the subtitle or a keyword, and within each the
/// scorer's own order holds (the title's start over a word inside it, over a
/// typo).
enum CommandPaletteRanking {
    private struct Candidate {
        let entry: CommandPaletteEntry
        let order: Int
        let score: Int
    }

    static func results(
        _ entries: [CommandPaletteEntry],
        query: String,
        sessionLimit: Int = 40,
        archivedLimit: Int = 20,
        contentMatches: Set<String> = []
    ) -> [CommandPaletteEntry] {
        let hasQuery = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var matched: [Candidate] = []
        for (order, entry) in entries.enumerated() {
            if entry.kind == .archived, !hasQuery { continue }
            let score = score(entry, query: query)
            if score > 0 {
                matched.append(Candidate(entry: entry, order: order, score: score))
            } else if entry.kind == .session, contentMatches.contains(entry.id) {
                // A backend transcript hit ranks after every metadata match,
                // whose weakest score is still at least one.
                matched.append(Candidate(entry: entry, order: order, score: 0))
            }
        }

        matched.sort { left, right in
            if left.entry.kind != right.entry.kind {
                return left.entry.kind.rawValue < right.entry.kind.rawValue
            }
            if left.score != right.score { return left.score > right.score }
            if left.entry.kind != .command {
                let leftDate = left.entry.recency ?? .distantPast
                let rightDate = right.entry.recency ?? .distantPast
                if leftDate != rightDate { return leftDate > rightDate }
            }
            return left.order < right.order
        }

        var sessions = 0
        var archived = 0
        return matched.compactMap { candidate in
            switch candidate.entry.kind {
            case .command:
                return candidate.entry
            case .session:
                sessions += 1
                return sessions <= sessionLimit ? candidate.entry : nil
            case .archived:
                archived += 1
                return archived <= archivedLimit ? candidate.entry : nil
            }
        }
    }

    /// 0 when the row does not match. A title match sits a full band above a
    /// match that needed the subtitle or keywords, and a query whose terms are
    /// spread across both still counts, since the row as a whole is searched.
    private static func score(_ entry: CommandPaletteEntry, query: String) -> Int {
        let title = FuzzyMatch.score(query, entry.title)
        if title > 0 { return 100 + title }
        let rest = ([entry.title, entry.subtitle].compactMap { $0 } + entry.keywords)
            .joined(separator: " ")
        return FuzzyMatch.score(query, rest)
    }
}

/// The palette's Archived rows, as values: archived workspaces whose sessions
/// are all closed, then the archived sessions such a row does not already
/// stand for (`archivedResults` in the web's SessionSearch.tsx). A workspace
/// that still has a live session is reached through that session instead.
enum CommandPaletteArchive {
    static let workspacePrefix = "archived-workspace:"
    static let sessionPrefix = "archived:"

    /// What selecting an archived row opens.
    enum Target: Equatable {
        /// The workspace's most recently active archived session.
        case session(String)
    }

    static func entries(
        archived: [Session],
        liveWorkspaceIds: Set<String>,
        workspaceNames: [String: String]
    ) -> [CommandPaletteEntry] {
        let newestFirst = archived.sorted {
            ($0.lastActivityDate ?? .distantPast) > ($1.lastActivityDate ?? .distantPast)
        }
        var workspaceOrder: [String] = []
        var byWorkspace: [String: [Session]] = [:]
        for session in newestFirst {
            guard let workspaceId = session.workspaceId, !workspaceId.isEmpty,
                  !liveWorkspaceIds.contains(workspaceId) else { continue }
            if byWorkspace[workspaceId] == nil { workspaceOrder.append(workspaceId) }
            byWorkspace[workspaceId, default: []].append(session)
        }
        var shownNames: [String: String] = [:]
        var entries: [CommandPaletteEntry] = []
        for workspaceId in workspaceOrder {
            guard let sessions = byWorkspace[workspaceId], let newest = sessions.first else {
                continue
            }
            let name = [workspaceNames[workspaceId], newest.workspaceName]
                .compactMap { $0 }
                .first { !$0.isEmpty }
            guard let name else { continue }
            shownNames[workspaceId] = name
            let count = sessions.count
            entries.append(CommandPaletteEntry(
                id: workspacePrefix + workspaceId,
                title: name,
                subtitle: [
                    RepoTile.label(for: newest.effectiveRepo),
                    "Archived workspace",
                    count == 1 ? "1 session" : "\(count) sessions",
                ].joined(separator: " · "),
                keywords: keywords(sessions),
                symbol: "archivebox",
                kind: .archived,
                recency: newest.lastActivityDate
            ))
        }
        for session in newestFirst {
            // A session alone under a workspace row of the same name is the
            // same result twice.
            if let workspaceId = session.workspaceId,
               let shown = shownNames[workspaceId],
               shown.caseInsensitiveCompare(session.displayTitle) == .orderedSame {
                continue
            }
            entries.append(CommandPaletteEntry(
                id: sessionPrefix + session.id,
                title: session.displayTitle,
                subtitle: [RepoTile.label(for: session.effectiveRepo), "Archived"]
                    .joined(separator: " · "),
                keywords: keywords([session]) + [session.workspaceName ?? ""]
                    .filter { !$0.isEmpty },
                symbol: "archivebox",
                kind: .archived,
                recency: session.lastActivityDate
            ))
        }
        return entries
    }

    /// The session an archived row opens, from the archived list it was built
    /// from. Nil for an id this list no longer holds.
    static func target(for id: String, in archived: [Session]) -> Target? {
        if id.hasPrefix(sessionPrefix) {
            let sessionId = String(id.dropFirst(sessionPrefix.count))
            return archived.contains { $0.id == sessionId } ? .session(sessionId) : nil
        }
        guard id.hasPrefix(workspacePrefix) else { return nil }
        let workspaceId = String(id.dropFirst(workspacePrefix.count))
        return archived
            .filter { $0.workspaceId == workspaceId }
            .max { ($0.lastActivityDate ?? .distantPast) < ($1.lastActivityDate ?? .distantPast) }
            .map { .session($0.id) }
    }

    private static func keywords(_ sessions: [Session]) -> [String] {
        var seen = Set<String>()
        return sessions.flatMap { session in
            [session.effectiveRepo, session.branch ?? "", session.startedBy ?? "", "archived"]
        }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

#endif

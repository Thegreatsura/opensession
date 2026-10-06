import Foundation

// Review progress for a diff: which files a reviewer has read, which changed
// after they read them, how the files group, and what bulk actions flip.
// Plain Foundation with no networking, so every rule here is unit-tested.
// Mirrors the web's lib/review-groups.ts, lib/pr-review-guide.ts and
// hooks/useLocalReviewedFiles.ts.

/// One group of files: a review guide section, or a file-type bucket while
/// the guide is unavailable.
struct PrReviewGroup: Equatable, Sendable, Identifiable {
    let title: String
    let explanation: String?
    let files: [String]

    var id: String { title }

    init(title: String, explanation: String? = nil, files: [String]) {
        self.title = title
        self.explanation = explanation
        self.files = files
    }
}

/// A group restricted to the files on screen, with its review progress.
struct PrReviewGroupProgress: Equatable, Sendable, Identifiable {
    let title: String
    let explanation: String?
    let files: [String]
    let reviewed: Int
    let changed: Int

    var id: String { title }
    var isDone: Bool { !files.isEmpty && reviewed == files.count }
}

/// The three whole-review actions. Each becomes at most two batch requests.
enum PrReviewBulkAction: String, CaseIterable, Identifiable, Sendable {
    case mark, reset, invert

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mark: "Mark all as reviewed"
        case .reset: "Reset review state"
        case .invert: "Invert review state"
        }
    }

    var symbol: String {
        switch self {
        case .mark: "checkmark.circle"
        case .reset: "arrow.uturn.backward.circle"
        case .invert: "arrow.left.arrow.right.circle"
        }
    }
}

/// What a reviewer's state for one file is.
enum PrFileReviewState: Equatable, Sendable {
    case unreviewed, reviewed
    /// Reviewed, then changed by later commits or edits.
    case changed

    static func of(
        _ path: String,
        reviewed: Set<String>,
        changed: Set<String>
    ) -> PrFileReviewState {
        if reviewed.contains(path) { return .reviewed }
        if changed.contains(path) { return .changed }
        return .unreviewed
    }
}

enum PrReviewGroups {
    static let leftoverTitle = "Everything else"
    static let staleLeftoverTitle = "New since the guide"

    // MARK: Type groups

    private struct Rule {
        let title: String
        let pattern: NSRegularExpression
    }

    private static func rule(_ title: String, _ pattern: String, ignoreCase: Bool = false) -> Rule {
        Rule(
            title: title,
            // The patterns are literals tested below; a typo is a test failure.
            pattern: try! NSRegularExpression(
                pattern: pattern,
                options: ignoreCase ? [.caseInsensitive] : []
            )
        )
    }

    /// The web's file-role rules, in the same precedence.
    private static let rules: [Rule] = [
        rule("Generated", #"(^|/)(dist|build|generated|__generated__|__snapshots__|vendor)/|\.(snap|min\.js|min\.css|map|pb\.go)$|(_pb2\.py|\.generated\.\w+)$"#),
        rule("Dependencies", #"(^|/)(package\.json|bun\.lockb?|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Cargo\.(toml|lock)|Gemfile(\.lock)?|go\.(mod|sum)|requirements[^/]*\.txt|poetry\.lock|uv\.lock|pyproject\.toml|composer\.(json|lock)|Podfile(\.lock)?|Package\.(swift|resolved)|flake\.lock)$"#),
        rule("Tests", #"(^|/)(tests?|__tests__|spec|e2e|fixtures?)/|[._-](test|spec)\.\w+$|_test\.(go|py)$|(^|/)test_[^/]+\.py$"#),
        rule("Docs", #"\.(md|mdx|rst|adoc|txt)$|(^|/)(docs?|documentation)/|(^|/)(LICENSE|CHANGELOG|README)[^/]*$"#, ignoreCase: true),
        rule("Config", #"(^|/)\.[^/]+$|(^|/)\.(github|circleci|vscode|husky)/|\.(ya?ml|toml|ini|cfg|conf|env(\.\w+)?)$|(^|/)(Dockerfile|Makefile|Procfile)[^/]*$|(^|/)[^/]*\.config\.\w+$|(^|/)tsconfig[^/]*\.json$"#),
    ]

    private static let ruleOrder = ["Code", "Tests", "Docs", "Config", "Dependencies", "Generated"]

    /// The file-type bucket for one path.
    static func ruleTitle(_ path: String) -> String {
        let range = NSRange(path.startIndex..., in: path)
        return rules.first { $0.pattern.firstMatch(in: path, range: range) != nil }?.title ?? "Code"
    }

    /// Type groups in review order: code first, machine output last. Ready on
    /// the first frame, so the guide lens never waits on the model to group.
    static func ruleGroups(_ paths: [String]) -> [PrReviewGroup] {
        var byTitle: [String: [String]] = [:]
        for path in paths { byTitle[ruleTitle(path), default: []].append(path) }
        return ruleOrder.compactMap { title in
            byTitle[title].map { PrReviewGroup(title: title, files: $0) }
        }
    }

    // MARK: Guide sections

    /// The guide's sections matched to the diff's paths: exactly, then by
    /// suffix (the model sometimes drops a prefix). Each path lands in one
    /// section, and files no section claimed come back as a trailing group so
    /// the guide never hides part of a change. A stale guide calls them new.
    static func guideSections(_ guide: PrReviewGuide, paths: [String]) -> [PrReviewGroup] {
        let known = Set(paths)
        var unclaimed = known
        var byBasename: [String: [String]] = [:]
        for path in paths { byBasename[basename(path), default: []].append(path) }
        func resolve(_ file: String) -> String? {
            if known.contains(file) { return file }
            return byBasename[basename(file)]?.first {
                $0.hasSuffix("/\(file)") || file.hasSuffix("/\($0)")
            }
        }
        var groups = guide.sections.map { section -> PrReviewGroup in
            var files: [String] = []
            for file in section.files {
                guard let path = resolve(file), unclaimed.contains(path) else { continue }
                unclaimed.remove(path)
                files.append(path)
            }
            return PrReviewGroup(title: section.title, explanation: section.explanation, files: files)
        }
        let leftover = paths.filter { unclaimed.contains($0) }
        if !leftover.isEmpty {
            groups.append(PrReviewGroup(
                title: guide.stale ? staleLeftoverTitle : leftoverTitle,
                explanation: guide.stale
                    ? "Files the latest commits added. The guide is updating to cover them."
                    : "Changes the guide didn't group into a section.",
                files: leftover
            ))
        }
        return groups
    }

    /// The page's one grouping: the guide's sections once written, file types
    /// until then (or when it fails), so steps and progress never disagree.
    static func reviewGroups(guide: PrReviewGuide?, paths: [String]) -> (groups: [PrReviewGroup], fromGuide: Bool) {
        if let guide, !guide.sections.isEmpty {
            let sections = guideSections(guide, paths: paths).filter { !$0.files.isEmpty }
            if !sections.isEmpty { return (sections, true) }
        }
        return (ruleGroups(paths), false)
    }

    // MARK: Progress

    /// Groups restricted to `paths`, files no group claimed collected last,
    /// and each group's progress. File order follows `paths`.
    static func progress(
        _ groups: [PrReviewGroup],
        paths: [String],
        reviewed: Set<String>,
        changed: Set<String>,
        leftoverTitle: String = leftoverTitle
    ) -> [PrReviewGroupProgress] {
        let position = Dictionary(paths.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var claimed = Set<String>()
        var result: [PrReviewGroupProgress] = []
        func add(_ title: String, _ explanation: String?, _ files: [String]) {
            guard !files.isEmpty else { return }
            let sorted = files.sorted { position[$0]! < position[$1]! }
            result.append(PrReviewGroupProgress(
                title: title,
                explanation: explanation,
                files: sorted,
                reviewed: sorted.filter(reviewed.contains).count,
                changed: sorted.filter(changed.contains).count
            ))
        }
        for group in groups {
            let files = group.files.filter { path in
                guard position[path] != nil, !claimed.contains(path) else { return false }
                claimed.insert(path)
                return true
            }
            add(group.title, group.explanation, files)
        }
        add(leftoverTitle, nil, paths.filter { !claimed.contains($0) })
        return result
    }

    /// The paths a bulk action flips to reach the requested state.
    static func bulkChanges(
        _ paths: [String],
        reviewed: Set<String>,
        action: PrReviewBulkAction
    ) -> (mark: [String], unmark: [String]) {
        var mark: [String] = []
        var unmark: [String] = []
        for path in paths {
            let isReviewed = reviewed.contains(path)
            switch action {
            case .mark: if !isReviewed { mark.append(path) }
            case .reset: if isReviewed { unmark.append(path) }
            case .invert: if isReviewed { unmark.append(path) } else { mark.append(path) }
            }
        }
        return (mark, unmark)
    }

    /// Every changed file under a folder.
    static func filesInFolder(_ paths: [String], folder: String) -> [String] {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return paths.filter { $0.hasPrefix(prefix) }
    }

    static func folder(of path: String) -> String? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        return String(path[..<slash])
    }

    /// The first unreviewed file after `current` in reading order, wrapping.
    static func nextUnreviewed(_ order: [String], after current: String?, reviewed: Set<String>) -> String? {
        let start = current.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let rotated = order[min(start, order.count)...] + order[..<min(start, order.count)]
        return rotated.first { !reviewed.contains($0) }
    }

    private static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

// MARK: - Local review marks

/// A per-file hash of a diff, so a review mark kept on this device knows when
/// the file it vouches for has changed. FNV-1a over the hunk text, skipping
/// the `index` line whose blob ids change on every rebase without the diff
/// changing — the same scheme as the web.
enum PrReviewHash {
    static func hash<S: Sequence>(lines: S) -> String where S.Element: StringProtocol {
        var hash: UInt32 = 0x811c_9dc5
        for line in lines {
            if line.hasPrefix("index ") { continue }
            for unit in line.utf16 {
                hash ^= UInt32(unit)
                hash = hash &* 0x0100_0193
            }
            hash ^= 10
            hash = hash &* 0x0100_0193
        }
        return String(hash, radix: 36)
    }

    static func hash(patch: String) -> String {
        hash(lines: patch.split(separator: "\n", omittingEmptySubsequences: false))
    }

    static func hashes(of files: [PrPatchFile]) -> [String: String] {
        Dictionary(
            files.map { ($0.path, hash(lines: $0.lines.map(\.text))) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    static func hashes(of patches: [FilePatch]) -> [String: String] {
        Dictionary(
            patches.map { ($0.path, hash(patch: $0.patch)) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

/// Review marks kept on this device, for diffs with no provider-side viewed
/// state: a session's worktree, and pull requests on hosts without it. Each
/// mark stores the file's diff hash, so a file edited after review reads as
/// changed rather than reviewed — the same thing GitHub reports as DIRTY.
struct PrLocalReviewStore {
    static let prefix = "os1.reviewedFiles."
    static let indexKey = "os1.reviewedFiles.index"
    /// Reviews remembered per device; the oldest are forgotten first.
    static let maxReviews = 100

    var defaults: UserDefaults = .standard

    func read(_ key: String) -> [String: String] {
        defaults.dictionary(forKey: Self.prefix + key) as? [String: String] ?? [:]
    }

    func write(_ key: String, _ value: [String: String]) {
        var index = defaults.stringArray(forKey: Self.indexKey) ?? []
        index.removeAll { $0 == key }
        index.append(key)
        while index.count > Self.maxReviews {
            defaults.removeObject(forKey: Self.prefix + index.removeFirst())
        }
        defaults.set(index, forKey: Self.indexKey)
        if value.isEmpty {
            defaults.removeObject(forKey: Self.prefix + key)
        } else {
            defaults.set(value, forKey: Self.prefix + key)
        }
    }

    /// Mark or unmark `paths` against the current hashes and save. Returns the
    /// stored map so the caller can derive state without reading it back.
    @discardableResult
    func setReviewed(
        _ key: String,
        paths: [String],
        reviewed: Bool,
        hashes: [String: String]
    ) -> [String: String] {
        var stored = read(key)
        for path in paths {
            if reviewed, let hash = hashes[path] {
                stored[path] = hash
            } else {
                stored.removeValue(forKey: path)
            }
        }
        write(key, stored)
        return stored
    }

    /// Reviewed and changed-since-review sets for the current diff. A mark for
    /// a file no longer in the diff counts as neither.
    static func state(stored: [String: String], hashes: [String: String]) -> (reviewed: Set<String>, changed: Set<String>) {
        var reviewed = Set<String>()
        var changed = Set<String>()
        for (path, hash) in hashes {
            guard let seen = stored[path] else { continue }
            if seen == hash { reviewed.insert(path) } else { changed.insert(path) }
        }
        return (reviewed, changed)
    }

    static func pullRequestKey(repo: String?, number: Int) -> String {
        "pr:\(repo.flatMap { $0.isEmpty ? nil : $0 } ?? "pr")#\(number)"
    }

    static func worktreeKey(sessionId: String, repo: String) -> String {
        "worktree:\(sessionId):\(repo)"
    }
}

// MARK: - Files later commits removed

/// Files an earlier head of this review had that later loads no longer do.
/// Tracked while the review is open, so a reviewer partway through sees what
/// disappeared rather than having it silently drop out of the list.
struct PrRemovedFiles: Equatable, Sendable {
    let target: String
    let known: [String]
    let removed: [String]

    static func next(_ previous: PrRemovedFiles?, target: String, current: [String]) -> PrRemovedFiles {
        guard let previous, previous.target == target else {
            return PrRemovedFiles(target: target, known: current, removed: [])
        }
        let now = Set(current)
        var seen = Set<String>()
        let removed = (previous.removed + previous.known.filter { !now.contains($0) })
            .filter { !now.contains($0) && seen.insert($0).inserted }
        return PrRemovedFiles(target: target, known: current, removed: removed)
    }
}

/// Resolved review threads per file, for the counts on file headers.
enum PrResolvedThreads {
    static func countByPath(_ threads: [PrReviewThread]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for thread in threads where thread.isResolved != false {
            if let path = thread.path { counts[path, default: 0] += 1 }
        }
        return counts
    }
}

// MARK: - The marks on screen

/// A review's marks and where they live: GitHub's per-viewer viewed state,
/// this device (worktrees, hosts without viewed state), or nowhere yet.
struct PrReviewMarks: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case unavailable
        case github(prId: String)
        case local(key: String)
    }

    var source: Source = .unavailable
    var reviewed = Set<String>()
    var changed = Set<String>()

    var isAvailable: Bool { source != .unavailable }

    func state(of path: String) -> PrFileReviewState {
        PrFileReviewState.of(path, reviewed: reviewed, changed: changed)
    }

    /// The optimistic local flip for a provider-side change. Marking or
    /// unmarking a file either way settles its changed-since-review state.
    mutating func apply(_ paths: [String], reviewed next: Bool) {
        for path in paths {
            if next { reviewed.insert(path) } else { reviewed.remove(path) }
            changed.remove(path)
        }
    }

    static func github(_ files: PrViewedFiles) -> PrReviewMarks {
        let reviewed = Set(files.viewed)
        return PrReviewMarks(
            source: .github(prId: files.prId),
            reviewed: reviewed,
            changed: Set(files.changed).subtracting(reviewed)
        )
    }

    static func local(key: String, stored: [String: String], hashes: [String: String]) -> PrReviewMarks {
        let state = PrLocalReviewStore.state(stored: stored, hashes: hashes)
        return PrReviewMarks(source: .local(key: key), reviewed: state.reviewed, changed: state.changed)
    }
}

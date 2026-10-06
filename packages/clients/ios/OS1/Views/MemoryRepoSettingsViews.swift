import Observation
import SwiftUI

// Settings → Memory, repository half: the list of memory repositories (git,
// Agent Memory Repo format) and one page per repository with its remote and
// sync state, recent changes (diff, originating session, revert) and files.
// Mirrors the web's MemoryRepoPage.tsx. The entry editor beside it
// (`MemorySettingsView`) keeps working through the same model, so a revert or
// a sync here refreshes the entries and both settings caches.

/// What Settings → Memory shows, shared by the list and every page pushed from
/// it so a mutation anywhere refreshes everything that depends on it.
@MainActor
@Observable
final class MemorySettingsModel {
    static let scopesCacheKey = "memory"
    static let reposCacheKey = "memory-repos"

    var scopes: [MemoryScope]? = SettingsCache.value(MemorySettingsModel.scopesCacheKey)
    var repos: [MemoryRepo]? = SettingsCache.value(MemorySettingsModel.reposCacheKey)
    var loading = false
    var error: String?
    var reposError: String?

    func load() async {
        loading = true
        async let entries: Void = loadEntries()
        async let repositories: Void = loadRepos()
        _ = await (entries, repositories)
        loading = false
    }

    func loadEntries() async {
        do {
            let fetched = try await SettingsAPI.memoryScopes()
            scopes = fetched
            error = nil
            SettingsCache.save(Self.scopesCacheKey, fetched)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadRepos() async {
        do {
            let fetched = try await SettingsAPI.memoryRepos()
            apply(repos: fetched)
            reposError = nil
        } catch {
            if Self.isMissingRoute(error) {
                // A server that keeps memory outside git has no repositories.
                apply(repos: [])
                reposError = nil
            } else {
                reposError = error.localizedDescription
            }
        }
    }

    /// A sync or remote save answered with the new status: show it on the
    /// list row too, without another round trip.
    func update(remote: MemoryRemoteStatus, for name: String) {
        guard var current = repos, let index = current.firstIndex(where: { $0.name == name }) else { return }
        current[index].remote = remote
        apply(repos: current)
    }

    func repo(named name: String) -> MemoryRepo? { repos?.first { $0.name == name } }

    /// After anything that rewrites a repository (revert, a sync that pulled
    /// changes): entries and HEADs may both have moved.
    func repositoryChanged() async {
        async let entries: Void = loadEntries()
        async let repositories: Void = loadRepos()
        _ = await (entries, repositories)
    }

    private func apply(repos fetched: [MemoryRepo]) {
        repos = fetched
        SettingsCache.save(Self.reposCacheKey, fetched)
    }

    nonisolated static func isMissingRoute(_ error: Error) -> Bool {
        guard let api = error as? OS1API.APIError else { return false }
        switch api {
        case .http(let code): return code == 404
        case .server(let message): return message == "entry not found"
        default: return false
        }
    }
}

// MARK: - List rows

struct MemoryRepoRow: View {
    let repo: MemoryRepo

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if repo.remoteStatus.state != .localOnly {
                MemoryRemoteChip(status: repo.remoteStatus)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let remote = repo.remoteStatus.url.flatMap { $0.isEmpty ? nil : $0 } ?? "local only"
        return "\(repo.name) · \(remote)"
    }
}

struct MemoryRemoteChip: View {
    let status: MemoryRemoteStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(status.stateLabel)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var color: Color {
        switch status.state {
        case .synced: .green
        case .failed, .conflict: .red
        case .notSynced, .localOnly: .secondary
        }
    }
}

// MARK: - One repository

struct MemoryRepoDetailView: View {
    let repoName: String
    let model: MemorySettingsModel

    @State private var commits: [MemoryCommit]?
    @State private var historyError: String?
    @State private var files: [String]?
    @State private var filesError: String?
    @State private var remoteURL = ""
    @State private var remoteBusy = false
    @State private var remoteMessage: String?
    #if DEBUG
    @State private var fixtureCommit: String? = ProcessInfo.processInfo.environment["OS1_MEMORY_COMMIT"]
    @State private var fixtureFile: String? = ProcessInfo.processInfo.environment["OS1_MEMORY_FILE"]
    #endif

    private var repo: MemoryRepo? { model.repo(named: repoName) }
    private var status: MemoryRemoteStatus { repo?.remoteStatus ?? MemoryRemoteStatus() }

    var body: some View {
        List {
            remoteSection
            historySection
            filesSection
        }
        .insetGroupedListCompat()
        .navigationTitle(repo.map { "\($0.title) memory" } ?? "Memory repository")
        .inlineTitleBarCompat()
        .task {
            // Opened before the list loaded (a cold cache): the remote and
            // the title come from the repository list.
            async let repos: Void = model.repos == nil ? model.loadRepos() : ()
            _ = await (repos, loadAll())
        }
        .refreshable {
            async let repos: Void = model.loadRepos()
            _ = await (repos, loadAll())
        }
        .onAppear { remoteURL = status.url ?? "" }
        .onChange(of: status.url) { _, url in remoteURL = url ?? "" }
        #if DEBUG
        // Screenshot hooks: `OS1_MEMORY_COMMIT=<sha>` / `OS1_MEMORY_FILE=<path>`
        // land on a change or a file, taps a scripted run cannot make.
        .navigationDestination(item: $fixtureCommit) { sha in
            if let commit = commits?.first(where: { $0.sha.hasPrefix(sha) }) {
                commitPage(commit)
            } else {
                ProgressView()
            }
        }
        .navigationDestination(item: $fixtureFile) { path in
            MemoryFileView(repo: repoName, path: path)
        }
        #endif
    }

    // Remote: optional, and private. Saving syncs at once; a failed sync or a
    // conflict comes back as a status, not as an error.
    private var remoteSection: some View {
        Section {
            TextField("Remote URL", text: $remoteURL, prompt: Text(MemoryRepoCopy.remotePlaceholder))
                .autocorrectionDisabled()
                .urlFieldCompat()
                .onSubmit { Task { await saveRemote() } }
            HStack {
                Button("Save") { Task { await saveRemote() } }
                    .disabled(remoteBusy || trimmedURL == (status.url ?? ""))
                if status.url?.isEmpty == false {
                    Spacer()
                    Button("Sync now") { Task { await sync() } }
                        .disabled(remoteBusy)
                }
                if remoteBusy {
                    Spacer()
                    ProgressView()
                }
            }
            .buttonStyle(.borderless)
            if status.state != .localOnly {
                HStack {
                    MemoryRemoteChip(status: status)
                    Spacer()
                    if let date = Session.parseISO(status.lastSyncAt) {
                        Text("Last sync \(date, format: .relative(presentation: .named))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let error = status.error, !error.isEmpty {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if status.conflict != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Conflicting files")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    let paths = status.conflictFiles
                    Text(paths.isEmpty ? "unknown" : paths.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            if let remoteMessage {
                Text(remoteMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            #if os(macOS)
            // A Mac section footer is one truncated line; this one matters.
            Text(Self.remoteHelp).font(.caption).foregroundStyle(.secondary)
            #endif
        } header: {
            Text("Remote")
        } footer: {
            #if os(iOS)
            Text(Self.remoteHelp)
            #endif
        }
    }

    private var historySection: some View {
        Section {
            if let historyError {
                settingsErrorRow(historyError) { Task { await loadHistory() } }
            } else if let commits {
                if commits.isEmpty {
                    Text("No changes yet. They appear here once a session saves memory.")
                        .foregroundStyle(.secondary)
                }
                ForEach(commits) { commit in
                    NavigationLink {
                        commitPage(commit)
                    } label: {
                        MemoryCommitRow(commit: commit)
                    }
                }
            } else {
                settingsLoadingRow
            }
        } header: {
            Text("Recent changes")
        } footer: {
            Text("Sessions clone this repository, edit it and push. Every change can be reverted.")
        }
    }

    private var filesSection: some View {
        Section("Files") {
            if let filesError {
                settingsErrorRow(filesError) { Task { await loadFiles() } }
            } else if let files {
                if files.isEmpty {
                    Text("No files yet.").foregroundStyle(.secondary)
                }
                ForEach(files, id: \.self) { path in
                    NavigationLink {
                        MemoryFileView(repo: repoName, path: path)
                    } label: {
                        Label(path, systemImage: "text.document")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } else {
                settingsLoadingRow
            }
        }
    }

    private func commitPage(_ commit: MemoryCommit) -> some View {
        MemoryCommitView(repo: repoName, commit: commit) {
            await afterRepositoryChange()
        }
    }

    private static let remoteHelp = "Optional. Syncs this repository with a private git remote so other tools can use the same memory. GitHub repositories must be private."

    private var trimmedURL: String { remoteURL.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func loadAll() async {
        async let history: Void = loadHistory()
        async let listed: Void = loadFiles()
        _ = await (history, listed)
    }

    private func loadHistory() async {
        do {
            commits = try await SettingsAPI.memoryHistory(repo: repoName)
            historyError = nil
        } catch {
            historyError = error.localizedDescription
        }
    }

    private func loadFiles() async {
        do {
            files = try await SettingsAPI.memoryFiles(repo: repoName)
            filesError = nil
        } catch {
            filesError = error.localizedDescription
        }
    }

    private func afterRepositoryChange() async {
        async let local: Void = loadAll()
        async let shared: Void = model.repositoryChanged()
        _ = await (local, shared)
    }

    private func saveRemote() async {
        guard !remoteBusy, trimmedURL != (status.url ?? "") else { return }
        await runRemote { try await SettingsAPI.saveMemoryRemote(repo: repoName, url: trimmedURL) }
    }

    private func sync() async {
        guard !remoteBusy else { return }
        await runRemote { try await SettingsAPI.syncMemoryRemote(repo: repoName) }
    }

    private func runRemote(_ action: () async throws -> MemoryRemoteStatus) async {
        remoteBusy = true
        remoteMessage = nil
        do {
            let next = try await action()
            model.update(remote: next, for: repoName)
            remoteURL = next.url ?? ""
            // A sync may have pulled the remote's changes in.
            await afterRepositoryChange()
        } catch {
            remoteMessage = error.localizedDescription
        }
        remoteBusy = false
    }
}

struct MemoryCommitRow: View {
    let commit: MemoryCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(commit.title)
                .foregroundStyle(.primary)
                .lineLimit(3)
            HStack(spacing: 4) {
                if let author = commit.author, !author.isEmpty {
                    Text(author)
                    Text("·")
                }
                if let date = Session.parseISO(commit.date) {
                    Text(date, format: .relative(presentation: .named))
                    Text("·")
                }
                Text(commit.fileCountLabel)
                Text("·")
                Text(commit.shortSha).monospaced()
                if commit.openableSessionId != nil {
                    Image(systemName: "bubble.left")
                        .accessibilityLabel("From a session")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

// MARK: - One change

struct MemoryCommitView: View {
    let repo: String
    let commit: MemoryCommit
    let onReverted: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var diff: RenderedDiff?
    @State private var diffError: String?
    @State private var confirmingRevert = false
    @State private var reverting = false
    @State private var revertError: String?

    /// A diff is capped at 200 KB server-side; lines past this many would only
    /// cost layout.
    private static let lineLimit = 4000

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(commit.title).font(.headline)
                    if let body = commit.body, !body.isEmpty {
                        Text(body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("Author", value: commit.author ?? "Unknown")
                if let pushedBy = commit.pushedBy, !pushedBy.isEmpty, pushedBy != commit.author {
                    LabeledContent("Pushed by", value: pushedBy)
                }
                if let date = Session.parseISO(commit.date) {
                    LabeledContent("When") {
                        Text(date, format: .dateTime.day().month().year().hour().minute())
                    }
                }
                LabeledContent("Commit") {
                    Text(commit.shortSha).monospaced().textSelection(.enabled)
                }
            }
            Section {
                if let sessionId = commit.openableSessionId {
                    Button {
                        SessionLinks.requestOpen(sessionId)
                    } label: {
                        Label("Open session", systemImage: "bubble.left.and.bubble.right")
                    }
                }
                Button(role: .destructive) {
                    confirmingRevert = true
                } label: {
                    HStack {
                        Label("Revert change", systemImage: "arrow.uturn.backward")
                        if reverting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(reverting)
                if let revertError {
                    Text(revertError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            if let files = commit.files, !files.isEmpty {
                Section(commit.fileCountLabel.capitalized) {
                    ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                        LabeledContent {
                            Text(file.statusLabel)
                        } label: {
                            Text(file.path ?? "")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            Section("Diff") {
                if let diffError {
                    settingsErrorRow(diffError) { Task { await loadDiff() } }
                } else if let diff {
                    // One attributed block, not a row per line: rows carry a
                    // minimum height on Mac and a diff reads as one well.
                    Text(diff.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    if diff.hiddenLines > 0 {
                        Text("\(diff.hiddenLines) more lines not shown.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    settingsLoadingRow
                }
            }
        }
        .insetGroupedListCompat()
        .navigationTitle(commit.shortSha)
        .inlineTitleBarCompat()
        .task { await loadDiff() }
        .confirmationDialog(
            "Revert this change?",
            isPresented: $confirmingRevert,
            titleVisibility: .visible
        ) {
            Button("Revert change", role: .destructive) { Task { await revert() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Adds a new change that undoes “\(commit.title)”. Sessions pick it up on their next pull.")
        }
    }

    struct RenderedDiff: Sendable {
        var text: AttributedString
        var hiddenLines: Int
    }

    nonisolated static func render(_ diff: String, limit: Int) -> RenderedDiff {
        let lines = MemoryDiffLine.lines(diff)
        var text = AttributedString()
        for line in lines.prefix(limit) {
            var piece = AttributedString((line.id == 0 ? "" : "\n") + line.text)
            switch line.tone {
            case .add: piece.foregroundColor = Color.green
            case .remove: piece.foregroundColor = Color.red
            case .meta: piece.foregroundColor = Color.gray
            case .plain: break
            }
            text += piece
        }
        return RenderedDiff(text: text, hiddenLines: max(0, lines.count - limit))
    }

    private func loadDiff() async {
        do {
            let raw = try await SettingsAPI.memoryCommitDiff(repo: repo, sha: commit.sha)
            let limit = Self.lineLimit
            diff = await Task.detached(priority: .userInitiated) { Self.render(raw, limit: limit) }.value
            diffError = nil
        } catch {
            diffError = error.localizedDescription
        }
    }

    private func revert() async {
        reverting = true
        revertError = nil
        do {
            _ = try await SettingsAPI.revertMemoryCommit(repo: repo, sha: commit.sha)
            await onReverted()
            reverting = false
            dismiss()
        } catch {
            revertError = error.localizedDescription
            reverting = false
        }
    }
}

// MARK: - One file

struct MemoryFileView: View {
    let repo: String
    let path: String

    @State private var content: String?
    @State private var error: String?

    var body: some View {
        ScrollView {
            Group {
                if let error {
                    settingsErrorRow(error) { Task { await load() } }
                } else if let content {
                    Text(content.isEmpty ? "Empty file." : content)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    settingsLoadingRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .inlineTitleBarCompat()
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            content = try await SettingsAPI.memoryFile(repo: repo, path: path)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

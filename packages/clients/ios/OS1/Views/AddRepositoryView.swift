import SwiftUI

/// Adding a project, one source at a time: clone a remote, register a checkout
/// already on the server, or start a new repository. The write half of the
/// web's `AddRepoPicker` (SetupRepos.tsx), on the same `/api/setup` routes.
///
/// Two ways in, one flow. Settings → Repositories pushes it; the sidebar's
/// workspace options → Add project presents it as a sheet (`AddProjectSheet`),
/// already pinned to the source picked from that submenu, as the web does.
///
/// Every registration is confirmed because none is a preference. The server
/// clones, registers or creates before it answers, and no client route
/// unregisters one again (`/api/repos/:id/remove` is fenced to desktop
/// profiles), so an accidental tap leaves a checkout on the instance for
/// somebody to remove by hand. What the server refuses (an owner the GitHub
/// App is not installed on, a repo already registered, a path that is not a
/// Git checkout) comes back as its own text, inline.
struct AddRepositoryView: View {
    let source: AddRepositorySource
    /// Refresh whatever lists repositories behind this screen.
    let onAdded: () async -> Void
    /// Close once something registers. The sidebar's sheet always does; the
    /// Settings remote list stays open so a second repo is one more tap.
    var closesAfterAdding = true

    @State private var model = RepoRegistrationModel()
    @State private var confirming: RepoRegistration?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch source {
            case .remote: RemoteRepositoryPicker(model: model, confirm: { confirming = $0 })
            case .local: LocalFolderForm(model: model, confirm: { confirming = $0 })
            case .new: NewRepositoryForm(model: model, confirm: { confirming = $0 })
            }
        }
        .navigationTitle(source.title)
        .inlineTitleBarCompat()
        .disabled(model.isBusy)
        .overlay {
            if let pending = model.pending { pendingOverlay(pending) }
        }
        // A registration in flight holds the screen: closing it would drop
        // the error if the server refused.
        .interactiveDismissDisabled(model.isBusy)
        .navigationBarBackButtonHidden(model.isBusy)
        .confirmationDialog(
            confirming?.confirmTitle ?? "",
            isPresented: Binding(
                get: { confirming != nil },
                set: { if !$0 { confirming = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirming
        ) { registration in
            Button(registration.confirmButton) {
                confirming = nil
                Task { await register(registration) }
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: { registration in
            Text(registration.confirmMessage)
        }
    }

    private func pendingOverlay(_ pending: RepoRegistration) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(pending.pendingText)
                .font(.callout)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .truncationMode(.middle)
            Text("This can take a minute on a large repository.")
                .font(.footnote)
                .foregroundStyle(OS1VisualStyle.textDim)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OS1VisualStyle.background.opacity(0.94))
        .accessibilityElement(children: .combine)
    }

    private func register(_ registration: RepoRegistration) async {
        let registered = await model.register(registration, onAdded: onAdded)
        guard registered else { return }
        Haptics.play(.commit)
        if closesAfterAdding || source != .remote { dismiss() }
    }
}

/// The sidebar's Add project sheet: one source of the picker with its own
/// navigation bar and Cancel.
struct AddProjectSheet: View {
    let source: AddRepositorySource
    let onAdded: () async -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AddRepositoryView(source: source, onAdded: onAdded)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 480, idealHeight: 560)
        #endif
    }
}

// MARK: - Clone repository

/// The repos the instance's GitHub credential can see, plus the code.storage
/// organization's when that integration is configured, and a tap to clone one.
/// With no GitHub list at all, an `owner/name` field stands in, as on the web.
private struct RemoteRepositoryPicker: View {
    let model: RepoRegistrationModel
    let confirm: (RepoRegistration) -> Void

    @State private var github: OS1API.RepoBrowse?
    @State private var codeStorage: OS1API.RepoBrowse?
    @State private var codeStorageError: String?
    @State private var loadError: String?
    @State private var loading = false
    @State private var query = ""
    @State private var manual = ""

    var body: some View {
        List {
            if let error = model.error ?? loadError {
                Section { Text(error).foregroundStyle(.red) }
            }

            if let github {
                if github.source == nil {
                    manualSection(github)
                } else {
                    githubSection(github)
                }
            } else if loading {
                Section { ProgressView("Loading repositories…") }
            } else if loadError != nil {
                manualSection(nil)
            }

            if let codeStorage, codeStorage.source == "org" {
                Section {
                    let matches = RepoPicker.matching(codeStorage.repos ?? [], query: query)
                    if matches.isEmpty {
                        Text(query.isEmpty ? "Nothing to add." : "No repositories match.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(matches) { repo in
                            row(repo, registration: .codeStorage(fullName: repo.fullName))
                        }
                    }
                } header: {
                    Text("code.storage")
                }
            } else if let codeStorageError {
                Section {
                    Text(codeStorageError).foregroundStyle(OS1VisualStyle.textDim)
                } header: {
                    Text("code.storage")
                }
            }
        }
        .insetGroupedListCompat()
        // Only with a list to filter: the typed-name fallback has nothing to
        // search, and an idle search bar under it reads as a second field.
        .modifier(SearchableWhen(enabled: hasList, text: $query))
        .task { await load() }
        .refreshable { await load() }
    }

    private var hasList: Bool {
        github?.source != nil || codeStorage?.source == "org"
    }

    @ViewBuilder
    private func githubSection(_ browse: OS1API.RepoBrowse) -> some View {
        Section {
            let matches = RepoPicker.matching(browse.repos ?? [], query: query)
            if matches.isEmpty {
                Text(query.isEmpty ? "Nothing to add." : "No repositories match.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(matches) { repo in
                    row(repo, registration: .github(fullName: repo.fullName))
                }
            }
        } header: {
            if codeStorage?.source == "org" { Text("GitHub") }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let unavailable = browse.unavailableInstallations, !unavailable.isEmpty {
                    Text("Couldn’t load repositories from \(unavailable.joined(separator: ", ")).")
                }
                Text(
                    browse.source == "user"
                        ? "Browsing as your connected GitHub account. Only repos it can reach are listed."
                        : "Only repositories shared with the workspace's GitHub App are listed."
                )
            }
        }
    }

    /// No list to pick from: the instance holds no GitHub credential, the App
    /// cannot list yet, or the list failed. A name still registers.
    @ViewBuilder
    private func manualSection(_ browse: OS1API.RepoBrowse?) -> some View {
        let registration = RepoRegistration.github(fullName: manual)
        Section {
            TextField(text: $manual, prompt: Text("owner/name")) { Text("Repository full name") }
                .labelsHidden()
                .font(.body.monospaced())
                .noAutocapitalizationCompat()
                .autocorrectionDisabled()
                .onSubmit { if let registration { confirm(registration) } }
            Button("Add") {
                if let registration { confirm(registration) }
            }
            .disabled(registration == nil || model.isBusy)
        } footer: {
            Text(
                browse == nil
                    ? "Couldn’t load the GitHub repo list. You can still add a repository by name."
                    : browse?.appConfigured == true
                        ? "The GitHub App can’t list repositories yet. Grant it access on GitHub, or add a repository by name."
                        : "No GitHub credential on this instance, so there is no list to pick from. Add a public repository by name, or connect GitHub under Settings → Account."
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func row(_ repo: OS1API.BrowsableRepo, registration: RepoRegistration?) -> some View {
        let registered = repo.registered == true
            || (registration.map(model.wasAdded) ?? false)
        Button {
            if let registration { confirm(registration) }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(repo.fullName)
                            .foregroundStyle(OS1VisualStyle.text)
                            .lineLimit(1)
                            .truncationMode(.head)
                        if repo.isPrivate == true {
                            // Explicit colours throughout this row, never
                            // `.secondary`: inside a Button the hierarchical
                            // styles resolve against the tint, so every
                            // description and badge on a row you can still tap
                            // came out accent teal, reading as a link.
                            Text("Private")
                                .font(.caption2)
                                .foregroundStyle(OS1VisualStyle.textDim)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(OS1VisualStyle.raised))
                        }
                    }
                    if let description = repo.description, !description.isEmpty {
                        Text(description)
                            .font(.footnote)
                            .foregroundStyle(OS1VisualStyle.textDim)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if registration != nil, model.pending == registration {
                    ProgressView()
                } else if registered {
                    Text("Added")
                        .font(.footnote)
                        .foregroundStyle(OS1VisualStyle.textDim)
                } else {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(OS1VisualStyle.iconTint)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(registered || registration == nil || model.isBusy)
        .accessibilityLabel(
            registered
                ? "\(repo.fullName), already registered"
                : "Add \(repo.fullName)"
        )
    }

    private func load() async {
        loading = true
        defer { loading = false }
        async let githubList = OS1API.browsableRepos()
        async let codeStorageList = OS1API.codeStorageRepos()
        do {
            github = try await githubList
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        // Configured but failing stays visible while GitHub remains usable;
        // unconfigured answers `source: null` and shows nothing.
        do {
            codeStorage = try await codeStorageList
            codeStorageError = nil
        } catch {
            codeStorageError = "Couldn’t reach code.storage right now."
        }
    }
}

private struct SearchableWhen: ViewModifier {
    let enabled: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text)
        } else {
            content
        }
    }
}

// MARK: - Local folder

/// A Git checkout already on the server, by its absolute path there. The path
/// is typed because the folder is on the server's disk, which this device
/// cannot browse.
private struct LocalFolderForm: View {
    let model: RepoRegistrationModel
    let confirm: (RepoRegistration) -> Void

    @State private var path = ""
    @FocusState private var focused: Bool

    var body: some View {
        let registration = RepoRegistration.local(path: path)
        Form {
            Section {
                TextField(text: $path, prompt: Text("/srv/repos/repository")) {
                    Text("Absolute repository path on the server")
                }
                .labelsHidden()
                .font(.body.monospaced())
                .noAutocapitalizationCompat()
                .autocorrectionDisabled()
                .focused($focused)
                .onSubmit { if let registration { confirm(registration) } }
            } footer: {
                Text("Use a Git checkout on the server with a working origin remote.")
            }
            Section {
                Button("Add") {
                    if let registration { confirm(registration) }
                }
                .disabled(registration == nil || model.isBusy)
            } footer: {
                if !path.isEmpty, registration == nil {
                    Text("Enter an absolute path, starting with /.")
                }
            }
            if let error = model.error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .onAppear { focused = true }
    }
}

// MARK: - New repository

/// A new repository: on this server alone, or on GitHub. GitHub creation
/// happens on github.com (the server refuses to create there itself), then
/// Connect registers it, the same two steps as the web's `NewRepoForm`.
private struct NewRepositoryForm: View {
    let model: RepoRegistrationModel
    let confirm: (RepoRegistration) -> Void

    private static let serverOnly = "\u{0}server"
    private static let otherOwner = "\u{0}other"

    @State private var name = ""
    @State private var owners: [OS1API.GithubOwner]?
    @State private var ownersError: String?
    @State private var chosen: String?
    @State private var customOwner = ""
    @State private var openedGithub = false
    @State private var loadAttempt = 0
    @FocusState private var nameFocused: Bool
    @Environment(\.openURL) private var openURL

    private var defaultLocation: String {
        let accounts = owners ?? []
        return accounts.first { $0.selected == true }?.login
            ?? accounts.first?.login
            ?? Self.serverOnly
    }

    private var location: String { chosen ?? defaultLocation }
    private var onGithub: Bool { location != Self.serverOnly }
    private var owner: String {
        location == Self.otherOwner
            ? customOwner.trimmingCharacters(in: .whitespaces)
            : location
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var registration: RepoRegistration? {
        .new(name: name, owner: onGithub ? owner : nil)
    }

    var body: some View {
        Form {
            Section {
                if owners == nil {
                    ProgressView("Loading GitHub owners…")
                } else {
                    Picker("Owner", selection: Binding(
                        get: { location },
                        set: { chosen = $0; openedGithub = false }
                    )) {
                        ForEach(owners ?? []) { account in
                            Text("\(account.login) on GitHub").tag(account.login)
                        }
                        Text("Another GitHub owner…").tag(Self.otherOwner)
                        Text("This server only").tag(Self.serverOnly)
                    }
                    if location == Self.otherOwner {
                        TextField(text: $customOwner, prompt: Text("GitHub username or organization")) {
                            Text("GitHub owner")
                        }
                        .labelsHidden()
                        .noAutocapitalizationCompat()
                        .autocorrectionDisabled()
                    }
                }
                TextField(text: $name, prompt: Text("my-project")) { Text("Repository name") }
                .labelsHidden()
                .font(.body.monospaced())
                .noAutocapitalizationCompat()
                .autocorrectionDisabled()
                .focused($nameFocused)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let ownersError {
                        Text(ownersError)
                    }
                    if onGithub, !owner.isEmpty, !RepoRegistration.validGithubOwner(owner) {
                        Text("Enter a GitHub username or organization, not a URL.")
                    }
                    if !trimmedName.isEmpty, !RepoRegistration.validNewRepoName(trimmedName) {
                        Text("Letters, digits, dots, dashes and underscores, starting with a letter or digit.")
                    }
                    Text(
                        onGithub
                            ? "Create it on GitHub first: choose Private and add a README, then come back and connect it."
                            : "Starts an empty repository on this server with a first commit on main. Sessions get branches, diffs and local review, but no GitHub pull requests."
                    )
                }
            }

            if ownersError != nil {
                Section {
                    Button("Retry") { loadAttempt += 1 }
                }
            }

            Section {
                if onGithub {
                    Button("Open GitHub") {
                        guard registration != nil,
                              let url = RepoRegistration.githubNewRepoURL(
                                owner: owner,
                                name: trimmedName
                              )
                        else { return }
                        openedGithub = true
                        openURL(url)
                    }
                    .disabled(registration == nil || model.isBusy)
                    if openedGithub {
                        Button("Connect repository") {
                            if let registration { confirm(registration) }
                        }
                        .disabled(registration == nil || model.isBusy)
                    }
                } else {
                    Button("Create") {
                        if let registration { confirm(registration) }
                    }
                    .disabled(registration == nil || owners == nil || model.isBusy)
                }
            } footer: {
                if onGithub, openedGithub {
                    Text("If you changed the name or owner on GitHub, update them here. Grant the App access to the new repository before connecting.")
                }
            }

            if let error = model.error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .onAppear { nameFocused = true }
        .task(id: loadAttempt) { await loadOwners() }
    }

    private func loadOwners() async {
        owners = nil
        ownersError = nil
        do {
            let result = try await OS1API.githubOwners()
            owners = result.owners ?? []
            if result.appConfigured == true, result.owners == nil {
                ownersError = "Couldn’t load GitHub owners. Retry or choose this server only."
            }
        } catch {
            owners = []
            ownersError = "Couldn’t load GitHub owners. Retry or choose this server only."
        }
    }
}

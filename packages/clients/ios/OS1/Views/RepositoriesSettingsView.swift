import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// Settings → Repositories: which repos this instance works in, and what each
/// one's tile looks like.
///
/// A repo shows a colored letter unless someone gives it art of its own. The
/// color is assigned across the registered set so no two repos match — this is
/// where that gets overridden by hand, and where a repo can be handed its
/// owner's GitHub avatar or a picture from the library. Mirrors the web's
/// Settings → Repositories (src/frontend/components/SetupRepos.tsx); both
/// drive the same endpoints, so a tile changed on the phone is the tile the
/// sidebar paints.
///
/// Adding one lives here too: clone a remote, register a checkout already on
/// the server, or start a new repository (see `AddRepositoryView`, which the
/// sidebar's workspace options open as well).
struct RepositoriesSettingsView: View {
    @State private var repos: [OS1API.RepoInfo] = SettingsCache.value("repos") ?? []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
            if repos.isEmpty {
                Section {
                    if loading {
                        ProgressView("Loading repositories…")
                    } else {
                        Text("No repositories registered.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    ForEach(repos, id: \.id) { repo in
                        NavigationLink {
                            RepoTileEditorView(repo: repo, onChanged: load)
                        } label: {
                            HStack(spacing: 11) {
                                RepoTile(name: repo.id, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(RepoTile.label(for: repo.id))
                                    if let ghRepo = repo.ghRepo, !ghRepo.isEmpty {
                                        Text(ghRepo)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                } footer: {
                    Text(
                        "A repo without an icon of its own wears a colored letter. Colors are assigned so no two repos match; pick one to override that."
                    )
                }
            }

            Section {
                // The same three sources as the sidebar's workspace options →
                // Add project, through the same flow.
                ForEach(AddRepositorySource.allCases) { source in
                    NavigationLink {
                        AddRepositoryView(
                            source: source,
                            onAdded: load,
                            closesAfterAdding: false
                        )
                    } label: {
                        Label(source.title, systemImage: source.systemImage)
                    }
                }
            } header: {
                Text("Add repository")
            } footer: {
                // Worth saying before the tap, not after: this is the one
                // action on the phone that changes what the whole instance
                // can work in, and no client can take it back.
                Text(
                    "Sessions branch into worktrees of a registered repo on the server. Nothing here removes one again."
                )
            }
        }
        .insetGroupedListCompat()
        .navigationTitle("Repositories")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            repos = try await OS1API.repos()
            SettingsCache.save("repos", repos)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One repo's tile.
///
/// One grid, because there is one question: what does this repo look like?
/// Every cell is the tile you'd get — the palette colors carrying the repo's
/// letter, the owner's GitHub avatar, and a picture of your own — and picking
/// a color is also how you take art back off. Automatic gets its own row
/// rather than a cell: it isn't a color among the ten, it's "keep this repo on
/// one no other repo has", so it says that and shows which color it currently
/// means.
private struct RepoTileEditorView: View {
    let repo: OS1API.RepoInfo
    let onChanged: () async -> Void

    @State private var color: String?
    @State private var colorChosen: Bool
    @State private var hasIcon: Bool
    @State private var iconSource: String?
    @State private var busy = false
    @State private var error: String?
    #if os(iOS)
    @State private var pickerItem: PhotosPickerItem?
    #else
    @State private var importing = false
    #endif

    init(repo: OS1API.RepoInfo, onChanged: @escaping () async -> Void) {
        self.repo = repo
        self.onChanged = onChanged
        _color = State(initialValue: repo.color)
        _colorChosen = State(initialValue: repo.colorChosen ?? false)
        _hasIcon = State(initialValue: repo.hasIcon ?? false)
        _iconSource = State(initialValue: repo.iconSource)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)

    /// On automatic when nothing was chosen for it and it wears no art.
    private var autoActive: Bool { !hasIcon && !colorChosen }

    private var owner: String {
        String((repo.ghRepo ?? "").split(separator: "/").first ?? "")
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    RepoTile(name: repo.id, size: 64, round: false)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            Section {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Array(RepoTilePalette.colors.enumerated()), id: \.offset) { index, rgb in
                        let hex = String(format: "#%06x", rgb)
                        TileChoice(
                            active: !autoActive && !hasIcon && color?.lowercased() == hex,
                            busy: busy,
                            // Picking a color takes art off too — otherwise the
                            // choice would be invisible on a repo wearing an icon.
                            action: { await apply(color: .some(hex), icon: .some(nil)) }
                        ) {
                            LetterTile(name: repo.id, rgb: rgb)
                        }
                        .accessibilityLabel(
                            "Letter icon, color \(index + 1) of \(RepoTilePalette.colors.count)"
                        )
                    }

                    // The avatar is offered only once the picture is really
                    // there: the route 404s for a repo with no GitHub remote,
                    // and GitHub can be unreachable. Loading it IS the probe.
                    if let url = avatarURL, let avatar = cachedAvatar(url) {
                        TileChoice(
                            active: iconSource == "github",
                            busy: busy,
                            action: { await apply(icon: .some("github")) }
                        ) {
                            avatar.resizable().scaledToFill()
                        }
                        .accessibilityLabel("\(owner)'s GitHub avatar")
                    }

                    uploadChoice
                }
                .padding(.vertical, 4)
                // Faded while automatic is on: these choices aren't in
                // effect. Still live, though — picking one is how you leave
                // automatic, so the fade never becomes a mode to escape first.
                .opacity(autoActive ? 0.4 : 1)
                .animation(.easeOut(duration: 0.15), value: autoActive)
            } header: {
                Text("Icon")
            }

            Section {
                // A mode, not an eleventh choice — so a switch. Off pins
                // whatever automatic was giving, so leaving it never lands the
                // repo on something it wasn't already wearing.
                Toggle(isOn: automaticBinding) {
                    HStack(spacing: 11) {
                        LetterTile(
                            name: repo.id,
                            rgb: RepoTilePalette.parse(repo.autoColor ?? color ?? "")
                                ?? RepoTilePalette.shared.rgb(for: repo.id)
                        )
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text("Automatic")
                    }
                }
                .disabled(busy)
            } footer: {
                // Worth saying out loud: this is why the avatar isn't
                // automatic. GitHub has no per-repo art, so taking the owner's
                // for every repo put one identical tile on all of them.
                Text(
                    avatarShown
                        ? "Automatic keeps this repo on a color no other repo has. The avatar is \(owner)'s — the same picture for every repo that owner has."
                        : "Automatic keeps this repo on a color no other repo has."
                )
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .insetGroupedListCompat()
        .navigationTitle(RepoTile.label(for: repo.id))
        .inlineTitleBarCompat()
        .task {
            // Kicks the load; the cell appears when the bytes land.
            if !(repo.ghRepo ?? "").isEmpty, let url = avatarURL {
                RepoImageCache.shared.ensureLoaded(url)
            }
        }
    }

    // MARK: - Upload

    @ViewBuilder
    private var uploadChoice: some View {
        #if os(iOS)
        PhotosPicker(selection: $pickerItem, matching: .images) {
            uploadCell
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onChange(of: pickerItem) {
            guard let item = pickerItem else { return }
            pickerItem = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                await upload(data)
            }
        }
        #else
        Button { importing = true } label: { uploadCell }
            .buttonStyle(.plain)
            .disabled(busy)
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [.image]
            ) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return }
                Task { await upload(data) }
            }
        #endif
    }

    private var uploadCell: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(
                OS1VisualStyle.border,
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .overlay {
                if iconSource == "upload" {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(OS1VisualStyle.text, lineWidth: 2)
                        .padding(-3)
                }
            }
            .accessibilityLabel("Upload an image")
    }

    /// Re-encode whatever was picked as the square PNG the tile wants — the
    /// same job the web editor's canvas does, and for the same reason: the
    /// server's icon path decodes PNG and nothing else.
    private func upload(_ raw: Data) async {
        guard let png = SettingsIconImage.squarePNG(raw) else {
            error = "That image couldn’t be read."
            return
        }
        await run { try await OS1API.uploadRepoIcon(id: repo.id, png: png) }
    }

    // MARK: - Avatar

    @MainActor
    private var avatarURL: URL? { OS1API.repoGitHubAvatarURL(id: repo.id) }

    private func cachedAvatar(_ url: URL) -> Image? {
        RepoImageCache.shared.images[url.absoluteString]
    }

    private var avatarShown: Bool {
        guard let url = avatarURL else { return false }
        return cachedAvatar(url) != nil
    }

    // MARK: - Applying

    /// On writes through to the server, so the switch reflects what is stored
    /// rather than a local guess.
    private var automaticBinding: Binding<Bool> {
        Binding(
            get: { autoActive },
            set: { on in
                Task {
                    if on {
                        await apply(color: .some(nil), icon: .some(nil))
                    } else {
                        await apply(color: .some(repo.autoColor ?? color))
                    }
                }
            }
        )
    }

    private func apply(color: String?? = nil, icon: String?? = nil) async {
        await run { try await OS1API.setRepoAppearance(id: repo.id, color: color, icon: icon) }
    }

    private func run(_ work: () async throws -> OS1API.RepoAppearance) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await work()
            color = result.color ?? color
            colorChosen = result.color != nil
            hasIcon = result.hasIcon
            iconSource = result.iconSource
            error = nil
            // Refresh the list behind this screen: the palette store learns the
            // new color and icon revision there, which is what repaints every
            // other tile in the app.
            await onChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One cell of the tile grid: a preview of what picking it would give.
private struct TileChoice<Content: View>: View {
    let active: Bool
    let busy: Bool
    let action: () async -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            content
                // Square, like every tile this previews — a wide cell
                // centre-crops art (the GitHub avatar lost its sides).
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    if active {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(OS1VisualStyle.text, lineWidth: 2)
                            .padding(-3)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

/// The letter icon in a given color, with the same slight gradient the real
/// one wears. Not `RepoTile`: that paints the art when a repo has any, and
/// these cells are previews of not having it.
private struct LetterTile: View {
    let name: String
    let rgb: UInt32

    private var letter: String {
        name == "backstage" ? "O" : String(name.prefix(1)).uppercased()
    }

    var body: some View {
        Rectangle()
            .fill(RepoTilePalette.fill(rgb))
            .overlay {
                Text(letter)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(RepoTilePalette.ink)
            }
    }
}

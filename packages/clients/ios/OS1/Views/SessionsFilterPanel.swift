import SwiftUI

/// The sessions list's view controls in one panel: how the list is grouped,
/// which project and person it is scoped to, what it hides, and, in Status,
/// how it is sorted. The web's filter popover, minus the two controls with no native
/// surface behind them (session-less pull request rows, and the desktop
/// sidebar's row density).
///
/// A panel rather than a menu. Seven controls is where a `Menu` stops working:
/// every toggle inside one dismisses the whole stack, so turning two things
/// off means opening it twice and walking two levels down each time. This
/// stays open across every adjustment, which is what the web popover does.
/// A sheet on the phone, a popover on the Mac.
struct SessionsFilterPanel: View {
    @Binding var groupBy: String
    @Binding var groupByProject: Bool
    @Binding var repo: String
    @Binding var person: String
    @Binding var sort: String
    @Binding var showAutoCreated: Bool
    @Binding var hideEmptyProjects: Bool
    /// Projects with a band in the list right now, in its own order.
    let repos: [String]
    let currentUser: String
    /// Add project → one source. The panel closes and the list opens that
    /// source's flow, as the web's workspace options do. Nil hides the row.
    var onAddProject: ((AddRepositorySource) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    /// The agent's own name, which is also the key its work files under.
    private var agentName: String { InstanceIdentity.shared.personaName }

    /// Teammates, minus whoever is signed in: "you" is the first row and must
    /// not appear twice under two spellings of the same name.
    private var teammates: [String] {
        TeamDirectory.shared.names.filter {
            !SidebarPersonLens.nameMatches($0, key: currentUser)
        }
    }

    var body: some View {
        panel
            .task { await TeamDirectory.shared.ensureLoaded() }
    }

    @ViewBuilder
    private var panel: some View {
        #if os(iOS)
        NavigationStack {
            form
                .navigationTitle("Filter")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        // Full height, not a half sheet. There are six controls and the half
        // sheet cut the last one off, which is the auto-created switch: the
        // setting most likely to be why the list looks short is the one you
        // would have had to drag the sheet to find.
        .presentationDetents([.large])
        #else
        form
            .formStyle(.grouped)
            .frame(width: 330, height: 500)
        #endif
    }

    private var form: some View {
        Form {
            // No footers on these two. Three explanations in a row pushed
            // Advanced off the sheet's first detent, and neither control
            // needs one: the groupings name themselves, and the switch below
            // says what turning it on does.
            Section {
                Picker("Group by", selection: $groupBy) {
                    ForEach(SidebarGroupBy.allCases, id: \.rawValue) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
            }

            Section {
                Picker("Project", selection: $repo) {
                    Text("All projects").tag("all")
                    ForEach(repos, id: \.self) { name in
                        Label {
                            Text(RepoTile.label(for: name))
                        } icon: {
                            RepoTile(name: name, size: 16)
                        }
                        .tag(name)
                    }
                }
                // The one setting about the SET of projects rather than about
                // which one you are in, so it sits under the list of them.
                Toggle("Group by project", isOn: $groupByProject)
                Toggle("Hide when empty", isOn: $hideEmptyProjects)
            }

            Section {
                Picker("Person", selection: $person) {
                    personOptions
                }
            }

            Section {
                // Inbox keeps stable creation order. Status is the
                // one layout where choosing the order inside lanes still helps.
                if groupBy == SidebarGroupBy.status.rawValue {
                    Picker("Sort by", selection: $sort) {
                        ForEach(SidebarSortBy.allCases, id: \.rawValue) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                }
                Toggle("Show auto created", isOn: $showAutoCreated)
            } header: {
                Text("Advanced")
            } footer: {
                // The one explanation worth its space: "auto created" and
                // "automation" are different things, and the row above cannot
                // say which one it means on its own.
                Text("Workspaces an agent opened for itself, not automations you set up.")
            }
            // No Archived row here. The list ends on one, on both clients, and
            // a second door to the same screen is one more thing to read.

            // Bringing a project in is the one action here rather than a view
            // setting, so it sits last, in a section of its own.
            if let onAddProject {
                Section {
                    Menu {
                        ForEach(AddRepositorySource.allCases) { source in
                            Button {
                                onAddProject(source)
                            } label: {
                                Label(source.menuLabel, systemImage: source.systemImage)
                            }
                        }
                    } label: {
                        Label("Add project", systemImage: "folder.badge.plus")
                    }
                    .accessibilityHint("Clone a repository, register a folder on the server, or start a new one")
                }
            }
        }
    }

    /// You first, then teammates and the agent, then the aggregate backlog,
    /// then everyone. The agent is one of the people in this list: it owns
    /// every workspace and automation nobody has taken.
    @ViewBuilder
    private var personOptions: some View {
        Text(currentUser.isEmpty ? "You" : "\(currentUser) (you)")
            .tag(SidebarPersonLens.me)
        ForEach(teammates, id: \.self) { name in
            Text(name).tag(name.lowercased())
        }
        Text(agentName).tag(agentName.lowercased())
        Text("Unassigned").tag(SidebarPersonLens.unassigned)
        Text("Everyone").tag(SidebarPersonLens.everyone)
    }
}

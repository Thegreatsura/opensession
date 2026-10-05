import Foundation

/// Who a row belongs to under the list's "My sessions" lens.
///
/// Three things make a row yours:
///
/// - a session of yours in it (automation runs never count as anyone's — they
///   carry their creator, not a person), or
/// - a CLAIM. Claiming is the per-user triage that pulls an automation's run,
///   or work someone else started, into your own list, and the web sidebar has
///   honored it since lanes went per-user (`focusWsRows` in
///   src/frontend/components/Sidebar.tsx). See `LaneStore`, or
/// - an outstanding @-mention on one of its sessions. A teammate explicitly
///   asking for you admits their row to the default "My sessions" lens, or
/// - a COLLABORATOR entry on its workspace. Adding a teammate files the
///   workspace into their sidebar exactly as it is filed for its creator
///   (`rowHasCollaborator` in src/frontend/lib/sidebar-derived.ts), and the
///   same entry makes it theirs under a teammate lens too.
///
/// The app used to test only the first, which is how a workspace claimed in
/// the browser could be missing from the phone entirely: nothing in it was
/// started by you, it was opened by the machine identity, and the claim that
/// made it yours was invisible here.
///
/// The web's rule has a third clause this deliberately limits to a parked
/// draft: a workspace whose `createdBy` is you. Applying it to every regular
/// workspace more than tripled one person's sidebar (31 rows to 96), while a
/// sessionless draft has no other owner signal at all.
///
/// One rule for every surface that asks the question — the live list, its
/// archived slice, and the Archived sheet — because three spellings of "mine"
/// is how they drift apart.
struct PeopleLens {
    /// Identity strings that count as you: display name, its first token
    /// (sessions store first names, e.g. "Jaap"), and the GitHub login.
    let names: Set<String>
    /// First-name key to the roster's canonical display name.
    var roster: [String: String] = [:]
    /// Session ids you have claimed (`LaneStore`).
    let claims: Set<String>
    /// Session ids where a teammate tagged you (`MentionStore`).
    var mentions: Set<String> = []
    /// Workspace id to the names of the teammates added to it.
    var collaborators: [String: [String]] = [:]

    /// The collaborator lists of the workspaces that have any, keyed by id.
    static func collaboratorIndex(
        _ workspaces: [OS1API.WorkspaceSummary]
    ) -> [String: [String]] {
        var index: [String: [String]] = [:]
        for workspace in workspaces {
            let names = (workspace.collaborators ?? []).map(\.name).filter { !$0.isEmpty }
            if !names.isEmpty { index[workspace.id] = names }
        }
        return index
    }

    @MainActor
    static func current() -> PeopleLens {
        var names: Set<String> = []
        let config = ServerConfig.shared
        let user = config.userName.trimmingCharacters(in: .whitespaces)
        if !user.isEmpty {
            names.insert(user.lowercased())
            if let first = user.split(separator: " ").first {
                names.insert(first.lowercased())
            }
        }
        let login = config.githubLogin
        if !login.isEmpty { names.insert(login.lowercased()) }
        return PeopleLens(
            names: names,
            roster: TeamDirectory.shared.displayNames,
            claims: LaneStore.shared.claims,
            mentions: MentionStore.shared.sessionIds,
            collaborators: WorkspaceCollaboratorsStore.shared.index
        )
    }

    /// Whether `name` (any spelling the roster knows) is you.
    func isViewer(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if names.contains(normalized) { return true }
        guard let canonical = ArchivedOwners.canonical(name, in: roster)?.lowercased() else {
            return false
        }
        return names.contains(canonical)
    }

    /// The teammates added to the workspace this row stands for.
    ///
    /// The index wins: it is replaced on every workspaces refresh and on each
    /// add or remove, while a row's own summary is as old as its grouping.
    func collaborators(of workspace: SidebarWorkspace) -> [String] {
        if let id = workspace.workspaceId, let listed = collaborators[id] { return listed }
        return (workspace.workspace?.collaborators ?? []).map(\.name)
    }

    /// You were added to this row's workspace.
    func collaborates(on workspace: SidebarWorkspace) -> Bool {
        collaborators(of: workspace).contains(where: isViewer)
    }

    /// Whether the row is your own work rather than work waiting on your
    /// review: you own it, collaborate on it, or one of its ordinary sessions
    /// is yours. A pull request opened from such a workspace asks its author's
    /// team to review it, and GitHub then asks the author too, so the review
    /// mark must not pull your own work out of your lanes (`rowIsOwnWork` in
    /// src/frontend/lib/review-queue.ts). Claims and mentions do not count:
    /// they bring someone else's work to you.
    func isOwnWork(_ workspace: SidebarWorkspace) -> Bool {
        if let owner = workspace.workspace?.createdBy, isViewer(owner) { return true }
        if collaborates(on: workspace) { return true }
        return workspace.sessions.contains { session in
            !session.isAutomation && session.startedBy.map(isViewer) == true
        }
    }

    /// A single session under the lens: yours to start with, or claimed.
    func isMine(_ session: Session) -> Bool {
        if claims.contains(session.id) { return true }
        guard !session.isAutomation, let startedBy = session.startedBy else {
            return false
        }
        return isViewer(startedBy)
    }

    /// A sidebar row under the lens. A row is yours as soon as ONE of its
    /// sessions is — a workspace is shared work, not a possession.
    func owns(_ workspace: SidebarWorkspace) -> Bool {
        if workspace.isDraftWorkspace,
           let owner = workspace.workspace?.createdBy?.lowercased() {
            return names.contains(owner) || collaborates(on: workspace)
        }
        if collaborates(on: workspace) { return true }
        return workspace.sessions.contains { isMine($0) || mentions.contains($0.id) }
    }
}

// ── The whole person lens ───────────────────────────────────────────────────
// The list used to ask one question, "is this mine", because it offered one
// answer besides everyone's. It now offers the web's lens: you, a teammate,
// the agent, the unassigned backlog, or everyone. `owns` above stays the rule
// for "me", and is the only branch that counts claims and @-mentions.

extension PeopleLens {
    /// A row under any lens value.
    ///
    /// The web asks this of a row's resolved `owner` field, which the wire
    /// does not carry here, so the native rule reads the evidence the row
    /// itself holds: who started its sessions, and who parked its draft.
    ///
    /// Claims and mentions count under "me" only. A teammate tagging you
    /// admits their row to YOUR list, not to theirs, and a row that mentions
    /// three people would otherwise turn up under all three.
    func matches(
        _ workspace: SidebarWorkspace,
        person: String,
        agentKey: String
    ) -> Bool {
        switch person {
        case SidebarPersonLens.everyone:
            return true
        case SidebarPersonLens.me:
            return owns(workspace)
        case SidebarPersonLens.unassigned:
            // Work nobody has picked up: no person's name on it, and nothing
            // running. The web reads its `pending` status for the same thing.
            return workspace.lane == .backlog && owners(of: workspace).isEmpty
        default:
            if SidebarPersonLens.nameMatches(agentKey, key: person) {
                return Self.isAgentWork(workspace)
            }
            return owners(of: workspace).contains {
                SidebarPersonLens.nameMatches($0, key: person)
            }
        }
    }

    /// One session under any lens value, for the surfaces that hold sessions
    /// rather than rows (the Archived sheet).
    func matches(_ session: Session, person: String, agentKey: String) -> Bool {
        switch person {
        case SidebarPersonLens.everyone:
            return true
        case SidebarPersonLens.me:
            return isMine(session)
        case SidebarPersonLens.unassigned:
            return !session.isAutomation && Self.personName(session) == nil
        default:
            if SidebarPersonLens.nameMatches(agentKey, key: person) {
                return session.isAutomation || AutoCreatedOrigin.wasAutoCreated(session)
            }
            guard let name = Self.personName(session) else { return false }
            return SidebarPersonLens.nameMatches(name, key: person)
        }
    }

    /// The machine's own work: an automation's runs, and the one-off
    /// workspaces an agent opened for itself. Both land under the agent
    /// because nobody has taken either.
    static func isAgentWork(_ workspace: SidebarWorkspace) -> Bool {
        if AutoCreatedOrigin.wasAutoCreated(workspace) { return true }
        return !workspace.sessions.isEmpty
            && workspace.sessions.allSatisfy { $0.isAutomation }
    }

    /// The people a row names as having started it: every ordinary session's
    /// sender, plus a parked draft's author. A draft has no other owner signal
    /// at all, which is why `owns` reads it too.
    ///
    /// The machine identity is not a person, so it never appears here. That is
    /// what keeps an agent's own workspace out of every teammate's lens and in
    /// the agent's.
    /// Everyone a row files under: the people who started it, and the
    /// teammates added to its workspace, who see it as their own work.
    func owners(of workspace: SidebarWorkspace) -> [String] {
        Self.owners(of: workspace) + collaborators(of: workspace).compactMap { Self.person($0) }
    }

    static func owners(of workspace: SidebarWorkspace) -> [String] {
        var names = workspace.sessions.compactMap(personName)
        if workspace.isDraftWorkspace,
           let author = workspace.workspace?.createdBy,
           let named = person(author) {
            names.append(named)
        }
        return names
    }

    /// The person who started this session, or nil when nobody did: an
    /// automation run carries its creator rather than an owner, and the
    /// machine identity is not a person.
    static func personName(_ session: Session) -> String? {
        guard !session.isAutomation else { return nil }
        return person(session.startedBy)
    }

    private static func person(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespaces),
              !trimmed.isEmpty,
              trimmed.lowercased() != AutoCreatedOrigin.machineIdentity
        else { return nil }
        return trimmed
    }
}

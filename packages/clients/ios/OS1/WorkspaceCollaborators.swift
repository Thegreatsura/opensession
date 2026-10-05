import Foundation
import Observation

/// Who has been added to which workspace, for the surfaces that ask about a
/// session rather than a sidebar row (the conversation's Add to sidebar
/// action, the person lens built outside the list).
///
/// The server owns the list (`POST/DELETE /api/workspaces/:id/collaborators`)
/// and this is only its latest answer: `/api/workspaces` replaces it on every
/// list refresh, and an add or remove installs the workspace the route
/// answers with. Nothing here decides who may be added; an unknown name comes
/// back as the server's error.
@Observable
@MainActor
final class WorkspaceCollaboratorsStore {
    static let shared = WorkspaceCollaboratorsStore()

    /// Workspace id to its collaborators' names.
    private(set) var index: [String: [String]] = [:]
    /// The workspace an add or remove is in flight for, so its menu can wait.
    private(set) var pendingWorkspaceId: String?
    private(set) var error: String?

    init() {}

    func replace(with workspaces: [OS1API.WorkspaceSummary]) {
        let next = PeopleLens.collaboratorIndex(workspaces)
        if next != index { index = next }
    }

    func install(_ workspace: OS1API.WorkspaceSummary) {
        let names = (workspace.collaborators ?? []).map(\.name).filter { !$0.isEmpty }
        if names.isEmpty {
            index.removeValue(forKey: workspace.id)
        } else {
            index[workspace.id] = names
        }
    }

    func names(for workspaceId: String?) -> [String] {
        guard let workspaceId, !workspaceId.isEmpty else { return [] }
        return index[workspaceId] ?? []
    }

    /// Add or remove `name`, returning the workspace as the server now has it.
    @discardableResult
    func toggle(
        _ name: String,
        workspaceId: String,
        sessionId: String?
    ) async -> OS1API.WorkspaceSummary? {
        let listed = WorkspaceCollaborators.contains(names(for: workspaceId), name)
        pendingWorkspaceId = workspaceId
        error = nil
        defer { pendingWorkspaceId = nil }
        do {
            let updated = listed
                ? try await OS1API.removeCollaborator(workspaceId: workspaceId, name: name)
                : try await OS1API.addCollaborator(
                    workspaceId: workspaceId,
                    name: name,
                    sessionId: sessionId
                )
            if let updated { install(updated) }
            return updated
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

/// The pure rules the collaborator menu and the lens share.
enum WorkspaceCollaborators {
    static func contains(_ names: [String], _ name: String) -> Bool {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return !key.isEmpty && names.contains {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == key
        }
    }

    /// The teammates a workspace's menu offers: the roster in its own order,
    /// minus the workspace's creator, whose sidebar already holds it (the
    /// web's `useWorkspaceCollaborators`). Someone listed who has since left
    /// the roster stays at the end so they can still be removed.
    static func choices(roster: [String], listed: [String], creator: String?) -> [String] {
        let creatorKey = creator?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var seen = Set<String>()
        return (roster + listed).filter { name in
            let key = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { return false }
            return key != creatorKey || contains(listed, name)
        }
    }
}

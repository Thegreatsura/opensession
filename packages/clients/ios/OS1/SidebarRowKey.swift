import Foundation

/// The key a sidebar ROW is stored under in the per-user overlays both clients
/// share — hides (`src/server/hides.ts`) and pins (`src/server/pins.ts`).
///
/// A row is keyed `workspace:<id>` when it's a real workspace, `wt:<dir>` for a
/// legacy isolated-worktree row, and by the bare session id for a solo session. Only
/// these forms may be persisted: the iOS-internal `worktree:` / `session:`
/// prefixes on `SidebarWorkspace.id` would be invisible to the web sidebar,
/// which writes the same files.
enum SidebarRowKeys {
    static func rowKey(for workspace: SidebarWorkspace) -> String {
        let id = workspace.id
        if let dir = id.dropPrefix("worktree:") { return "wt:\(dir)" }
        if let sessionId = id.dropPrefix("session:") { return sessionId }
        return id
    }

    /// The key a row's per-user colour and Active-order entry are stored
    /// under, as the web sidebar writes them.
    ///
    /// The Mac draws one row per session, so its row key is the session id,
    /// while the web and the phone draw the workspace. A colour or a place in
    /// the order is about the piece of work, so a Mac session row inside a
    /// workspace reads and writes the workspace's key; otherwise a row
    /// coloured in the browser would come up plain on the Mac.
    static func sharedRowKey(for workspace: SidebarWorkspace) -> String {
        if workspace.id.hasPrefix("session:"),
           let workspaceId = workspace.mainSession.workspaceId,
           !workspaceId.isEmpty {
            return "workspace:\(workspaceId)"
        }
        return rowKey(for: workspace)
    }

    /// The keys a row's hide can be stored under: its own, and the shared
    /// key the web writes for a Mac session row inside a workspace.
    static func hideKeys(for workspace: SidebarWorkspace) -> [String] {
        let own = rowKey(for: workspace)
        let shared = sharedRowKey(for: workspace)
        return own == shared ? [own] : [own, shared]
    }

    /// Every row key a session can sit under. Used to clear an overlay entry
    /// (over-clearing is safe — it only ever restores a row) and to spot the
    /// hidden rows a blocked session should resurface.
    static func candidateKeys(for session: Session) -> [String] {
        var keys = [session.id]
        if let workspaceId = session.workspaceId, !workspaceId.isEmpty {
            keys.append("workspace:\(workspaceId)")
        }
        if let dir = session.worktreeDir, !dir.isEmpty {
            keys.append("wt:\(dir)")
        }
        return keys
    }

    /// The server drops over-long keys (`clean` in hides.ts / pins.ts), which
    /// would look like a write that survives until the next hydrate.
    static func isPersistable(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 128
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

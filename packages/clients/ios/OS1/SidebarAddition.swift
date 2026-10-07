import Foundation

/// Decides whether an open session offers "Add to sidebar", with the same
/// membership rule as the row menu and the "me" lens
/// (`PeopleLens.membership`). The unit is the whole sidebar row: a row the
/// lens already files under you (your own or spawned work, a claim, a
/// mention, a collaborator entry) needs nothing; any other row is claimed in,
/// and a hidden row is restored without adding a redundant claim.
enum SidebarAddition {
    enum Intent: Equatable {
        case claim
        case restore
    }

    static func intent(
        for session: Session,
        siblings: [Session],
        lens: PeopleLens,
        hidden: Bool
    ) -> Intent? {
        guard session.archived != true else { return nil }
        switch lens.membership(of: row(for: session, siblings: siblings), hidden: hidden) {
        case .keep: return .claim
        case .restore: return .restore
        case .hide: return nil
        }
    }

    /// The sidebar row the session sits in, as the lens reads it.
    static func row(for session: Session, siblings: [Session]) -> SidebarWorkspace {
        let sessions = siblings.contains { $0.id == session.id }
            ? siblings
            : [session] + siblings
        return SidebarWorkspace(
            id: "session:\(session.id)",
            title: session.displayTitle,
            sessions: sessions,
            mainSession: session
        )
    }

    @MainActor
    static func currentIntent(for session: Session, siblings: [Session]) -> Intent? {
        let hidden = !Set(SidebarRowKeys.candidateKeys(for: session))
            .isDisjoint(with: HideStore.shared.hides.keys)
        return intent(
            for: session,
            siblings: siblings,
            lens: PeopleLens.current(),
            hidden: hidden
        )
    }

    @MainActor
    static func add(session: Session, siblings: [Session]) {
        guard let intent = currentIntent(for: session, siblings: siblings) else { return }
        HideStore.shared.unhide(for: session)
        if intent == .claim {
            LaneStore.shared.claim(row(for: session, siblings: siblings).sessions)
        }
    }
}

import SwiftUI

/// Organization switcher shared by the iPhone toolbar and Mac sidebar.
struct ServerAccountPicker: View {
    var iconSize: CGFloat = 32
    var compact = false
    let openSettings: () -> Void

    @State private var config = ServerConfig.shared
    @State private var presence = PresenceStore.shared

    var body: some View {
        pickerLabel
            .overlay {
                Menu {
                    accountActions
                } label: {
                    // Keep the artwork outside the Menu label. On iOS 26 the
                    // system snapshots that label as the menu's morph source;
                    // snapshotting a clipped image makes it briefly stretch
                    // and flatten when the menu closes.
                    Color.clear
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .accessibilityLabel("Organization, \(config.activeAccount.displayLabel)")
                .accessibilityValue(isConnected ? "Connected" : "Connecting")
                .accessibilityHint("Switch organization or open settings")
            }
    }

    @ViewBuilder
    private var accountActions: some View {
        Section("Organizations") {
            ForEach(config.accounts) { account in
                Button {
                    guard account.id != config.activeId else { return }
                    GitHubSignIn.shared.cancel()
                    config.activate(account.id)
                    PresenceStore.shared.start()
                    TailscaleHandoff.switchIfNeeded(to: config.activeAccount)
                } label: {
                    HStack {
                        Label(
                            account.displayLabel,
                            systemImage: account.id == config.activeId
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        if let count = config.accountBadges[account.id], count > 0 {
                            Text("\(count)")
                        }
                    }
                }
            }
        }

        Button {
            GitHubSignIn.shared.cancel()
            config.addAccount()
            openSettings()
        } label: {
            Label("Add organization", systemImage: "plus")
        }

        Button(action: openSettings) {
            Label("Settings", systemImage: "gearshape")
        }
    }

    private var pickerLabel: some View {
        HStack(spacing: compact ? 6 : 8) {
            OrganizationAppIcon(size: iconSize, fallbackScale: 0.88)
                .overlay(alignment: .topTrailing) {
                    if inactiveBadgeCount > 0 {
                        Circle()
                            .fill(.red)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(OS1VisualStyle.background, lineWidth: 1.5))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(isConnected ? OS1VisualStyle.green : OS1VisualStyle.textFaint)
                        .frame(width: 9, height: 9)
                        .overlay(
                            Circle().stroke(OS1VisualStyle.background, lineWidth: 1.5)
                        )
                }
            if !compact {
                Text(config.activeAccount.displayLabel)
                    .font(.headline)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }

    private var isConnected: Bool {
        presence.isConnected(accountID: config.activeId)
    }

    private var inactiveBadgeCount: Int {
        config.accountBadges.reduce(into: 0) { total, item in
            if item.key != config.activeId { total += item.value }
        }
    }
}

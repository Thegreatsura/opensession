import SwiftUI

struct OrganizationsSettingsView: View {
    @State private var config = ServerConfig.shared

    var body: some View {
        List {
            Section {
                ForEach(config.accounts) { account in
                    Button {
                        guard account.id != config.activeId else { return }
                        GitHubSignIn.shared.cancel()
                        config.activate(account.id)
                        PresenceStore.shared.start()
                        TailscaleHandoff.switchIfNeeded(to: config.activeAccount)
                    } label: {
                        HStack(spacing: 12) {
                            accountIcon(account)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayLabel)
                                    .foregroundStyle(.primary)
                                if !account.url.isEmpty {
                                    Text(account.url)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if let count = config.accountBadges[account.id], count > 0 {
                                Text("\(count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .frame(minHeight: 20)
                                    .background(.red, in: Capsule())
                            }
                            if account.id == config.activeId {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(OS1VisualStyle.accentInk)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            GitHubSignIn.shared.cancel()
                            config.removeAccount(account.id)
                            PresenceStore.shared.start()
                        }
                    }
                }
            } footer: {
                Text("Each organization keeps its own server address and secure token.")
            }

            Section {
                Button {
                    GitHubSignIn.shared.cancel()
                    config.addAccount()
                } label: {
                    Label("Add organization", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Organizations")
        .inlineTitleBarCompat()
    }

    @ViewBuilder
    private func accountIcon(_ account: ServerAccount) -> some View {
        if account.id == config.activeId {
            OrganizationAppIcon(size: 34)
        } else {
            Image(systemName: "building.2")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 9))
        }
    }
}

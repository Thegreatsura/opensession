import SwiftUI

/// What a suggested-task card can do outside the transcript: open the session
/// it created, or open New Session prefilled. Provided by the sessions list,
/// which owns navigation and the composer sheet. A transcript shown anywhere
/// else gets nil, and the card disables the control rather than pretending.
struct SuggestedTaskActions {
    var openSession: (@MainActor (String) async -> Void)?
    var edit: (@MainActor (SuggestedTask) -> Void)?
}

extension EnvironmentValues {
    @Entry var suggestedTaskActions = SuggestedTaskActions()
}

/// The turn's proposals, minus those already started from this device:
/// starting one closes its card. Its own view so only a turn that proposed
/// something observes the started list.
struct SuggestedTasksView: View {
    let proposals: [SuggestedTaskProposal]
    let sessionId: String

    var body: some View {
        let open = StartedSuggestedTasks.shared.open(proposals, sessionId: sessionId)
        if !open.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(open) { proposal in
                    SuggestedTaskCard(proposal: proposal, sessionId: sessionId)
                }
            }
            .padding(.top, 8)
        }
    }
}

/// A follow-up the agent proposed: work it judged worth doing but out of
/// scope. Nothing has run until the person acts. Start session creates a new
/// session from the instructions as written and opens it; the pencil opens
/// New Session prefilled with them, for anyone who wants to edit first. The
/// instructions fold under the card for reading before either. Mirrors the
/// web's `SuggestedTaskCard`.
struct SuggestedTaskCard: View {
    let proposal: SuggestedTaskProposal
    let sessionId: String

    @Environment(\.suggestedTaskActions) private var actions
    @State private var starting = false
    @State private var failure: String?
    @State private var showsInstructions = false

    private var task: SuggestedTask { proposal.task }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(OS1VisualStyle.textFaint)
                Text(task.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OS1VisualStyle.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !task.description.isEmpty {
                    Text(task.description)
                        .font(.subheadline)
                        .foregroundStyle(OS1VisualStyle.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            controls

            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(OS1VisualStyle.redInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            instructions
        }
        .padding(14)
        .background(OS1VisualStyle.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(OS1VisualStyle.border, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private var caption: String {
        var parts = ["Suggested task"]
        if let repo = task.repo { parts.append(repo) }
        if task.mode == "ask" { parts.append("read-only") }
        return parts.joined(separator: " · ")
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                Task { await start() }
            } label: {
                HStack(spacing: 6) {
                    if starting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(starting ? "Starting" : "Start session")
                }
                .font(.subheadline.weight(.medium))
                #if os(iOS)
                .frame(minHeight: 32)
                #endif
            }
            .buttonStyle(.borderedProminent)
            .disabled(actions.openSession == nil || starting)

            Button {
                actions.edit?(task)
            } label: {
                Image(systemName: "pencil")
                    .font(.subheadline.weight(.medium))
                    #if os(iOS)
                    .frame(minWidth: 20, minHeight: 32)
                    #endif
            }
            .buttonStyle(.bordered)
            .disabled(actions.edit == nil || starting)
            .accessibilityLabel("Edit before starting")
            .help("Edit before starting")
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.22, extraBounce: 0)) {
                    showsInstructions.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OS1VisualStyle.textFaint)
                        .rotationEffect(.degrees(showsInstructions ? 0 : -90))
                    Text("Instructions")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(OS1VisualStyle.textDim)
                }
                #if os(iOS)
                .frame(minHeight: 32)
                #endif
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(showsInstructions ? "Hide the instructions" : "Show the instructions")

            if showsInstructions {
                Text(task.instructions)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(OS1VisualStyle.codeWellText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(OS1VisualStyle.codeWell, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .transition(.opacity)
            }
        }
    }

    private func start() async {
        guard let open = actions.openSession, !starting else { return }
        starting = true
        failure = nil
        do {
            let id = try await SuggestedTaskStart.run(proposal, sessionId: sessionId)
            Haptics.play(.send)
            // The card is retired by now; this view goes away with it.
            await open(id)
        } catch {
            failure = error.localizedDescription
            starting = false
        }
    }
}

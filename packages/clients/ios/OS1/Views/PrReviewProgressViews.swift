import SwiftUI

// The review-progress pieces both diff surfaces share: the PR review canvas
// and the worktree Changes view. A file's state reads the same way in both.

/// The tick in front of a file: empty, reviewed, or reviewed and then
/// changed. The changed state is its own amber mark rather than an empty
/// circle, so a reviewer can tell "never read" from "read an older version".
struct PrReviewStateButton: View {
    let state: PrFileReviewState
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var symbol: String {
        switch state {
        case .reviewed: "checkmark.circle.fill"
        case .changed: "exclamationmark.arrow.circlepath"
        case .unreviewed: "circle"
        }
    }

    private var tint: Color {
        switch state {
        case .reviewed: OS1VisualStyle.green
        case .changed: OS1VisualStyle.yellowInk
        case .unreviewed: OS1VisualStyle.textDim
        }
    }

    private var label: String {
        switch state {
        case .reviewed: "Mark not reviewed"
        case .changed: "Changed since review. Mark reviewed again"
        case .unreviewed: "Mark reviewed"
        }
    }
}

/// The words on a file that changed after it was reviewed.
struct PrChangedSinceReviewBadge: View {
    var body: some View {
        Label("Changed since review", systemImage: "exclamationmark.arrow.circlepath")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(OS1VisualStyle.yellowInk)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(OS1VisualStyle.yellow.opacity(0.16), in: Capsule())
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
    }
}

/// A callout across the top of a review: an outdated guide, a guide being
/// written, files changed since review.
struct PrReviewCallout<Actions: View>: View {
    enum Tone { case warning, info }

    let tone: Tone
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(ink)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tone == .warning ? ink : OS1VisualStyle.text)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(OS1VisualStyle.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                actions()
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tone == .warning ? OS1VisualStyle.yellow.opacity(0.55) : OS1VisualStyle.border)
        }
        .accessibilityElement(children: .combine)
    }

    private var ink: Color { tone == .warning ? OS1VisualStyle.yellowInk : OS1VisualStyle.blueInk }
    private var fill: Color { tone == .warning ? OS1VisualStyle.yellow.opacity(0.12) : OS1VisualStyle.raised }
}

extension PrReviewCallout where Actions == EmptyView {
    init(tone: Tone, symbol: String, title: String, message: String) {
        self.init(tone: tone, symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// "3/12 reviewed", a bar, how many changed since review, and the actions
/// over the whole review: next unreviewed, and mark all, reset or invert.
struct PrReviewProgressHeader: View {
    let total: Int
    let reviewed: Int
    let changed: Int
    var nextUnreviewed: (() -> Void)?
    var bulk: ((PrReviewBulkAction) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(reviewed)/\(total) reviewed")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(reviewed == total && total > 0 ? OS1VisualStyle.greenInk : OS1VisualStyle.text)
                if changed > 0 {
                    Label("\(changed) changed", systemImage: "exclamationmark.arrow.circlepath")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(OS1VisualStyle.yellowInk)
                }
                Spacer(minLength: 8)
                if let nextUnreviewed {
                    Button("Next unreviewed", action: nextUnreviewed)
                        .font(.caption.weight(.medium))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(reviewed == total)
                }
                if let bulk {
                    Menu {
                        ForEach(PrReviewBulkAction.allCases) { action in
                            Button { bulk(action) } label: {
                                Label(action.label, systemImage: action.symbol)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.body)
                            .foregroundStyle(OS1VisualStyle.textDim)
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Review progress")
                }
            }
            ProgressView(value: Double(reviewed), total: Double(max(total, 1)))
                .tint(OS1VisualStyle.green)
        }
    }
}

/// Files an earlier load of this review had that later commits removed.
struct PrRemovedFilesSection: View {
    let paths: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No longer in this diff", systemImage: "minus.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(OS1VisualStyle.textDim)
            ForEach(paths, id: \.self) { path in
                Text(path)
                    .font(.caption.monospaced())
                    .strikethrough()
                    .foregroundStyle(OS1VisualStyle.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("\(path), removed by later commits")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(OS1VisualStyle.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// One guide step's chip in the step strip: its number, title and progress.
struct PrGuideStepChip: View {
    let index: Int
    let group: PrReviewGroupProgress
    let isCurrent: Bool
    let showsProgress: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(OS1VisualStyle.textDim)
                Text(group.title)
                    .font(.caption.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(OS1VisualStyle.text)
                    .lineLimit(1)
                if showsProgress {
                    Text("\(group.reviewed)/\(group.files.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(group.isDone ? OS1VisualStyle.greenInk : OS1VisualStyle.textDim)
                }
                if group.changed > 0 {
                    Circle().fill(OS1VisualStyle.yellow).frame(width: 6, height: 6)
                        .accessibilityLabel("\(group.changed) changed since review")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 240)
            .background(
                isCurrent ? OS1VisualStyle.accent.opacity(0.16) : OS1VisualStyle.raised,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// A group's heading: its position, title, explanation, progress, and the
/// one-tap mark for the whole group.
struct PrReviewGroupHeader: View {
    let index: Int
    let count: Int
    let group: PrReviewGroupProgress
    var setReviewed: ((Bool) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(format: "%02d / %02d", index + 1, count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(OS1VisualStyle.textDim)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.title)
                    .font(.headline)
                    .foregroundStyle(OS1VisualStyle.text)
                if let explanation = group.explanation, !explanation.isEmpty {
                    Text(explanation)
                        .font(.subheadline)
                        .foregroundStyle(OS1VisualStyle.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let setReviewed {
                Text("\(group.reviewed)/\(group.files.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(group.isDone ? OS1VisualStyle.greenInk : OS1VisualStyle.textDim)
                    .padding(.top, 2)
                Button { setReviewed(!group.isDone) } label: {
                    Image(systemName: group.isDone ? "checkmark.circle.fill" : "checkmark.circle")
                        .foregroundStyle(group.isDone ? OS1VisualStyle.green : OS1VisualStyle.textDim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(group.isDone
                    ? "Mark \(group.title) as not reviewed"
                    : "Mark \(group.title) as reviewed")
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Resolved review threads on one file, under its header.
struct PrResolvedThreadsList: View {
    let threads: [PrReviewThread]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(threads) { thread in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Label("Resolved", systemImage: "checkmark.bubble")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(OS1VisualStyle.greenInk)
                        if let line = thread.line {
                            Text("Line \(line)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(OS1VisualStyle.textDim)
                        }
                        if let author = thread.rootAuthor, !author.isEmpty {
                            Text("@\(author)")
                                .font(.caption2)
                                .foregroundStyle(OS1VisualStyle.textDim)
                        }
                        if thread.isOutdated == true {
                            Text("Outdated")
                                .font(.caption2)
                                .foregroundStyle(OS1VisualStyle.textFaint)
                        }
                    }
                    if let body = thread.comments?.first?.body, !body.isEmpty {
                        Text(body)
                            .font(.caption)
                            .foregroundStyle(OS1VisualStyle.textDim)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(OS1VisualStyle.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

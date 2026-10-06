import SwiftUI

#if os(iOS)

/// The phone composer while dictating: three floating pills in place of the
/// box. Stop keeps the text in the draft to read and edit, the middle pill
/// shows elapsed time and a live level meter, and send stops and sends.
///
/// Send stays solid: with nothing dictated yet it just stops.
///
/// Its own view so the level ticks re-evaluate only this, never the bar.
struct ComposerDictationPills: View {
    let dictation: Dictation
    let onSend: () -> Void

    private static let meterBars = 10
    private static let height: CGFloat = 48

    var body: some View {
        // Fixed shares (1 : 1.4 : 1) rather than flexible frames, which let
        // the timer pill's content claim nearly the whole row.
        GeometryReader { proxy in
            let spacing: CGFloat = 10
            let unit = (proxy.size.width - spacing * 2) / 3.4
            row(side: unit, middle: unit * 1.4, spacing: spacing)
        }
        .frame(height: Self.height)
        .padding(.horizontal, 8)
    }

    private func row(side: CGFloat, middle: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Button {
                Haptics.play(.released)
                dictation.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(OS1VisualStyle.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(pillSurface)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .frame(width: side)
            .accessibilityLabel("Stop dictating")

            HStack(spacing: 12) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsed(at: context.date))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(OS1VisualStyle.text)
                }
                meter
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .frame(width: middle)
            .frame(maxHeight: .infinity)
            .background(pillSurface)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording")

            Button {
                dictation.stop()
                onSend()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(OS1VisualStyle.onAccent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(OS1VisualStyle.accent, in: Capsule())
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .frame(width: side)
            .accessibilityLabel("Stop and send")
        }
    }

    private var meter: some View {
        let levels = dictation.levels
        return HStack(spacing: 3) {
            ForEach(0..<Self.meterBars, id: \.self) { i in
                let index = levels.count - Self.meterBars + i
                let level = index >= 0 ? CGFloat(levels[index]) : 0
                Capsule()
                    .fill(OS1VisualStyle.textDim)
                    .frame(width: 3, height: 8 + level * 12)
            }
        }
        .frame(height: 20)
        .animation(.linear(duration: 0.09), value: levels)
    }

    private var pillSurface: some View {
        Capsule()
            .fill(OS1VisualStyle.background)
            .overlay { Capsule().strokeBorder(OS1VisualStyle.composerBorder, lineWidth: 1) }
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }

    private func elapsed(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(dictation.startedAt ?? date)))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}
#endif

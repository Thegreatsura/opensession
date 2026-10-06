import AVKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The agent's demo of a user-visible change, inline in the transcript where
/// it was published: a short screen recording, the writeup, and before/after
/// stills. The web viewer renders the same card in the session — until now the
/// walkthroughs an agent published from the phone were only visible from a
/// browser, which is a strange thing for the app the work was done in.
///
/// It reads as a raised card rather than a message, because it summarizes a
/// stretch of the conversation rather than continuing it.
///
/// It folds, like a work turn does, and arrives folded. A walkthrough is a
/// screenful of video and a screenful per before/after pair, and on a phone
/// that is a long way to drag past to reach what was said after it — in a
/// session that published several, the conversation is mostly walkthrough.
///
/// Folded is not hidden: the card keeps a sideways strip of its stills, and a
/// tap on one opens the same full-screen viewer the open card does. Checking
/// what changed should not require unfolding the whole walkthrough.
struct WalkthroughCard: View {
    let walkthrough: SessionWalkthrough
    let state: TurnFoldState

    /// The card's own inset — and the amount its pictures give back. Text is
    /// read at the card's margin; the media runs to its edges, because on a
    /// phone the walkthrough is already the narrowest thing on the narrowest
    /// screen (the transcript's margin, then the card's, then a letterbox) and
    /// every inset comes off the one screenshot the reader opened it for.
    fileprivate static let padding: CGFloat = 14

    /// How tall one piece of media may get before it stops being part of a
    /// conversation and becomes a page of its own. Shared by the video and the
    /// stills so a before/after pair and the demo of the same screen come out
    /// the same size.
    fileprivate static let mediaHeightCap: CGFloat = 640

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy(duration: 0.22, extraBounce: 0)) {
                    state.toggle()
                }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(state.expanded ? "Hide the walkthrough" : "Show the demo and writeup")

            if state.expanded {
                if let video = walkthrough.video, let url = OS1API.mediaURL(path: video) {
                    WalkthroughVideo(url: url)
                        .padding(.horizontal, -Self.padding)
                }
                if !walkthrough.summary.isEmpty {
                    MarkdownBody(walkthrough.summary)
                }
                ForEach(walkthrough.stills) { shot in
                    WalkthroughShotView(shot: shot, gallery: gallery)
                }
            } else if !gallery.isEmpty {
                WalkthroughThumbnailStrip(stills: walkthrough.stills, gallery: gallery)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Self.padding)
        .background(OS1VisualStyle.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(OS1VisualStyle.border, lineWidth: 0.5)
        }
        // Media needs more room after it than ordinary transcript text. A
        // writeup-only walkthrough still folds to the normal one-line rhythm.
        .padding(.bottom, state.expanded || !gallery.isEmpty ? 6 : 0)
    }

    /// Every still in the card, in reading order, so opening one pages
    /// before → after → the next pair. Comparing the two is the whole point of
    /// a walkthrough, and a viewer that shows one picture makes you close it to
    /// see the other.
    private var gallery: [PreviewImage] {
        walkthrough.stills.flatMap { shot in
            [
                (PreviewImage.WalkthroughLabel.before, shot.before),
                (.after, shot.after),
            ].compactMap { side, path in
                guard let path else { return nil }
                return PreviewImage(
                    id: path,
                    source: .media(path: path),
                    label: shot.caption?.isEmpty == false ? shot.caption : nil,
                    walkthroughLabel: side
                )
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(OS1VisualStyle.textFaint)
                .rotationEffect(.degrees(state.expanded ? 0 : -90))
            Image(systemName: "play.rectangle")
                .font(.system(size: 11, weight: .semibold))
            Text("Walkthrough")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            // Folded, what the card holds — the one thing a reader needs to
            // decide whether to open it. Open, they can see that for
            // themselves, so the slot goes back to saying when it was
            // published (the same trade the work fold's header makes).
            Text(state.expanded ? publishedLabel : contentsLabel)
                .font(.caption2)
                .foregroundStyle(OS1VisualStyle.textFaint)
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(OS1VisualStyle.textDim)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }

    /// "Demo · 2 stills" — omitted pieces collapse rather than leaving a
    /// stray separator, and a writeup-only walkthrough says so instead of
    /// looking empty.
    private var contentsLabel: String {
        var parts: [String] = []
        if walkthrough.video != nil { parts.append("Demo") }
        let stills = walkthrough.stills.reduce(0) { count, shot in
            count + [shot.before, shot.after].compactMap { $0 }.count
        }
        if stills > 0 { parts.append("\(stills) still\(stills == 1 ? "" : "s")") }
        if parts.isEmpty, !walkthrough.summary.isEmpty { parts.append("Writeup") }
        return parts.joined(separator: " · ")
    }

    private var publishedLabel: String {
        guard let published = walkthrough.publishedDate else { return "" }
        return published.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private var accessibilityLabel: String {
        var parts = ["Walkthrough"]
        let contents = contentsLabel
        if !contents.isEmpty { parts.append(contents.replacing(" · ", with: ", ")) }
        return parts.joined(separator: ", ")
    }
}

/// The folded card's stills in reading order. A tap opens the full-screen
/// gallery at that image, so Before and After can be compared without opening
/// the walkthrough first.
private struct WalkthroughThumbnailStrip: View {
    let stills: [WalkthroughShot]
    let gallery: [PreviewImage]

    /// A pair fits side by side at phone width while remaining large enough to
    /// distinguish two screenshots of the same interface.
    private static let tile = CGSize(width: 168, height: 160)

    var body: some View {
        ScrollView(.horizontal) {
            // Keep each pair tight and leave a larger gap between changes.
            HStack(alignment: .top, spacing: 14) {
                ForEach(stills) { shot in
                    let items: [(label: String, path: String)] = [
                        ("Before", shot.before), ("After", shot.after),
                    ].compactMap { item in
                        item.1.map { (item.0, $0) }
                    }
                    HStack(spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            MediaImage(
                                path: item.path,
                                gallery: gallery,
                                galleryIndex: gallery.firstIndex { $0.id == item.path } ?? 0,
                                label: item.label,
                                thumbnail: Self.tile
                            )
                        }
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
        // A clipped next tile communicates that the strip continues.
        .padding(.horizontal, -WalkthroughCard.padding)
        .contentMargins(.horizontal, WalkthroughCard.padding, for: .scrollContent)
    }
}

/// The demo recording. `VideoPlayer` streams it over the same range-enabled
/// media route the web `<video>` uses, so it seeks without downloading first.
///
/// Sized to the recording's own shape, not to a fixed box. A player is a black
/// rectangle that letterboxes whatever it is given: at the 200pt height this
/// started at, a landscape demo lost the card's width to bars down both sides
/// and a PORTRAIT one — a phone recording, which is most of what the app's own
/// walkthroughs show — played as a sliver about a fifth the size of the room
/// the card had for it.
private struct WalkthroughVideo: View {
    let url: URL

    @State private var player: AVPlayer?
    /// The recording's display ratio, once the asset says what it is. 16:9
    /// until then, so the row doesn't resize under a reader who is already
    /// watching — landscape is the common case and the cheap guess.
    @State private var ratio: CGFloat?

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(ratio ?? 16 / 9, contentMode: .fit)
            // A tall recording would otherwise fill the screen and bury the
            // writeup under it; the same ceiling the stills use.
            .frame(maxWidth: .infinity, maxHeight: WalkthroughCard.mediaHeightCap)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .task {
                guard ratio == nil else { return }
                ratio = await Self.displayRatio(of: url)
            }
            .onAppear {
                guard player == nil else { return }
                player = AVPlayer(url: url)
            }
            // Deliberately not autoplaying: a transcript that starts talking
            // at you while you scroll past is worse than a tap.
            .onDisappear { player?.pause() }
    }

    /// Width over height as the recording is MEANT to be shown — the natural
    /// size turned by the track's transform, since a phone recording is stored
    /// landscape with a rotation on it and its raw size claims the opposite
    /// shape of what plays.
    private static func displayRatio(of url: URL) async -> CGFloat? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return nil }
        let shown = size.applying(transform)
        let width = abs(shown.width), height = abs(shown.height)
        guard width > 0, height > 0 else { return nil }
        return width / height
    }
}

/// One before/after pair, stacked rather than side by side — at phone width
/// two half-width screenshots are too small to show what changed.
private struct WalkthroughShotView: View {
    let shot: WalkthroughShot
    /// All the card's stills; each still finds itself in it by path.
    let gallery: [PreviewImage]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let caption = shot.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(OS1VisualStyle.textDim)
            }
            if let before = shot.before {
                labelled("Before", path: before)
            }
            if let after = shot.after {
                labelled("After", path: after)
            }
        }
    }

    private func labelled(_ label: String, path: String) -> some View {
        MediaImage(
            path: path,
            gallery: gallery,
            galleryIndex: gallery.firstIndex { $0.id == path } ?? 0,
            label: label
        )
        .padding(.horizontal, -WalkthroughCard.padding)
    }
}

/// A staged still, fetched with the session's credentials and tappable into
/// the same full-screen viewer transcript images use.
private struct MediaImage: View {
    let path: String
    var gallery: [PreviewImage] = []
    var galleryIndex: Int = 0
    var label: String? = nil
    /// Set to render at a fixed size, cropped to fill — the folded card's
    /// strip. Unset, the still is shown whole at the card's width.
    var thumbnail: CGSize?

    @State private var data: Data?
    /// The still's own aspect ratio. `DataImage` renders `scaledToFill`, which
    /// crops a wide screenshot to whatever box it lands in — sizing the box to
    /// the image's ratio is what makes fill behave as fit, so a walkthrough
    /// shot is shown whole rather than with its right edge cut off.
    @State private var ratio: CGFloat?
    @State private var failed = false
    @State private var retryCount = 0

    var body: some View {
        Group {
            if let data {
                let image = ExpandableDataImage(
                    data: data, gallery: gallery, galleryIndex: galleryIndex
                )
                if let thumbnail {
                    image
                        .frame(width: thumbnail.width, height: thumbnail.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        // Most of what these show is a screenshot of a light
                        // UI on a light card, which without an edge dissolves
                        // into the card instead of reading as a picture.
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(OS1VisualStyle.border, lineWidth: 0.5)
                        }
                } else {
                    image
                        .aspectRatio(ratio ?? 16 / 9, contentMode: .fit)
                        // A tall screenshot would otherwise take the whole
                        // screen and bury the rest of the walkthrough under
                        // it. The cap is what a PHONE shot runs into — at the
                        // card's width one wants ~780pt of height — and it is
                        // a ceiling on HEIGHT, so it costs a portrait shot
                        // width too: every point taken off the cap narrows the
                        // picture by about half a point. 640 keeps the card's
                        // bottom edge and the start of the next block in view
                        // on the shortest phone this app runs on.
                        .frame(maxWidth: .infinity, maxHeight: WalkthroughCard.mediaHeightCap)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            } else {
                Button { retryCount += 1 } label: {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.fill.tertiary)
                        .frame(width: thumbnail?.width, height: thumbnail?.height ?? 120)
                        .overlay {
                            if failed {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundStyle(.tertiary)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(!failed)
                .accessibilityLabel(failed ? "Retry image" : "Loading image")
            }
        }
        .overlay(alignment: .topLeading) {
            if let label {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(label == "Before" ? OS1VisualStyle.red : OS1VisualStyle.green)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        (label == "Before" ? OS1VisualStyle.red : OS1VisualStyle.green).opacity(0.14),
                        in: Capsule()
                    )
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .task(id: "\(path)#\(retryCount)") {
            guard data == nil else { return }
            failed = false
            do {
                guard let loaded = await DisplayableImageData.prepare(
                    try await OS1API.media(path: path)
                ) else {
                    failed = true
                    return
                }
                ratio = Self.aspectRatio(of: loaded)
                data = loaded
            } catch {
                failed = true
            }
        }
    }

    private static func aspectRatio(of data: Data) -> CGFloat? {
        #if canImport(UIKit)
        let size = UIImage(data: data)?.size
        #else
        let size = NSImage(data: data)?.size
        #endif
        guard let size, size.width > 0, size.height > 0 else { return nil }
        return size.width / size.height
    }
}

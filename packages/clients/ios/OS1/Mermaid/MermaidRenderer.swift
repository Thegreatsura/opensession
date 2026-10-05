import Foundation
import WebKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A laid-out diagram: PNG bytes, and the size mermaid drew it at.
///
/// PNG rather than a live image so the result rides the same path as every
/// other picture in the transcript — `pinchToPeek`, the full-screen viewer —
/// and so one bitmap can be measured against the cache's byte budget.
struct MermaidDiagram: Sendable, Equatable {
    let png: Data
    /// CSS pixels, which the page renders at 1:1 with points.
    let size: CGSize
    /// Pixels per point in `png`. PNG carries no scale, so an image rebuilt
    /// from these bytes claims to be `scale` times its true size — on a 3x
    /// phone that is a diagram laid out three times too large, which the row
    /// then clips instead of fitting. The view rebuilds the image WITH this.
    let scale: CGFloat
}

/// Draws ```mermaid fences by running mermaid in ONE offscreen web view and
/// snapshotting the result. The transcript itself never holds a web view: a
/// row shows a plain `Image`, so a lazy list scrolls at SwiftUI speed and a
/// diagram that has been seen once costs nothing to see again.
///
/// There is no native mermaid: the layout engines (dagre for flowcharts, one
/// per diagram type besides) are the bulk of the library, so fidelity with the
/// web means running the same JavaScript the web runs. Keeping it offscreen
/// and cached is what makes that cheap.
///
/// Renders are serialized — one page, one `mermaid.render` at a time — and
/// bounded by a timeout, because a pathological diagram can wedge the JS
/// thread and would otherwise hang every diagram behind it.
@MainActor
final class MermaidRenderer: NSObject {
    static let shared = MermaidRenderer()

    /// Mirrors the web's ceiling: past this, layout freezes rather than draws.
    private static let maxSourceCharacters = 20_000
    /// A diagram bigger than this in either direction is a runaway; the code
    /// fence is a better answer than a 100MB bitmap.
    private static let maxDimension: CGFloat = 4096
    private static let renderTimeout: Duration = .seconds(8)

    /// Boxed so a failure caches too: an unparseable fence must not be retried
    /// on every scroll pass.
    private final class Entry {
        let diagram: MermaidDiagram?
        init(_ diagram: MermaidDiagram?) { self.diagram = diagram }
    }

    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    private var webView: WKWebView?
    private var loadedPage: URL?
    private var pendingLoad: CheckedContinuation<Void, Never>?
    /// FIFO: each render waits on the one before it.
    private var tail: Task<Void, Never> = Task {}
    /// The window the page is parked in — see `host(_:)`.
    #if os(iOS)
    private var window: UIWindow?
    #else
    private var window: NSWindow?
    #endif

    /// The diagram for this source, or nil when it doesn't parse, is too big,
    /// or the mermaid bundle isn't available. Callers keep the code fence for
    /// every nil, exactly like the web does.
    func diagram(
        source: String,
        dark: Bool,
        background: String
    ) async -> MermaidDiagram? {
        let key = "\(dark ? "dark" : "light")|\(background)|\(source)" as NSString
        if let hit = cache.object(forKey: key) { return hit.diagram }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maxSourceCharacters else { return nil }

        // Unstructured on purpose: a row scrolled off mid-render cancels its
        // `.task`, and the work should still finish and land in the cache
        // rather than start over when the row comes back.
        let previous = tail
        let work = Task { @MainActor [weak self] () -> MermaidDiagram? in
            await previous.value
            guard let self else { return nil }
            if let hit = self.cache.object(forKey: key) { return hit.diagram }
            let diagram = await self.render(
                source: trimmed,
                dark: dark,
                background: background
            )
            self.cache.setObject(
                Entry(diagram),
                forKey: key,
                cost: diagram.map { $0.png.count } ?? 1
            )
            return diagram
        }
        tail = Task { _ = await work.value }
        return await work.value
    }

    // MARK: - Rendering

    private func render(
        source: String,
        dark: Bool,
        background: String
    ) async -> MermaidDiagram? {
        guard let page = MermaidHostPage.url,
              let webView = await ready(page: page)
        else { return nil }
        let outcome: CGSize?? = await withTimeout(Self.renderTimeout) {
            try? await Self.measure(
                in: webView,
                source: source,
                dark: dark,
                background: background
            )
        }
        // Nothing at all means the deadline won: the JS thread is wedged and
        // the page can't be trusted for the next diagram either.
        guard let attempt = outcome else {
            teardown()
            return nil
        }
        // A nil inside means mermaid refused the source — an ordinary outcome,
        // and the page is fine.
        guard let size = attempt else { return nil }
        guard size.width > 0, size.height > 0,
              size.width <= Self.maxDimension, size.height <= Self.maxDimension
        else { return nil }
        guard let shot = await snapshot(webView, size: size) else { return nil }
        return MermaidDiagram(png: shot.png, size: size, scale: shot.scale)
    }

    /// Runs the page's `render()` and returns the size it laid the diagram out
    /// at, or nil when mermaid refused the source.
    ///
    /// When mermaid refuses `source`, the page retries once with
    /// `MermaidRepair`'s version of it, in the same call and under the same
    /// deadline. Only the drawing changes: the cache key and the code fence
    /// the view falls back to keep the source as written.
    ///
    /// The source travels as a JS *argument*, never interpolated into a script
    /// string: it is untrusted transcript text, and escaping it by hand is the
    /// kind of thing that works until a diagram contains a quote.
    private static func measure(
        in webView: WKWebView,
        source: String,
        dark: Bool,
        background: String
    ) async throws -> CGSize? {
        let result = try await webView.callAsyncJavaScript(
            "return await render(source, repaired, theme, font, bg);",
            arguments: [
                "source": source,
                "repaired": MermaidRepair.repairedSource(source) ?? NSNull(),
                "theme": dark ? "dark" : "default",
                "font": "-apple-system, BlinkMacSystemFont, system-ui, sans-serif",
                "bg": background,
            ],
            contentWorld: .page
        )
        guard let dictionary = result as? [String: Any],
              let width = dictionary["width"] as? Double,
              let height = dictionary["height"] as? Double
        else { return nil }
        return CGSize(width: width, height: height)
    }

    private func snapshot(
        _ webView: WKWebView,
        size: CGSize
    ) async -> (png: Data, scale: CGFloat)? {
        resize(webView, to: size)
        // Wait for the page to actually SEE the new bounds. The resize is
        // asynchronous — on iOS the view is re-laid out a turn or two later —
        // and a snapshot taken before it lands captures the diagram cut off at
        // the old viewport, which is exactly what shipped-looking-fine bugs
        // are made of. Ask the page what size it thinks it is until it agrees.
        for _ in 0..<10 {
            let viewport = try? await webView.callAsyncJavaScript(
                "return await settle();",
                contentWorld: .page
            )
            guard let box = viewport as? [String: Any],
                  let width = box["width"] as? Double,
                  let height = box["height"] as? Double
            else { break }
            if width + 1 >= size.width, height + 1 >= size.height { break }
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        configuration.afterScreenUpdates = true
        let image = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }
        guard let image else { return nil }
        #if os(iOS)
        guard let png = image.pngData() else { return nil }
        return (png, image.scale)
        #else
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        // A snapshot's NSImage is sized in points; the bitmap behind it is the
        // backing store, so their ratio is the scale the page was captured at.
        let scale = size.width > 0 ? CGFloat(rep.pixelsWide) / size.width : 1
        return (png, max(scale, 1))
        #endif
    }

    // MARK: - The offscreen page

    /// The shared web view with the host page loaded, or nil if it can't be
    /// stood up (no window to host it in yet, most likely — the next diagram
    /// tries again).
    private func ready(page: URL) async -> WKWebView? {
        if let webView, loadedPage == page, webView.isHosted { return webView }
        if webView == nil || !(webView?.isHosted ?? false) { teardown() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = true
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 240),
            configuration: configuration
        )
        webView.navigationDelegate = self
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        // The page is a canvas, not a document: without this the scroll view
        // inherits the window's safe-area inset, the content starts an inch
        // down, and the snapshot loses the same strip off the bottom.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #endif
        guard host(webView) else { return nil }
        self.webView = webView
        webView.loadFileURL(
            page,
            allowingReadAccessTo: MermaidHostPage.readAccess ?? page
        )
        // The bundle is 3.5MB of JavaScript to parse; give it room, but never
        // hang the queue on it.
        let loaded: Void? = await withTimeout(.seconds(20)) { [weak self] in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self?.pendingLoad = continuation
            }
        }
        guard loaded != nil else {
            teardown()
            return nil
        }
        loadedPage = page
        return webView
    }

    private func finishLoad() {
        pendingLoad?.resume()
        pendingLoad = nil
    }

    private func teardown() {
        finishLoad()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        #if os(iOS)
        window?.isHidden = true
        #else
        window?.orderOut(nil)
        #endif
        window = nil
        webView = nil
        loadedPage = nil
    }

    /// Puts the web view somewhere it will actually rasterize. WebKit only
    /// paints — and so only snapshots — a view that belongs to a window, so
    /// "offscreen" here means present but invisible, not detached.
    ///
    /// Invisible by being COVERED, never by being faded: `takeSnapshot`
    /// captures the view as composited, so hiding the page behind an alpha of
    /// 0.01 produced diagrams that were 1% opaque ghosts. The page therefore
    /// lives at full opacity in its own window one level below the app's own,
    /// which is opaque and covers it completely.
    private func host(_ webView: WKWebView) -> Bool {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first
        else { return false }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal - 1
        window.isUserInteractionEnabled = false
        window.isHidden = false
        window.addSubview(webView)
        self.window = window
        return true
        #else
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: webView.frame)
        window.contentView?.addSubview(webView)
        window.orderBack(nil)
        self.window = window
        return true
        #endif
    }

    /// The host window grows with the page: a diagram wider than the screen
    /// would otherwise be clipped by its own window before the snapshot ever
    /// sees it.
    private func resize(_ webView: WKWebView, to size: CGSize) {
        #if os(iOS)
        window?.frame = CGRect(origin: .zero, size: size)
        #else
        window?.setContentSize(size)
        #endif
        webView.frame = CGRect(origin: .zero, size: size)
    }

    /// `body` raced against a deadline. nil means the deadline won.
    ///
    /// Deliberately not a task group: the whole point of the deadline is that
    /// `body` may never finish (a diagram that wedges the JS thread leaves
    /// `callAsyncJavaScript`'s completion handler uncalled, and no amount of
    /// cancellation unsticks it), and a group can't return until its children
    /// do. Racing two continuations lets the caller walk away and tear the
    /// page down while the stuck call is still notionally outstanding.
    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        _ body: @escaping @MainActor () async -> T
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = ResumeOnce(continuation)
            Task { @MainActor in once.resume(await body()) }
            Task { @MainActor in
                try? await Task.sleep(for: duration)
                once.resume(nil)
            }
        }
    }

    /// Whichever of the two racers finishes first wins; the loser's resume is
    /// dropped rather than crashing on a second resume.
    @MainActor
    private final class ResumeOnce<T: Sendable> {
        private var continuation: CheckedContinuation<T?, Never>?

        init(_ continuation: CheckedContinuation<T?, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: T?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}

extension MermaidRenderer: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finishLoad() }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated { finishLoad() }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated { finishLoad() }
    }

    /// The web content process died — usually a diagram that ate all the
    /// memory. Drop the page so the next diagram builds a fresh one instead of
    /// waiting forever on a corpse.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { teardown() }
    }
}

private extension WKWebView {
    /// Whether this view still belongs to a window, which is what it needs to
    /// paint. The iOS host window is the app's own, and can go away.
    var isHosted: Bool {
        #if os(iOS)
        window != nil
        #else
        window != nil
        #endif
    }
}

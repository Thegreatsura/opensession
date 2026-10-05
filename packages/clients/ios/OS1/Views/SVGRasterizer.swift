import Foundation
import WebKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Draws a sanitized SVG to PNG the way the web viewer shows it: as the
/// source of an `<img>`, in a web view that can do nothing else.
///
/// `UIImage` has no public SVG decoder, and WebKit is the platform's SVG
/// renderer, so fidelity with the web (text, CSS classes, gradients, filters)
/// means using it. An image document is WebKit's most restricted mode: it runs
/// no script and loads no subresource. Around that, each render gets its own
/// throwaway page that also:
///
/// - has JavaScript turned off and a CSP that allows nothing but `data:`
///   images and the page's own inline style,
/// - runs under a content rule list blocking every network and file scheme,
/// - uses a non-persistent data store, so it shares no cookies or storage
///   with anything,
/// - permits exactly one navigation, the initial `about:blank` load, and has
///   no UI delegate, so it can open no window,
/// - takes no input, and is torn down as soon as it has been snapshotted.
///
/// The markup reaching it has already been through `SVGSanitizer`; the page
/// is the second wall, not the only one.
///
/// Used on the phone. The Mac draws SVG through `NSImage` and only reaches
/// this in tests, which exercise the same sandbox there.
@MainActor
final class SVGRasterizer: NSObject {
    static let shared = SVGRasterizer()

    /// Points on the long side the picture is drawn at: small icons are blown
    /// up so a thumbnail and the zoomed viewer stay sharp, huge canvases are
    /// capped so a bitmap stays a few megabytes.
    nonisolated static let minLongSide: CGFloat = 256
    nonisolated static let maxLongSide: CGFloat = 768
    private static let renderTimeout: Duration = .seconds(10)

    /// FIFO: one page at a time, so a transcript full of SVGs is a queue
    /// rather than a burst of web content processes.
    private var tail: Task<Void, Never> = Task {}
    private var ruleList: WKContentRuleList?

    /// The size `svg` is drawn at, in points.
    nonisolated static func renderSize(for intrinsic: CGSize) -> CGSize {
        let long = max(intrinsic.width, intrinsic.height, 1)
        let scale = min(maxLongSide / long, max(1, minLongSide / long))
        return CGSize(
            width: max(1, (intrinsic.width * scale).rounded()),
            height: max(1, (intrinsic.height * scale).rounded())
        )
    }

    func png(for svg: SanitizedSVG) async -> Data? {
        await render(markup: svg.markup, size: Self.renderSize(for: svg.size))
    }

    /// Renders `markup` as an `<img>` at `size` points. Internal so tests can
    /// hand the page markup that has NOT been sanitized and check the page
    /// holds on its own.
    func render(markup: Data, size: CGSize) async -> Data? {
        // Unstructured on purpose, like the mermaid renderer: a thumbnail that
        // scrolls away cancels its `.task`, and the render should still finish
        // rather than wedge the queue behind it.
        let previous = tail
        let work = Task { @MainActor [weak self] () -> Data? in
            await previous.value
            guard let self else { return nil }
            return await self.renderNow(markup: markup, size: size)
        }
        tail = Task { _ = await work.value }
        return await work.value
    }

    // MARK: - One page

    nonisolated static func html(markup: Data, size: CGSize) -> String {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        return """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">\
        <meta name="viewport" content="width=\(width), initial-scale=1, user-scalable=no">\
        <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}\
        img{display:block;width:\(width)px;height:\(height)px}</style></head>\
        <body><img alt="" src="data:image/svg+xml;base64,\(markup.base64EncodedString())"></body></html>
        """
    }

    /// Every scheme that names something outside the page. `data:` is the
    /// only one the page needs, and it is not listed.
    nonisolated static let blockedSchemes = ["https?", "wss?", "ftp", "file", "blob", "ftps?", "javascript"]

    private func rules() async -> WKContentRuleList? {
        if let ruleList { return ruleList }
        let triggers = Self.blockedSchemes.map {
            #"{"trigger":{"url-filter":"^\#($0):"},"action":{"type":"block"}}"#
        }
        let list = try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "os1-svg-image-sandbox-v1",
            encodedContentRuleList: "[\(triggers.joined(separator: ","))]"
        )
        ruleList = list
        return list
    }

    private func renderNow(markup: Data, size: CGSize) async -> Data? {
        // Fail closed: without the rule list the page does not get built.
        guard size.width > 0, size.height > 0, let rules = await rules() else { return nil }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.suppressesIncrementalRendering = true
        configuration.userContentController.add(rules)
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        #if os(iOS)
        configuration.dataDetectorTypes = []
        configuration.allowsInlineMediaPlayback = false
        #endif

        let frame = CGRect(origin: .zero, size: size)
        let webView = WKWebView(frame: frame, configuration: configuration)
        let gate = NavigationGate()
        webView.navigationDelegate = gate
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isUserInteractionEnabled = false
        #endif
        guard let host = Host(webView: webView, size: size) else { return nil }
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            host.close()
        }

        let loaded: Bool? = await Self.withTimeout(Self.renderTimeout) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                gate.onFinish = { continuation.resume(returning: $0) }
                webView.loadHTMLString(Self.html(markup: markup, size: size), baseURL: nil)
            }
        }
        guard loaded == true else { return nil }

        let snapshot = WKSnapshotConfiguration()
        snapshot.rect = frame
        snapshot.afterScreenUpdates = true
        let png: Data?? = await Self.withTimeout(Self.renderTimeout) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                webView.takeSnapshot(with: snapshot) { image, _ in
                    continuation.resume(returning: image.flatMap(Self.png))
                }
            }
        }
        return png ?? nil
    }

    #if os(iOS)
    private static func png(_ image: UIImage) -> Data? { image.pngData() }
    #else
    private static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
    #endif

    /// WebKit only paints a view that belongs to a window, so the page is
    /// parked in one of its own: on the phone a full-opacity window one level
    /// below the app's (covered, never faded, or the snapshot comes out
    /// faded too), on the Mac a borderless one behind everything.
    @MainActor
    private struct Host {
        #if os(iOS)
        let window: UIWindow
        #else
        let window: NSWindow
        #endif

        init?(webView: WKWebView, size: CGSize) {
            #if os(iOS)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                ?? scenes.first
            else { return nil }
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .normal - 1
            window.isUserInteractionEnabled = false
            window.frame = CGRect(origin: .zero, size: size)
            window.isHidden = false
            window.addSubview(webView)
            self.window = window
            #else
            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.alphaValue = 0.01
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: CGRect(origin: .zero, size: size))
            window.contentView?.addSubview(webView)
            window.orderBack(nil)
            self.window = window
            #endif
        }

        func close() {
            #if os(iOS)
            window.subviews.forEach { $0.removeFromSuperview() }
            window.isHidden = true
            #else
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            window.orderOut(nil)
            #endif
        }
    }

    /// Allows the one load the renderer starts and nothing after it: no link,
    /// redirect, frame or form gets to take the page anywhere.
    @MainActor
    final class NavigationGate: NSObject, WKNavigationDelegate {
        var onFinish: ((Bool) -> Void)?
        private var started = false

        private func finish(_ ok: Bool) {
            onFinish?(ok)
            onFinish = nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            Self.policy(
                url: navigationAction.request.url,
                isMainFrame: navigationAction.targetFrame?.isMainFrame == true,
                started: &started
            )
        }

        /// The decision itself, apart from WebKit's types so it can be tested.
        static func policy(url: URL?, isMainFrame: Bool, started: inout Bool) -> WKNavigationActionPolicy {
            let isInitial = !started && isMainFrame && url?.absoluteString == "about:blank"
            if isInitial { started = true }
            return isInitial ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish(true)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(false)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            finish(false)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            finish(false)
        }
    }

    /// `body` raced against a deadline; nil means the deadline won. Two
    /// continuations rather than a task group, because a wedged WebKit
    /// callback never returns and a group would wait for it.
    private static func withTimeout<T: Sendable>(
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

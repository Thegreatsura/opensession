import XCTest
import AppKit
import Network
import WebKit
@testable import OS1

/// SVG reaches the app from `/media` (a local file an agent announced) and
/// from uploads, and it is untrusted markup either way. These pin that it is
/// rebuilt from an allowlist, drawn on both platforms' paths, and that raster
/// images are left exactly as they were.
final class SVGImageTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "svg"),
            "missing fixture \(name).svg"
        )
        return try Data(contentsOf: url)
    }

    private func sanitizedMarkup(_ name: String) throws -> (String, SanitizedSVG) {
        let svg = try XCTUnwrap(SVGSanitizer.sanitize(fixture(name)))
        return (String(decoding: svg.markup, as: UTF8.self), svg)
    }

    // MARK: - Sniffing

    func testSniffsSVGFixturesButNotRasters() throws {
        for name in ["local-media", "uploaded", "hostile"] {
            XCTAssertTrue(SVGSanitizer.looksLikeSVG(try fixture(name)), name)
        }
        XCTAssertTrue(SVGSanitizer.looksLikeSVG(Data("\u{FEFF}  <svg/>".utf8)))
        XCTAssertFalse(SVGSanitizer.looksLikeSVG(Self.raster(.png)))
        XCTAssertFalse(SVGSanitizer.looksLikeSVG(Self.raster(.jpeg)))
        XCTAssertFalse(SVGSanitizer.looksLikeSVG(Data("plain text mentioning <svg".utf8)))
    }

    // MARK: - Sanitizing

    func testLocalMediaChartKeepsItsDrawing() throws {
        let (markup, svg) = try sanitizedMarkup("local-media")
        XCTAssertEqual(svg.size, CGSize(width: 200, height: 100))
        XCTAssertTrue(markup.hasPrefix("<svg xmlns=\"http://www.w3.org/2000/svg\""))
        for kept in ["<linearGradient", "<stop", "url(#bar)", "<text", "Build time", ".label"] {
            XCTAssertTrue(markup.contains(kept), "dropped \(kept)")
        }
        XCTAssertFalse(markup.contains("<!--"))
    }

    func testUploadedLogoSizesFromViewBoxAndDropsEditorMetadata() throws {
        let (markup, svg) = try sanitizedMarkup("uploaded")
        XCTAssertEqual(svg.size, CGSize(width: 64, height: 64))
        XCTAssertTrue(markup.contains("xlink:href=\"#dot\""))
        XCTAssertTrue(markup.contains("xmlns:xlink="))
        XCTAssertFalse(markup.contains("inkscape"))
    }

    func testHostileMarkupLosesEveryWayOut() throws {
        let (markup, svg) = try sanitizedMarkup("hostile")
        XCTAssertEqual(svg.size, CGSize(width: 100, height: 100))
        let lower = markup.lowercased()
        for banned in [
            "<script", "onload", "onclick", "foreignobject", "iframe", "javascript:",
            "@import", "xml-stylesheet", "<set", "feimage", "127.0.0.1", "file:", "<a ", "<a>",
        ] {
            XCTAssertFalse(lower.contains(banned), "kept \(banned): \(markup)")
        }
        // The drawing itself survives, links unwrapped rather than dropped.
        XCTAssertTrue(markup.contains("fill=\"#16a34a\""))
        XCTAssertTrue(markup.contains("<circle"))
        XCTAssertTrue(markup.contains(">link</text>"))
        // Pictures and clones that pointed outside go entirely, rather than
        // staying as empty boxes a decoder draws as broken images.
        XCTAssertFalse(markup.contains("<image"))
        XCTAssertFalse(markup.contains("<use"))
        // An outside paint server paints nothing, as it would on the web,
        // rather than falling back to black.
        XCTAssertTrue(markup.contains(#"fill="none""#))
    }

    func testEmbeddedRasterAndInternalReferencesStay() throws {
        let png = Self.raster(.png).base64EncodedString()
        let source = """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 8 8">\
        <defs><rect id="r" width="4" height="4"/></defs><use href="#r"/>\
        <image width="4" height="4" xlink:href="data:image/png;base64,\(png)"/></svg>
        """
        let markup = String(decoding: try XCTUnwrap(SVGSanitizer.sanitize(Data(source.utf8))).markup, as: UTF8.self)
        XCTAssertTrue(markup.contains(##"<use href="#r">"##))
        XCTAssertTrue(markup.contains("<image "))
        XCTAssertTrue(markup.contains("data:image/png;base64,"))
    }

    func testEntityDeclarationsAreRefused() throws {
        XCTAssertNil(SVGSanitizer.sanitize(try fixture("entity-expansion")))
    }

    func testOnlyAnSVGRootIsAPicture() {
        XCTAssertNil(SVGSanitizer.sanitize(Data("<html><svg/></html>".utf8)))
        XCTAssertNil(SVGSanitizer.sanitize(Data("<svg><rect>".utf8)))
        XCTAssertNil(SVGSanitizer.sanitize(Data()))
    }

    func testAbsoluteSizeWithoutViewBoxGetsOneSoItScales() throws {
        let svg = try XCTUnwrap(SVGSanitizer.sanitize(Data(
            #"<svg xmlns="http://www.w3.org/2000/svg" width="40px" height="20"><rect width="40" height="20"/></svg>"#.utf8
        )))
        XCTAssertEqual(svg.size, CGSize(width: 40, height: 20))
        XCTAssertTrue(String(decoding: svg.markup, as: UTF8.self).contains(#"viewBox="0 0 40 20""#))
    }

    func testHrefAndValueRules() {
        XCTAssertTrue(SVGSanitizer.isSafeHref("#a", element: "use"))
        XCTAssertTrue(SVGSanitizer.isSafeHref("data:image/png;base64,AAAA", element: "image"))
        XCTAssertFalse(SVGSanitizer.isSafeHref("data:image/png;base64,AAAA", element: "use"))
        XCTAssertFalse(SVGSanitizer.isSafeHref("data:image/svg+xml;base64,AAAA", element: "image"))
        XCTAssertFalse(SVGSanitizer.isSafeHref("https://example.test/a.png", element: "image"))
        XCTAssertTrue(SVGSanitizer.isSafeValue("url(#g) none"))
        XCTAssertTrue(SVGSanitizer.isSafeValue("url( '#g' )"))
        XCTAssertFalse(SVGSanitizer.isSafeValue("url(#g) url(https://example.test/x)"))
        XCTAssertFalse(SVGSanitizer.isSafeValue("JavaScript:alert(1)"))
    }

    // MARK: - Displayable bytes

    func testRastersPassThroughUntouched() async {
        for format in [NSBitmapImageRep.FileType.png, .jpeg] {
            let bytes = Self.raster(format)
            let shown = await DisplayableImageData.prepare(bytes)
            XCTAssertEqual(shown, bytes)
            XCTAssertNotNil(shown.flatMap(NSImage.init(data:)))
        }
    }

    /// The Mac's path: sanitized SVG straight into `NSImage`, which draws it.
    func testMacDrawsSanitizedFixturesThroughNSImage() async throws {
        let chartSource = try fixture("local-media"), logoSource = try fixture("uploaded")
        let chart = try await XCTUnwrapAsync(await DisplayableImageData.prepare(chartSource))
        Self.assertColor(of: chart, at: CGPoint(x: 0.05, y: 0.1), near: (0x25, 0x63, 0xeb))

        let logo = try await XCTUnwrapAsync(await DisplayableImageData.prepare(logoSource))
        Self.assertColor(of: logo, at: CGPoint(x: 0.5, y: 0.5), near: (0x16, 0xa3, 0x4a))
    }

    func testUnsafeSVGThatCannotBeRebuiltIsAFailureNotABlank() async throws {
        let shown = await DisplayableImageData.prepare(try fixture("entity-expansion"))
        XCTAssertNil(shown)
    }

    // MARK: - The phone's web view sandbox

    func testRenderSizeBounds() {
        XCTAssertEqual(SVGRasterizer.renderSize(for: CGSize(width: 16, height: 8)), CGSize(width: 256, height: 128))
        XCTAssertEqual(SVGRasterizer.renderSize(for: CGSize(width: 4000, height: 1000)), CGSize(width: 768, height: 192))
        XCTAssertEqual(SVGRasterizer.renderSize(for: CGSize(width: 300, height: 150)), CGSize(width: 300, height: 150))
    }

    @MainActor
    func testOnlyTheInitialBlankLoadNavigates() {
        var started = false
        let blank = URL(string: "about:blank")
        XCTAssertEqual(SVGRasterizer.NavigationGate.policy(url: blank, isMainFrame: false, started: &started), .cancel)
        XCTAssertEqual(SVGRasterizer.NavigationGate.policy(url: blank, isMainFrame: true, started: &started), .allow)
        XCTAssertEqual(SVGRasterizer.NavigationGate.policy(url: blank, isMainFrame: true, started: &started), .cancel)
        XCTAssertEqual(
            SVGRasterizer.NavigationGate.policy(url: URL(string: "https://example.test"), isMainFrame: true, started: &started),
            .cancel
        )
    }

    func testPageAllowsNothingButItsDataImage() {
        let html = SVGRasterizer.html(markup: Data("<svg/>".utf8), size: CGSize(width: 10, height: 5))
        XCTAssertTrue(html.contains("default-src 'none'; img-src data:"))
        XCTAssertTrue(html.contains("<img alt=\"\" src=\"data:image/svg+xml;base64,"))
        XCTAssertFalse(html.contains("<script"))
    }

    /// What the phone does with a transcript SVG, run here on the same
    /// WebKit: the sanitized fixture comes back as a PNG of the drawing.
    @MainActor
    func testRasterizerDrawsSanitizedFixture() async throws {
        let svg = try XCTUnwrap(SVGSanitizer.sanitize(try fixture("local-media")))
        let png = try await XCTUnwrapAsync(await SVGRasterizer.shared.png(for: svg))
        XCTAssertNotNil(NSBitmapImageRep(data: png))
        Self.assertColor(of: png, at: CGPoint(x: 0.05, y: 0.1), near: (0x25, 0x63, 0xeb))
        // The gradient bar, not the background, near its left end.
        Self.assertColor(of: png, at: CGPoint(x: 0.15, y: 0.72), near: (0xf5, 0x9e, 0x0b), tolerance: 40)
    }

    /// The second wall on its own: hand the page the hostile file WITHOUT
    /// sanitizing it. No script runs (the background stays green) and not one
    /// request reaches a listener its every reference points at.
    @MainActor
    func testRasterizerSandboxHoldsForUnsanitizedHostileMarkup() async throws {
        let listener = try LoopbackListener()
        defer { listener.stop() }
        let port = try await listener.ready()
        let hostile = String(decoding: try fixture("hostile"), as: UTF8.self)
            .replacingOccurrences(of: "127.0.0.1:9/", with: "127.0.0.1:\(port)/")
        let png = try await XCTUnwrapAsync(
            await SVGRasterizer.shared.render(markup: Data(hostile.utf8), size: CGSize(width: 100, height: 100))
        )
        Self.assertColor(of: png, at: CGPoint(x: 0.5, y: 0.5), near: (0x16, 0xa3, 0x4a))

        // And the Mac's own decoder, given the same raw file, fetches nothing
        // either; then the sanitized path for good measure.
        _ = NSImage(data: Data(hostile.utf8))?.tiffRepresentation
        _ = await DisplayableImageData.prepare(Data(hostile.utf8))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(listener.connections, 0, "the sandbox let a request out")

        // Positive control: the listener does count a request that is made.
        _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/control")!)
        XCTAssertGreaterThan(listener.connections, 0, "the listener never saw the control request")
    }

    // MARK: - Helpers

    private static func raster(_ type: NSBitmapImageRep.FileType) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        for x in 0..<4 { for y in 0..<4 { rep.setColor(.systemRed, atX: x, y: y) } }
        return rep.representation(using: type, properties: [:])!
    }

    /// Samples `data` drawn into a bitmap, at a point given as a fraction of
    /// its size from the top-left.
    private static func assertColor(
        of data: Data,
        at point: CGPoint,
        near expected: (Int, Int, Int),
        tolerance: Int = 24,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let image = NSImage(data: data) else {
            return XCTFail("not an image", file: file, line: line)
        }
        let width = 200, height = Int((200 * image.size.height / max(image.size.width, 1)).rounded())
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let x = Int(point.x * CGFloat(width)), y = Int(point.y * CGFloat(height))
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
            return XCTFail("no pixel", file: file, line: line)
        }
        let actual = (
            Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255)
        )
        let close = abs(actual.0 - expected.0) <= tolerance
            && abs(actual.1 - expected.1) <= tolerance
            && abs(actual.2 - expected.2) <= tolerance
        XCTAssertTrue(close, "pixel \(actual) is not near \(expected)", file: file, line: line)
    }
}

private func XCTUnwrapAsync<T>(
    _ value: @autoclosure () async throws -> T?,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> T {
    let resolved = try await value()
    return try XCTUnwrap(resolved, file: file, line: line)
}

/// A TCP listener on loopback that counts whoever knocks.
private final class LoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var count = 0
    var connections: Int { lock.withLock { count } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func ready() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.lock.withLock { self.count += 1 }
                connection.cancel()
            }
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    if claimResume() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if claimResume() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
    }

    private var resumed = false
    private func claimResume() -> Bool {
        lock.withLock {
            defer { resumed = true }
            return !resumed
        }
    }

    func stop() { listener.cancel() }
}

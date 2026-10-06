import Foundation
import CryptoKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// An SVG rebuilt from an allowlist: only drawing elements and attributes
/// survive, so what reaches a renderer can neither run script nor name a
/// resource outside its own bytes.
struct SanitizedSVG: Sendable, Equatable {
    /// UTF-8 SVG markup with an `xmlns` root and, when the source gave an
    /// absolute size but no `viewBox`, one derived from it so the picture
    /// scales to whatever box it is drawn into.
    let markup: Data
    /// The picture's own size in CSS pixels, from `width`/`height` or the
    /// `viewBox`, defaulting to the browser's 300x150 when it names neither.
    let size: CGSize
}

/// Turns untrusted SVG bytes from a transcript into a `SanitizedSVG`.
///
/// The server serves SVG from `/media` and the transcript links uploads and
/// local files that are SVG, so the app sees agent- and user-authored markup.
/// The web viewer draws those through `<img>`, where a browser runs no script
/// and fetches nothing. The app has no `<img>`, so it rebuilds the document
/// from what an image can legitimately contain and drops everything else:
/// scripts, `foreignObject`, event handlers, external `href`s, `url()`s that
/// leave the document, stylesheet imports and entity declarations.
enum SVGSanitizer {
    static let svgNamespace = "http://www.w3.org/2000/svg"
    static let xlinkNamespace = "http://www.w3.org/1999/xlink"
    /// Past this the file is not a picture anyone drew; it is a payload.
    static let maxBytes = 8 * 1024 * 1024
    static let maxElements = 100_000
    static let maxDepth = 256
    static let maxDimension: CGFloat = 16_384

    /// Cheap sniff on the leading bytes, so raster images never pay for a
    /// parse: an SVG is text that opens with markup and names `<svg` early.
    static func looksLikeSVG(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        let trimmed = head.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
        guard trimmed.first == "<" else { return false }
        return trimmed.range(of: "<svg", options: .caseInsensitive) != nil
    }

    static func sanitize(_ data: Data) -> SanitizedSVG? {
        guard !data.isEmpty, data.count <= maxBytes else { return nil }
        // Entity declarations are how XML expands a few bytes into gigabytes
        // or pulls in a file; no picture needs one.
        if data.range(of: Data("<!ENTITY".utf8)) != nil
            || data.range(of: Data("<!entity".utf8)) != nil {
            return nil
        }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        let builder = Builder()
        parser.delegate = builder
        guard parser.parse(), !builder.failed, builder.closedRoot,
              let size = builder.size
        else { return nil }
        return SanitizedSVG(markup: Data(builder.output.utf8), size: size)
    }

    // MARK: - Allowlists

    /// Drawing, structure, paint servers and filters. Everything else is
    /// dropped with its subtree; `a` alone is unwrapped, because a link's
    /// children are ordinary drawing.
    static let allowedElements: Set<String> = [
        "svg", "g", "defs", "symbol", "use", "title", "desc", "style", "switch",
        "rect", "circle", "ellipse", "line", "polyline", "polygon", "path",
        "text", "tspan", "textPath", "image", "marker", "pattern", "clipPath", "mask",
        "linearGradient", "radialGradient", "stop", "filter",
        "feBlend", "feColorMatrix", "feComponentTransfer", "feComposite",
        "feConvolveMatrix", "feDiffuseLighting", "feDisplacementMap",
        "feDistantLight", "feDropShadow", "feFlood", "feFuncA", "feFuncB",
        "feFuncG", "feFuncR", "feGaussianBlur", "feMerge", "feMergeNode",
        "feMorphology", "feOffset", "fePointLight", "feSpecularLighting",
        "feSpotLight", "feTile", "feTurbulence",
    ]
    static let unwrappedElements: Set<String> = ["a"]
    /// Elements that draw nothing but what they point at.
    static let referenceElements: Set<String> = ["image", "use"]
    /// Prefixed attributes that keep their meaning without their author's
    /// namespace declarations; any other prefix (editor metadata, mostly)
    /// would leave the rebuilt document unparseable.
    static let allowedPrefixedAttributes: Set<String> = ["xlink:href", "xml:space", "xml:lang"]
    static let inlineRasterPrefixes = [
        "data:image/png;base64,", "data:image/jpeg;base64,", "data:image/jpg;base64,",
        "data:image/gif;base64,", "data:image/webp;base64,",
    ]

    /// A reference that stays inside this document: `#id` or nothing else.
    static func isSafeHref(_ value: String, element: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { return true }
        // An embedded raster is pixels the document already carries. An
        // embedded SVG is a second document and could carry anything.
        guard element == "image" else { return false }
        let lower = value.lowercased()
        return inlineRasterPrefixes.contains { lower.hasPrefix($0) }
    }

    /// CSS and presentation values may only point back into the document.
    static func isSafeValue(_ value: String) -> Bool {
        let lower = value.lowercased()
        for banned in ["javascript:", "vbscript:", "@import", "expression(", "behavior:", "-moz-binding"]
        where lower.contains(banned) {
            return false
        }
        var rest = lower[...]
        while let open = rest.range(of: "url(") {
            let target = rest[open.upperBound...].drop { $0.isWhitespace || $0 == "\"" || $0 == "'" }
            guard target.first == "#" else { return false }
            rest = target
        }
        return true
    }

    // MARK: - Size

    static func length(_ raw: String?) -> CGFloat? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !text.isEmpty, !text.hasSuffix("%")
        else { return nil }
        let units: [(String, CGFloat)] = [
            ("px", 1), ("pt", 4.0 / 3.0), ("pc", 16), ("mm", 96 / 25.4),
            ("cm", 96 / 2.54), ("in", 96), ("em", 16), ("ex", 8),
        ]
        var factor: CGFloat = 1
        for (unit, scale) in units where text.hasSuffix(unit) {
            text.removeLast(unit.count)
            factor = scale
            break
        }
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)),
              value.isFinite, value > 0
        else { return nil }
        return CGFloat(value) * factor
    }

    static func viewBox(_ raw: String?) -> CGSize? {
        guard let raw else { return nil }
        let parts = raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { Double($0) }
        guard parts.count == 4, parts[2].isFinite, parts[3].isFinite, parts[2] > 0, parts[3] > 0
        else { return nil }
        return CGSize(width: parts[2], height: parts[3])
    }

    static func intrinsicSize(width: String?, height: String?, viewBox raw: String?) -> CGSize {
        let w = length(width), h = length(height), box = viewBox(raw)
        let size: CGSize
        switch (w, h, box) {
        case let (w?, h?, _): size = CGSize(width: w, height: h)
        case let (w?, nil, box?): size = CGSize(width: w, height: w * box.height / box.width)
        case let (nil, h?, box?): size = CGSize(width: h * box.width / box.height, height: h)
        case let (nil, nil, box?): size = box
        case let (w?, nil, nil): size = CGSize(width: w, height: 150)
        case let (nil, h?, nil): size = CGSize(width: 300, height: h)
        default: size = CGSize(width: 300, height: 150)
        }
        return CGSize(
            width: min(max(size.width, 1), maxDimension),
            height: min(max(size.height, 1), maxDimension)
        )
    }

    // MARK: - Rebuilding

    private final class Builder: NSObject, XMLParserDelegate {
        enum Frame { case emitted(String), unwrapped }

        var output = ""
        var failed = false
        var closedRoot = false
        var size: CGSize?
        private var stack: [Frame] = []
        private var skipDepth = 0
        private var elements = 0
        private var styleText: String?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            elements += 1
            guard elements <= SVGSanitizer.maxElements, stack.count < SVGSanitizer.maxDepth else {
                return fail(parser)
            }
            if skipDepth > 0 {
                skipDepth += 1
                return
            }
            let namespace = namespaceURI ?? ""
            let isSVGNamespace = namespace.isEmpty || namespace == SVGSanitizer.svgNamespace
            if size == nil {
                // The document element has to BE an SVG; anything else is not
                // a picture, whatever it was sniffed as.
                guard elementName == "svg", isSVGNamespace, !closedRoot else { return fail(parser) }
                size = SVGSanitizer.intrinsicSize(
                    width: attributes["width"],
                    height: attributes["height"],
                    viewBox: attributes["viewBox"]
                )
            } else if closedRoot {
                return fail(parser)
            }
            guard isSVGNamespace else {
                skipDepth = 1
                return
            }
            if SVGSanitizer.unwrappedElements.contains(elementName) {
                stack.append(.unwrapped)
                return
            }
            guard SVGSanitizer.allowedElements.contains(elementName) else {
                skipDepth = 1
                return
            }
            // An `image` or `use` whose reference was stripped would still be
            // drawn: the Mac's decoder paints a broken-image box for it, where
            // the web paints nothing. So it goes, rather than its `href`.
            if SVGSanitizer.referenceElements.contains(elementName),
               !attributes.contains(where: { name, value in
                   (name == "href" || name == "xlink:href")
                       && SVGSanitizer.isSafeHref(value, element: elementName)
               }) {
                skipDepth = 1
                return
            }
            var tag = "<\(elementName)"
            let isRoot = stack.isEmpty
            if isRoot {
                tag += " xmlns=\"\(SVGSanitizer.svgNamespace)\" xmlns:xlink=\"\(SVGSanitizer.xlinkNamespace)\""
            }
            for name in attributes.keys.sorted() {
                guard let value = attributes[name],
                      let kept = keep(name: name, value: value, element: elementName)
                else { continue }
                tag += " \(name)=\"\(Self.escape(kept, attribute: true))\""
            }
            if isRoot, attributes["viewBox"] == nil,
               let w = SVGSanitizer.length(attributes["width"]),
               let h = SVGSanitizer.length(attributes["height"]) {
                tag += " viewBox=\"0 0 \(Self.number(w)) \(Self.number(h))\""
            }
            output += tag + ">"
            stack.append(.emitted(elementName))
            if elementName == "style" { styleText = "" }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            if skipDepth > 0 {
                skipDepth -= 1
                return
            }
            guard let frame = stack.popLast() else { return }
            guard case .emitted(let name) = frame else { return }
            if name == "style", let css = styleText {
                if SVGSanitizer.isSafeValue(css) { output += Self.escape(css, attribute: false) }
                styleText = nil
            }
            output += "</\(name)>"
            if stack.isEmpty { closedRoot = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text(String(decoding: CDATABlock, as: UTF8.self))
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            failed = true
        }

        private func text(_ string: String) {
            guard skipDepth == 0, !stack.isEmpty else { return }
            if styleText != nil {
                styleText? += string
            } else {
                output += Self.escape(string, attribute: false)
            }
        }

        private func fail(_ parser: XMLParser) {
            failed = true
            parser.abortParsing()
        }

        /// The value to write the attribute with, or nil to drop it.
        private func keep(name: String, value: String, element: String) -> String? {
            let lower = name.lowercased()
            if lower == "xmlns" || lower.hasPrefix("xmlns:") { return nil }
            if name.contains(":"), !SVGSanitizer.allowedPrefixedAttributes.contains(lower) { return nil }
            let local = lower.split(separator: ":").last.map(String.init) ?? lower
            if local.hasPrefix("on") { return nil }
            if local == "href" {
                return SVGSanitizer.isSafeHref(value, element: element) ? value : nil
            }
            // Animation targets and anything spelled like a resource: nothing
            // drawable needs them, and each is a way to name the outside world.
            if ["src", "base", "attributename", "requiredextensions"].contains(local) { return nil }
            if SVGSanitizer.isSafeValue(value) { return value }
            // A paint server outside the document fails to load in a browser
            // and paints nothing. Dropping the attribute instead would fall
            // back to the default, black, which is not what the web shows.
            return ["fill", "stroke"].contains(local) ? "none" : nil
        }

        static func escape(_ text: String, attribute: Bool) -> String {
            var escaped = ""
            escaped.reserveCapacity(text.count)
            for character in text {
                switch character {
                case "&": escaped += "&amp;"
                case "<": escaped += "&lt;"
                case ">": escaped += "&gt;"
                case "\"" where attribute: escaped += "&quot;"
                default: escaped.append(character)
                }
            }
            return escaped
        }

        static func number(_ value: CGFloat) -> String {
            let rounded = (Double(value) * 1000).rounded() / 1000
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        }
    }
}

/// Image bytes made ready for `UIImage(data:)` / `NSImage(data:)`.
///
/// Raster formats pass straight through. An SVG is sanitized first on both
/// platforms; the Mac then hands it to `NSImage`, which draws SVG itself, and
/// the phone, whose `UIImage` cannot, rasterizes it in `SVGRasterizer`'s
/// sandboxed web view to PNG. Either way every consumer downstream (the
/// thumbnail, pinch-to-peek, the viewer, the annotation editor) keeps working
/// on plain bytes.
enum DisplayableImageData {
    /// nil means "an SVG that could not be made safe or drawn", which callers
    /// treat exactly like a failed fetch: a retry tile, not a blank.
    static func prepare(_ data: Data) async -> Data? {
        guard SVGSanitizer.looksLikeSVG(data) else { return data }
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() as NSString
        if let hit = cache.object(forKey: key) { return hit as Data }
        let sanitized = await Task.detached(priority: .userInitiated) {
            SVGSanitizer.sanitize(data)
        }.value
        guard let sanitized else { return nil }
        #if os(iOS)
        guard let rendered = await SVGRasterizer.shared.png(for: sanitized) else { return nil }
        #else
        guard NSImage(data: sanitized.markup) != nil else { return nil }
        let rendered = sanitized.markup
        #endif
        // Failures are not cached: a render can lose to a timeout on a busy
        // device, and the retry tile should get a real second attempt.
        cache.setObject(rendered as NSData, forKey: key, cost: rendered.count)
        return rendered
    }

    struct Unrenderable: Error {}

    /// `prepare` for a throwing fetch path.
    static func prepared(_ data: Data) async throws -> Data {
        guard let shown = await prepare(data) else { throw Unrenderable() }
        return shown
    }

    private static let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
}

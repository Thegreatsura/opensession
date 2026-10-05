import XCTest
@testable import OS1

/// A transcript's images are mostly server-relative paths, because the
/// transcript is written for a web viewer sitting on the same origin. Nothing
/// about that is visible in the app until the picture doesn't appear, so these
/// pin the join.
final class ConversationImageURLTests: XCTestCase {
    private let base = URL(string: "https://os.example.dev")!

    func testRelativeMediaPathJoinsTheServer() {
        let url = OS1API.conversationImageURL(
            source: "/media?path=%2Fhome%2Fubuntu%2Fshot.png",
            base: base
        )
        XCTAssertEqual(
            url?.absoluteString,
            "https://os.example.dev/media?path=%2Fhome%2Fubuntu%2Fshot.png"
        )
    }

    func testRelativeVideoPathUsesTheSameMediaResolver() {
        let url = OS1API.conversationMediaURL(
            source: "/media?path=%2Fhome%2Fubuntu%2Fdemo.mp4",
            base: base
        )
        XCTAssertEqual(
            url?.absoluteString,
            "https://os.example.dev/media?path=%2Fhome%2Fubuntu%2Fdemo.mp4"
        )
    }

    func testRelativeApiPathJoinsTheServer() {
        let url = OS1API.conversationImageURL(
            source: "/api/sessions/os-1/transcript-image/e-1/0",
            base: base
        )
        XCTAssertEqual(url?.host, "os.example.dev")
        XCTAssertEqual(url?.path, "/api/sessions/os-1/transcript-image/e-1/0")
    }

    /// The bug this guards: `URL(string:)` accepts a relative path and hands
    /// back something with no scheme, which `URLRequest` cannot fetch — so the
    /// joined URL must come out absolute, not merely non-nil.
    func testJoinedURLIsAbsolute() {
        XCTAssertNil(URL(string: "/media?path=x")?.scheme)
        XCTAssertEqual(
            OS1API.conversationImageURL(source: "/media?path=x", base: base)?.scheme,
            "https"
        )
    }

    func testAbsoluteSourcesAreLeftAlone() {
        let remote = "https://cdn.example.com/a.png"
        XCTAssertEqual(
            OS1API.conversationImageURL(source: remote, base: base)?.absoluteString,
            remote
        )
    }

    /// A server that isn't configured yet has no base to join against; the
    /// caller turns nil into `APIError.badURL` rather than firing a request at
    /// a path.
    func testRelativeSourceWithoutAServerHasNoURL() {
        XCTAssertNil(OS1API.conversationImageURL(source: "/media?path=x", base: nil))
    }

    /// An SVG an agent wrote to disk and announced: the server serves it from
    /// /media like any picture, and it joins the same way. The bytes, not the
    /// URL, are what make it SVG (see `SVGImageTests`).
    func testLocalMediaSVGJoinsTheServer() {
        let url = OS1API.conversationImageURL(
            source: "/media?path=%2Ftmp%2Fchart.svg",
            base: base
        )
        XCTAssertEqual(url?.absoluteString, "https://os.example.dev/media?path=%2Ftmp%2Fchart.svg")
    }

    func testUploadedSVGJoinsTheServer() {
        let url = OS1API.conversationImageURL(
            source: "/media?path=%2Fhome%2Facme%2F.opensession%2Fuploads%2Fos-1%2Flogo.svg",
            base: base
        )
        XCTAssertEqual(url?.host, "os.example.dev")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertTrue(url?.absoluteString.hasSuffix("logo.svg") ?? false)
    }
}

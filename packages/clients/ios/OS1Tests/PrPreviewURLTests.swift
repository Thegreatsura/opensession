import XCTest
@testable import OS1

/// The PR preview link opens the feature under test: the session's recorded
/// route, else the deployment's configured landing route, else the root. The
/// rules are the web's (src/frontend/lib/preview-url.ts), so both clients
/// open the same page.
final class PrPreviewURLTests: XCTestCase {
    private func pr(_ json: String) throws -> PrDetails {
        try JSONDecoder().decode(PrDetails.self, from: Data(json.utf8))
    }

    private func session(_ json: String) throws -> Session {
        try JSONDecoder().decode(Session.self, from: Data(json.utf8))
    }

    func testDecodesDefaultPathAndPreviewPath() throws {
        let details = try pr(
            #"{"number":1,"staging":{"url":"https://pr-1.example.test","defaultPath":"/home","status":"Ready"}}"#
        )
        XCTAssertEqual(details.staging?.url, "https://pr-1.example.test")
        XCTAssertEqual(details.staging?.defaultPath, "/home")
        XCTAssertEqual(try session(#"{"id":"s","previewPath":"/settings?tab=a"}"#).previewPath, "/settings?tab=a")
    }

    func testOlderServerPayloadsStillDecode() throws {
        let details = try pr(#"{"number":1,"staging":{"url":"https://pr-1.example.test"}}"#)
        XCTAssertNil(details.staging?.defaultPath)
        XCTAssertNil(try session(#"{"id":"s"}"#).previewPath)
        XCTAssertEqual(
            details.staging?.href(previewPath: nil)?.absoluteString,
            "https://pr-1.example.test"
        )
    }

    func testRecordedRouteWinsOverConfiguredFallback() {
        let staging = PrStaging(url: "https://pr-1.example.test", defaultPath: "/home")
        XCTAssertEqual(
            staging.href(previewPath: "/settings")?.absoluteString,
            "https://pr-1.example.test/settings"
        )
    }

    func testConfiguredFallbackWithoutRecordedRoute() {
        let staging = PrStaging(url: "https://pr-1.example.test/", defaultPath: "/home")
        XCTAssertEqual(staging.href(previewPath: nil)?.absoluteString, "https://pr-1.example.test/home")
        // An empty recorded route is no route, as `||` treats it on the web.
        XCTAssertEqual(staging.href(previewPath: "")?.absoluteString, "https://pr-1.example.test/home")
    }

    func testNeitherOpensTheRoot() {
        let staging = PrStaging(url: "https://pr-1.example.test/", defaultPath: nil)
        XCTAssertEqual(staging.href(previewPath: nil)?.absoluteString, "https://pr-1.example.test/")
        XCTAssertEqual(staging.href(previewPath: "/")?.absoluteString, "https://pr-1.example.test/")
    }

    func testTrailingAndLeadingSlashesCollapse() {
        XCTAssertEqual(
            PrStaging.withPreviewPath("https://pr-1.example.test///", "//a/b"),
            "https://pr-1.example.test/a/b"
        )
        XCTAssertEqual(PrStaging.withPreviewPath("https://pr-1.example.test", "a"), "https://pr-1.example.test/a")
        XCTAssertEqual(PrStaging.withPreviewPath("https://pr-1.example.test/", "///"), "https://pr-1.example.test/")
    }

    func testQueryStringSurvives() {
        let staging = PrStaging(url: "https://pr-1.example.test/", defaultPath: "/home?tab=new")
        XCTAssertEqual(
            staging.href(previewPath: "/s/abc?mode=edit&x=1")?.absoluteString,
            "https://pr-1.example.test/s/abc?mode=edit&x=1"
        )
        XCTAssertEqual(staging.href(previewPath: nil)?.absoluteString, "https://pr-1.example.test/home?tab=new")
    }

    func testNoURLNoLink() {
        XCTAssertNil(PrStaging(url: nil, defaultPath: "/home").href(previewPath: "/a"))
    }
}

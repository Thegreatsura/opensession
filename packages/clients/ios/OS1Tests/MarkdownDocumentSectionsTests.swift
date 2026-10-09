import XCTest
@testable import OS1

final class MarkdownDocumentSectionsTests: XCTestCase {
    func testSplitsAtTopThreeHeadingLevels() {
        let text = "Lead.\n\n# Title\n\nIntro.\n\n## Part\n\nBody.\n\n### Detail\n\n#### Minor\n\nText."
        let sections = MarkdownDocumentSections.split(text)
        XCTAssertEqual(sections.map(\.level), [nil, 1, 2, 3])
        XCTAssertEqual(sections[0].text, "Lead.\n")
        XCTAssertTrue(sections[3].text.hasPrefix("### Detail"))
        XCTAssertTrue(sections[3].text.contains("#### Minor"))
    }

    func testHeadingsInsideFencesStayText() {
        let text = "## Real\n\n```sh\n# a comment\n## not a heading\n```\n\n~~~\n# also code\n~~~\n\nAfter."
        let sections = MarkdownDocumentSections.split(text)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].text, text)
    }

    func testRejectsNonHeadings() {
        XCTAssertNil(MarkdownDocumentSections.headingLevel("#hashtag"))
        XCTAssertNil(MarkdownDocumentSections.headingLevel("    # indented code"))
        XCTAssertNil(MarkdownDocumentSections.headingLevel("#### four"))
        XCTAssertEqual(MarkdownDocumentSections.headingLevel("   ## ok"), 2)
        XCTAssertEqual(MarkdownDocumentSections.headingLevel("#"), 1)
    }

    func testGapsOpenAboveHeadingsAndCloseUnderHeadingOnlySections() {
        let sections = MarkdownDocumentSections.split("# Title\n## Part\n\nBody.\n\n### Detail\n\nText.")
        XCTAssertEqual(sections.map(\.headingOnly), [true, false, false])
        XCTAssertEqual(MarkdownDocumentSections.gap(before: sections[0], after: nil), 0)
        XCTAssertEqual(MarkdownDocumentSections.gap(before: sections[1], after: sections[0]), 4)
        XCTAssertEqual(MarkdownDocumentSections.gap(before: sections[2], after: sections[1]), 12)
    }
}

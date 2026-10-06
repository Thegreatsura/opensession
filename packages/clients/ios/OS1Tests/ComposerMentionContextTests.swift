import SwiftUI
import XCTest
@testable import OS1

final class ComposerMentionContextTests: XCTestCase {
    func testFindsMentionAtBeginning() {
        let context = ComposerMentionContext.active(in: "@ken", caretUTF16Offset: 4)

        XCTAssertEqual(context?.query, "ken")
        XCTAssertEqual(context?.range, NSRange(location: 0, length: 4))
    }

    func testFindsMentionAtCaretBeforeFollowingText() {
        let text = "Ask @ses about this"
        let context = ComposerMentionContext.active(in: text, caretUTF16Offset: 8)

        XCTAssertEqual(context?.query, "ses")
        XCTAssertEqual(context?.range, NSRange(location: 4, length: 4))
    }

    func testIgnoresEmailAddressesAndClosedTokens() {
        XCTAssertNil(
            ComposerMentionContext.active(
                in: "hello@example.com",
                caretUTF16Offset: ("hello@example.com" as NSString).length
            )
        )
        XCTAssertNil(
            ComposerMentionContext.active(
                in: "Ask @Kent now",
                caretUTF16Offset: ("Ask @Kent now" as NSString).length
            )
        )
    }

    func testInsertionPreservesUnicodeAndFollowingText() {
        let text = "👋 Ask @se today"
        let caret = ("👋 Ask @se" as NSString).length
        let context = ComposerMentionContext.active(in: text, caretUTF16Offset: caret)
        let item = FileMention(
            display: "Session title",
            insert: "session:os-example",
            kind: "session"
        )

        let edit = context?.inserting(item, into: text)

        XCTAssertEqual(edit?.text, "👋 Ask @session:os-example  today")
        XCTAssertEqual(edit?.caretUTF16Offset, ("👋 Ask @session:os-example " as NSString).length)
    }

    /// The field's selection can run ahead of the text the palette reads, and
    /// arrive UTF-16 encoded. Past the end of a non-ASCII draft (an "Ask about
    /// this" quote carries a middle dot) that used to trap.
    func testASelectionFromANewerCopyOfTheDraftNeverTraps() {
        let text = "> You should know \u{00b7} the retry"
        let newer = NSMutableString(string: text + " and what came next") as String
        let stale = TextSelection(insertionPoint: newer.endIndex)
        XCTAssertNil(ComposerMentionContext.caretUTF16Offset(in: text, selection: stale))
        XCTAssertNil(ComposerMentionContext.active(in: text, selection: stale))

        let inside = newer.utf16.index(newer.utf16.startIndex, offsetBy: 5)
        XCTAssertEqual(ComposerMentionContext.caretUTF16Offset(in: text, selection: TextSelection(insertionPoint: inside)), 5)
        XCTAssertEqual(
            ComposerMentionContext.caretUTF16Offset(in: text, selection: TextSelection(insertionPoint: text.endIndex)),
            (text as NSString).length
        )
        let mention = text + " @ka"
        XCTAssertEqual(
            ComposerMentionContext.active(in: mention, selection: TextSelection(insertionPoint: mention.endIndex))?.query,
            "ka"
        )
    }
}

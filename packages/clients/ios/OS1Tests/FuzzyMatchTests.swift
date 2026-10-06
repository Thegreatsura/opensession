import XCTest
@testable import OS1

/// Parity fixtures for the server's `shared/fuzzy-match.test.ts`: the same
/// inputs must score the same here, so a query ranks alike in every client.
final class FuzzyMatchTests: XCTestCase {
    func testRanksExactPrefixWordPrefixThenSubstring() {
        XCTAssertEqual(FuzzyMatch.score("release", "Release"), 100)
        XCTAssertEqual(FuzzyMatch.score("rel", "Release work"), 90)
        XCTAssertEqual(FuzzyMatch.score("work", "Release work"), 80)
        XCTAssertEqual(FuzzyMatch.score("lease", "Release work"), 70)
    }

    func testForgivesATypoInLongerTerms() {
        XCTAssertEqual(FuzzyMatch.score("relase", "Release work"), 40)
        XCTAssertEqual(FuzzyMatch.score("wrokspace", "Workspace cleanup"), 40)
        XCTAssertGreaterThan(FuzzyMatch.score("billng audit", "Billing audit"), 0)
    }

    func testAnAdjacentTranspositionIsOneEdit() {
        // "wrokspace" is one transposition away; a plain Levenshtein would
        // need two edits and, at a budget of two, still pass. "wrkospace"
        // has the transposition and a second slip: still within budget.
        XCTAssertEqual(FuzzyMatch.score("wrkospace", "workspace"), 30)
        // Three edits is past the budget for a nine-letter term.
        XCTAssertEqual(FuzzyMatch.score("wrkospcae", "workspace rows"), 0)
    }

    func testKeepsShortTermsStrict() {
        XCTAssertEqual(FuzzyMatch.score("cat", "cut"), 0)
        XCTAssertEqual(FuzzyMatch.score("api", "apple"), 0)
    }

    func testMatchesAbbreviationsInsideOneWord() {
        XCTAssertEqual(FuzzyMatch.score("wksp", "workspace"), 20)
    }

    func testNeedsEveryTermToLandSomewhere() {
        XCTAssertEqual(FuzzyMatch.score("release billing", "Release work"), 0)
        XCTAssertGreaterThan(FuzzyMatch.score("work release", "Release work"), 0)
        // The mean of the per-term scores, rounded half up as in JavaScript.
        XCTAssertEqual(FuzzyMatch.score("relase work", "Release work"), 50)
    }

    func testIgnoresCaseAndAccentsAndAnEmptyQueryMatchesAll() {
        XCTAssertEqual(FuzzyMatch.score("jaap", "Jääp"), 100)
        XCTAssertEqual(FuzzyMatch.score("CAFE", "Café"), 100)
        XCTAssertEqual(FuzzyMatch.score("", "anything"), 1)
        XCTAssertEqual(FuzzyMatch.score("   ", "anything"), 1)
        XCTAssertEqual(FuzzyMatch.score("x", ""), 0)
    }

    func testBestTakesTheStrongestField() {
        XCTAssertEqual(FuzzyMatch.best("audit", in: [nil, "Billing", "audit/billing"]), 90)
        XCTAssertEqual(FuzzyMatch.best("nothing", in: ["a", nil]), 0)
    }

    func testPunctuationInsideATermIsAPhraseOfAdjacentWords() {
        XCTAssertEqual(FuzzyMatch.score("pi-durable", "Explore Pi Durable objects"), 60)
        XCTAssertGreaterThan(FuzzyMatch.score("pi-durable", "pi_durable"), 0)
        XCTAssertGreaterThan(FuzzyMatch.score("pi-durable", "Pi/Durable worker"), 0)
        XCTAssertGreaterThan(FuzzyMatch.score("pi-durable", "pidurable"), 0)
        // Both words, but not adjacent or not in order: not the phrase.
        XCTAssertEqual(FuzzyMatch.score("pi-durable", "Durable Pi"), 0)
        XCTAssertEqual(FuzzyMatch.score("pi-durable", "Pi release, durable queue"), 0)
        XCTAssertEqual(FuzzyMatch.score("s-desk", "Voice captions for the Desk"), 0)
        // The phrase starts at a word boundary.
        XCTAssertEqual(FuzzyMatch.score("pi-durable", "api durable"), 0)
        // Edge punctuation is not a phrase.
        XCTAssertEqual(FuzzyMatch.score("pi-", "Pi release"), 60)
    }

    func testAPreparedQueryScoresLikeTheOneShotAcrossManyTexts() {
        let texts = [
            "Release work", "Relase notes", "workspace", "Explore Pi Durable objects",
            "Durable Pi", "Café", "Billing audit", "audit/billing", "",
        ]
        for query in ["release", "relase work", "wksp", "pi-durable", "cafe", "billng audit"] {
            let prepared = FuzzyMatch.Query(query)
            for text in texts {
                // Twice, so the second pass reads the per-word cache.
                for _ in 0..<2 {
                    XCTAssertEqual(
                        prepared.score(FuzzyMatch.Text(text)),
                        FuzzyMatch.score(query, text),
                        "\(query) / \(text)"
                    )
                }
            }
        }
    }
}

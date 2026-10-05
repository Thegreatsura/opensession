import XCTest
@testable import OS1

/// Mirrors `src/frontend/lib/mermaid-repair.test.ts` (the ER half) so the two
/// ports cannot drift, then draws the fixtures through the real renderer.
final class MermaidRepairTests: XCTestCase {
    func testAttributeNamedLikeAKeyMarkerInAnyCase() {
        let source = """
        erDiagram
          ITEM {
            string pk "ORG#orgID"
            string sk
            string Uk PK
          }
        """
        XCTAssertEqual(MermaidRepair.quoteErAttributes(source), """
        erDiagram
          ITEM {
            string `pk` "ORG#orgID"
            string sk
            string `Uk` PK
          }
        """)
    }

    func testTypeWithPunctuationTheGrammarRejects() {
        XCTAssertEqual(
            MermaidRepair.quoteErAttributes("erDiagram\n  T {\n    Vec<Track> tracks\n  }"),
            "erDiagram\n  T {\n    `Vec<Track>` tracks\n  }"
        )
    }

    func testRelationshipsAndValidAttributesAreLeftAlone() {
        XCTAssertNil(MermaidRepair.quoteErAttributes(MermaidFixtures.validER))
        XCTAssertNil(MermaidRepair.quoteErAttributes("""
        erDiagram
          A ||--o{ B : "pk to fk"
          B {
            int id PK
            string[] tags
            string `fk`
            %% string pk
            "quoted" name
          }
        """))
    }

    func testOtherDiagramTypesAreNotTouched() {
        XCTAssertNil(MermaidRepair.quoteErAttributes("flowchart LR\n  A {\n  pk\n  }"))
        XCTAssertNil(MermaidRepair.repairedSource(MermaidFixtures.sequence))
        XCTAssertNil(MermaidRepair.repairedSource("classDiagram\n  class Foo {\n    Vec<T> pk\n  }"))
        XCTAssertNil(MermaidRepair.repairedSource("erDiagrams\n  A {\n    string pk\n  }"))
    }

    func testRepairRoutesEachTypeAndSkipsTheHeaderDirective() {
        XCTAssertEqual(
            MermaidRepair.repairedSource("erDiagram\n  A {\n    string fk\n  }"),
            "erDiagram\n  A {\n    string `fk`\n  }"
        )
        XCTAssertEqual(
            MermaidRepair.repairedSource("%%{init: {}}%%\n\nerDiagram\n  A {\n    string fk\n  }"),
            "%%{init: {}}%%\n\nerDiagram\n  A {\n    string `fk`\n  }"
        )
        XCTAssertNil(MermaidRepair.repairedSource("sequenceDiagram\n  A->>B: pk"))
    }

    func testNonASCIIWordsMatchTheWebLexer() {
        // À-￿ is a word character to mermaid; an emoji is two UTF-16
        // code units in that range, so it is a word too.
        XCTAssertNil(MermaidRepair.quoteErAttributes("erDiagram\n  A {\n    string café\n    string 🎵\n  }"))
        XCTAssertEqual(
            MermaidRepair.quoteErAttributes("erDiagram\n  A {\n    Map<K,V> café\n  }"),
            "erDiagram\n  A {\n    `Map<K,V>` café\n  }"
        )
    }

    // MARK: - Through the bundled renderer

    @MainActor
    func testRepairedERFixturesDrawInsteadOfFallingBackToCode() async throws {
        let renderer = MermaidRenderer.shared
        for source in [MermaidFixtures.keyNamedAttributes, MermaidFixtures.genericType] {
            let diagram = await renderer.diagram(source: source, dark: false, background: "#ffffff")
            XCTAssertNotNil(diagram, "repaired ER fixture fell back to code:\n\(source)")
            XCTAssertGreaterThan(diagram?.png.count ?? 0, 0)
        }
    }

    @MainActor
    func testValidDiagramsStillDrawAndBrokenOnesStillFallBack() async throws {
        let renderer = MermaidRenderer.shared
        for source in [MermaidFixtures.validER, MermaidFixtures.sequence] {
            let diagram = await renderer.diagram(source: source, dark: true, background: "#000000")
            XCTAssertNotNil(diagram, "valid fixture failed to draw:\n\(source)")
        }
        let broken = await renderer.diagram(
            source: "erDiagram\n  A {\n    string pk\n",
            dark: true,
            background: "#000000"
        )
        XCTAssertNil(broken)
    }
}

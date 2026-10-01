import { describe, expect, test } from "bun:test";
import {
  isFlowchart,
  quoteErAttributes,
  quoteFlowchartLabels,
  repairMermaidSource,
} from "./mermaid-repair";

describe("isFlowchart", () => {
  test("flowchart and graph headers, past a leading init directive", () => {
    expect(isFlowchart("flowchart LR\n  A --> B")).toBe(true);
    expect(isFlowchart("  graph TD\n  A --> B")).toBe(true);
    expect(isFlowchart("%%{init: {}}%%\nflowchart TB\n  A")).toBe(true);
  });

  test("other diagram types are not touched", () => {
    expect(isFlowchart("sequenceDiagram\n  A->>B: hi")).toBe(false);
    expect(isFlowchart("classDiagram\n  class Foo {\n  +bar()\n  }")).toBe(
      false,
    );
    expect(isFlowchart("stateDiagram-v2\n  [*] --> Idle")).toBe(false);
  });
});

describe("quoteFlowchartLabels", () => {
  test("an edge label starting with @, which mermaid reads as an edge id", () => {
    expect(quoteFlowchartLabels("flowchart LR\n  wh -->|@mention| m")).toBe(
      'flowchart LR\n  wh -->|"@mention"| m',
    );
  });

  test("a bracket label carrying parentheses", () => {
    expect(quoteFlowchartLabels("graph TD\n  A[foo (bar)] --> B")).toBe(
      'graph TD\n  A["foo (bar)"] --> B',
    );
  });

  test("every node shape keeps its own delimiters around the quoted text", () => {
    const src = [
      "flowchart LR",
      "  a(round: x) --> b([stadium: x])",
      "  c[[sub: x]] --> d[(db: x)]",
      "  e((circle: x)) --> f>flag: x]",
      "  g{dia: x} --> h{{hex: x}}",
      "  i[/para: x/] --> j[\\alt: x\\]",
      "  k[/trap: x\\] --> l(((dbl: x)))",
    ].join("\n");
    expect(quoteFlowchartLabels(src)).toBe(
      [
        "flowchart LR",
        '  a("round: x") --> b(["stadium: x"])',
        '  c[["sub: x"]] --> d[("db: x")]',
        '  e(("circle: x")) --> f>"flag: x"]',
        '  g{"dia: x"} --> h{{"hex: x"}}',
        '  i[/"para: x"/] --> j[\\"alt: x"\\]',
        '  k[/"trap: x"\\] --> l((("dbl: x")))',
      ].join("\n"),
    );
  });

  test("labels already quoted, markdown strings and entity codes stay as written", () => {
    const src = [
      "flowchart LR",
      '  A["already (quoted)"] -->|"@x"| B["`**md**`"]',
      "  B --> C[#64;mention]",
    ].join("\n");
    expect(quoteFlowchartLabels(src)).toBe(
      [
        "flowchart LR",
        '  A["already (quoted)"] -->|"@x"| B["`**md**`"]',
        '  B --> C["#64;mention"]',
      ].join("\n"),
    );
  });

  test("arrows, chained nodes, classes and subgraph titles survive", () => {
    const src = [
      "flowchart TD",
      "  subgraph one [Group (a)]",
      "    direction LR",
      "    a-->b & c",
      "    a -- text --> d:::hot",
      "    a ==> e",
      "    a -.-> f",
      "  end",
      "  classDef hot fill:#f00",
      "  style a fill:#fff,stroke:#333",
      '  click a "https://example.com" _blank',
      "  linkStyle 0 stroke:#f00",
      "  %% a comment [with brackets]",
    ].join("\n");
    expect(quoteFlowchartLabels(src)).toBe(
      src.replace("[Group (a)]", '["Group (a)"]'),
    );
  });

  test("a label with <br/> line breaks quotes cleanly", () => {
    expect(
      quoteFlowchartLabels(
        "flowchart LR\n  GH[GitHub App webhook<br/>POST /github/webhook] --> x",
      ),
    ).toBe(
      'flowchart LR\n  GH["GitHub App webhook<br/>POST /github/webhook"] --> x',
    );
  });

  test("a label containing its own delimiter is left alone", () => {
    const src = "flowchart LR\n  A[x] y] --> B";
    // `A[x]` quotes; the stray ` y]` is not a label and stays put.
    expect(quoteFlowchartLabels(src)).toBe('flowchart LR\n  A["x"] y] --> B');
    expect(quoteFlowchartLabels("flowchart LR\n  A(f(x)) --> B")).toBe(null);
  });

  test("null when nothing needs quoting or the diagram is not a flowchart", () => {
    expect(quoteFlowchartLabels("flowchart LR\n  A --> B")).toBe(null);
    expect(quoteFlowchartLabels("sequenceDiagram\n  A->>B: hi (there)")).toBe(
      null,
    );
  });
});

describe("quoteErAttributes", () => {
  test("an attribute named like a key marker, in any case", () => {
    const src = [
      "erDiagram",
      "  ITEM {",
      '    string pk "ORG#orgID"',
      "    string sk",
      "    string Uk PK",
      "  }",
    ].join("\n");
    expect(quoteErAttributes(src)).toBe(
      [
        "erDiagram",
        "  ITEM {",
        '    string `pk` "ORG#orgID"',
        "    string sk",
        "    string `Uk` PK",
        "  }",
      ].join("\n"),
    );
  });

  test("a type with punctuation the attribute grammar rejects", () => {
    expect(
      quoteErAttributes("erDiagram\n  T {\n    Vec<Track> tracks\n  }"),
    ).toBe("erDiagram\n  T {\n    `Vec<Track>` tracks\n  }");
  });

  test("relationships and valid attributes are left alone", () => {
    const src = [
      "erDiagram",
      '  A ||--o{ B : "pk to fk"',
      "  B {",
      "    int id PK",
      "    string[] tags",
      "    string `fk`",
      "  }",
    ].join("\n");
    expect(quoteErAttributes(src)).toBe(null);
  });

  test("other diagram types are not ER diagrams", () => {
    expect(quoteErAttributes("flowchart LR\n  A {\n  pk\n  }")).toBe(null);
  });
});

describe("repairMermaidSource", () => {
  test("routes each diagram type to its own repair", () => {
    expect(repairMermaidSource("graph TD\n  A[f (x)]")).toBe(
      'graph TD\n  A["f (x)"]',
    );
    expect(repairMermaidSource("erDiagram\n  A {\n    string fk\n  }")).toBe(
      "erDiagram\n  A {\n    string `fk`\n  }",
    );
    expect(repairMermaidSource("sequenceDiagram\n  A->>B: pk")).toBe(null);
  });
});

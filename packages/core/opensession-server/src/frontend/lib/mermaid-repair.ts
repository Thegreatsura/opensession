/**
 * Second chance for a diagram mermaid refuses. Models write labels the way
 * people read them, and mermaid's grammars read some of that as syntax:
 *
 * - Flowcharts: `A[foo (bar)]` or `-->|@mention|`, where `(` opens a node
 *   and `@` starts an edge id. Quoting the label (`A["foo (bar)"]`) is the
 *   documented fix.
 * - ER diagrams: an attribute named `pk`, `fk` or `uk` (any case) lexes as a
 *   key marker, and a type like `Vec<Track>` is not an attribute word.
 *   Backticks (`` `pk` ``) make either one a plain word.
 *
 * Neither changes what renders, so when the source as written does not
 * parse, mermaid.ts retries it repaired. Pure text, no DOM: this runs before
 * mermaid is even loaded for the retry. Other diagram types use brackets for
 * their own grammar (class members, state descriptions) and are left alone.
 */

/** Node bracket pairs, longest opener first so `[[` wins over `[`. The closer list
 *  covers the trapezoids, whose opener and closer slashes may differ. */
const NODE_BRACKETS: ReadonlyArray<{ open: string; close: readonly string[] }> =
  [
    { open: "(((", close: [")))"] },
    { open: "((", close: ["))"] },
    { open: "([", close: ["])"] },
    { open: "[(", close: [")]"] },
    { open: "[[", close: ["]]"] },
    { open: "[/", close: ["/]", "\\]"] },
    { open: "[\\", close: ["\\]", "/]"] },
    { open: "{{", close: ["}}"] },
    { open: "[", close: ["]"] },
    { open: "(", close: [")"] },
    { open: "{", close: ["}"] },
    { open: ">", close: ["]"] },
  ];

/** A node id: word characters, dashes allowed inside (`my-node`) but not at
 *  the end, so the `--` of an arrow never reads as an id before `>`. */
const NODE_ID = /[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*/y;

const OPENER_CHARS = new Set(["(", "[", "{", ">"]);

/** Lines whose brackets are not node labels. */
const DIRECTIVE = /^\s*(%%|click\b|style\b|classDef\b|class\b|linkStyle\b)/;

/** The diagram header: the first line that is not blank or a directive. */
function headerLine(src: string): string {
  const first = src.split("\n").find((line) => {
    const t = line.trim();
    return t && !t.startsWith("%%");
  });
  return first?.trim() ?? "";
}

/** True when the diagram is a flowchart (or its `graph` alias). */
export function isFlowchart(src: string): boolean {
  return /^(flowchart|graph)\b/.test(headerLine(src));
}

/** The label's delimiter must not appear inside it: `A[x] y]` is not one
 *  node, and nested brackets are a different (already quoted, or broken
 *  beyond this pass) node. Text carrying a quote is left alone too: it is
 *  either already quoted or would need escaping this pass does not do. */
function labelIsQuotable(text: string, open: string, close: string): boolean {
  if (!text.trim() || text.includes('"') || text.includes("\n")) return false;
  const forbidden = new Set([...open, ...close]);
  for (const ch of text) if (forbidden.has(ch)) return false;
  return true;
}

function quoteNodeLabels(line: string): string {
  let out = "";
  let i = 0;
  while (i < line.length) {
    NODE_ID.lastIndex = i;
    const id = NODE_ID.exec(line);
    if (!id) {
      out += line[i];
      i += 1;
      continue;
    }
    // An id preceded by a word or arrow character is the tail of something
    // else (`-->B` handled by the arrow branch, `a.b` by dotted ids).
    const prev = i > 0 ? line[i - 1] : "";
    if (/[\w.-]/.test(prev)) {
      out += id[0];
      i += id[0].length;
      continue;
    }
    let j = i + id[0].length;
    while (line[j] === " " || line[j] === "\t") j += 1;
    const bracket = OPENER_CHARS.has(line[j] ?? "")
      ? NODE_BRACKETS.find((s) => line.startsWith(s.open, j))
      : undefined;
    if (!bracket) {
      out += line.slice(i, j);
      i = j;
      continue;
    }
    const start = j + bracket.open.length;
    let matched: { close: string; end: number } | null = null;
    for (const close of bracket.close) {
      const end = line.indexOf(close, start);
      if (end !== -1 && (!matched || end < matched.end))
        matched = { close, end };
    }
    if (!matched) {
      out += line.slice(i, start);
      i = start;
      continue;
    }
    const text = line.slice(start, matched.end);
    const after = matched.end + matched.close.length;
    out += labelIsQuotable(text, bracket.open, matched.close)
      ? `${line.slice(i, start)}"${text}"${matched.close}`
      : line.slice(i, after);
    i = after;
  }
  return out;
}

/** `-->|text|` edge labels. A label carrying a quote is already quoted. */
function quoteEdgeLabels(line: string): string {
  return line.replace(/\|([^|"\n]+)\|/g, (m, text: string) =>
    text.trim() ? `|"${text}"|` : m,
  );
}

/**
 * The flowchart with every unquoted node and edge label quoted, or null when
 * the source is not a flowchart or nothing needed quoting (so the caller
 * knows a retry would be pointless).
 */
export function quoteFlowchartLabels(src: string): string | null {
  if (!isFlowchart(src)) return null;
  const lines = src.split("\n");
  const first = lines.findIndex((line) => /^\s*(flowchart|graph)\b/.test(line));
  const repaired = lines.map((line, index) => {
    if (index <= first || DIRECTIVE.test(line)) return line;
    return quoteEdgeLabels(quoteNodeLabels(line));
  });
  const out = repaired.join("\n");
  return out === src ? null : out;
}

/** What mermaid's ER lexer accepts as a bare attribute type or name. */
const ER_ATTRIBUTE_WORD =
  /^[*A-Za-z_\u00C0-\uFFFF][A-Za-z0-9\-_[\]().,\u00C0-\uFFFF*]*$/;
const ER_KEY = /^(pk|fk|uk)$/i;

/** Backtick-quote a type or name the ER lexer would not read as a word. */
function quoteErWord(word: string): string {
  if (word.includes("`")) return word;
  return ER_KEY.test(word) || !ER_ATTRIBUTE_WORD.test(word)
    ? `\`${word}\``
    : word;
}

/**
 * The ER diagram with every attribute type and name that mermaid would read
 * as syntax wrapped in backticks, or null when the source is not an ER
 * diagram or nothing needed quoting. Only the leading `type name` pair of a
 * line inside an entity's `{ ... }` block is touched: keys and the quoted
 * comment after them already parse.
 */
export function quoteErAttributes(src: string): string | null {
  if (!/^erDiagram\b/.test(headerLine(src))) return null;
  let inBlock = false;
  const repaired = src.split("\n").map((line) => {
    const t = line.trim();
    if (!inBlock) {
      if (t.endsWith("{") && !t.startsWith("%%")) inBlock = true;
      return line;
    }
    if (t.startsWith("}")) {
      inBlock = false;
      return line;
    }
    const attr = /^(\s*)(\S+)(\s+)(\S+)(.*)$/.exec(line);
    if (!attr || t.startsWith("%%") || attr[2].startsWith('"')) return line;
    const [, indent, type, gap, name, rest] = attr;
    return `${indent}${quoteErWord(type)}${gap}${quoteErWord(name)}${rest}`;
  });
  const out = repaired.join("\n");
  return out === src ? null : out;
}

/** The repaired source for any diagram type this module knows, or null. */
export function repairMermaidSource(src: string): string | null {
  return quoteFlowchartLabels(src) ?? quoteErAttributes(src);
}

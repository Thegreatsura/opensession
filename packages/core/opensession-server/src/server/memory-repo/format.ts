/**
 * Agent Memory Repo file format (https://github.com/AgentMemoryRepo/agentmemoryrepo).
 *
 * Pure parsing and rendering. Nothing here touches git or the filesystem.
 *
 * - A memory repository is a folder of Markdown notes (plus any other files).
 * - In a Markdown note, each entry is a top-level bullet on ONE line, with
 *   optional metadata at the end: `[key: value; key: value]`. Several
 *   trailing groups are allowed and merge (`[source: a] [source: b]`).
 * - `[[path]]` links between files. Paths start at the memory root, and
 *   Markdown targets omit `.md`.
 * - `MEMORY.md` is the entry point. Entries above its `## Index` heading are
 *   loaded by every session ("pinned"); the Index lists links.
 *
 * Parsing is lenient: anything that is not an entry is prose, kept verbatim
 * and never rewritten. Rendering an unchanged file reproduces it byte for byte.
 */

export const ENTRY_POINT = "MEMORY.md";

/** Metadata keys Open Session writes, in the order it writes them. */
export const KNOWN_META_KEYS = [
  "id",
  "kind",
  "source",
  "by",
  "via",
  "added",
  "updated",
  "confirmed",
  "expires",
  "tags",
  "supersedes",
] as const;

export type MemoryMeta = Record<string, string[]>;

export interface ParsedEntry {
  /** 0-based line index in the file. */
  line: number;
  /** The entry text without the bullet marker and trailing metadata. */
  text: string;
  meta: MemoryMeta;
  /** The bullet marker as written ("-" or "*"). */
  marker: string;
  /** True when the entry sits above `## Index` in a MEMORY.md file. */
  pinned: boolean;
}

export interface FormatProblem {
  line: number;
  message: string;
}

export interface ParsedMemoryFile {
  path: string;
  lines: string[];
  entries: ParsedEntry[];
  problems: FormatProblem[];
  /** Line index of the `## Index` heading, when the file is an entry point. */
  indexLine: number;
}

const BULLET = /^([-*])\s+(.*\S)\s*$/;
const META_KEY = /^[A-Za-z][A-Za-z0-9_-]*$/;
const INDEX_HEADING = /^#{1,6}\s+index\s*$/i;

export function isMarkdownPath(path: string): boolean {
  return /\.(md|markdown)$/i.test(path);
}

export function isEntryPoint(path: string): boolean {
  return path === ENTRY_POINT || path.endsWith(`/${ENTRY_POINT}`);
}

/**
 * Split a trailing metadata group off a line. Returns null when the line does
 * not end in a bracket group, "invalid" when it ends in one that looks like
 * metadata but does not parse.
 */
function splitTrailingGroup(
  value: string,
): { rest: string; pairs: Array<[string, string]> } | null | "invalid" {
  if (!value.endsWith("]") || value.endsWith("]]")) return null;
  // Find the matching "[" for the final "]", ignoring "[[" link openers.
  let depth = 0;
  let start = -1;
  for (let i = value.length - 1; i >= 0; i--) {
    const ch = value[i];
    if (ch === "]") depth++;
    else if (ch === "[") {
      depth--;
      if (depth === 0) {
        start = i;
        break;
      }
    }
  }
  if (start < 0 || value[start - 1] === "[") return null;
  const inner = value.slice(start + 1, -1);
  if (!inner.includes(":")) return null;
  const segments = inner.split(";").map((part) => part.trim());
  const pairs: Array<[string, string]> = [];
  let parsed = 0;
  for (const segment of segments) {
    if (!segment) continue;
    const colon = segment.indexOf(":");
    const key = colon > 0 ? segment.slice(0, colon).trim() : "";
    if (colon > 0 && META_KEY.test(key)) {
      parsed++;
      pairs.push([key.toLowerCase(), segment.slice(colon + 1).trim()]);
    } else {
      // `[note: see http://x]` style text is fine; a group where some
      // segments are key/value and others are not is a malformed group.
      return parsed > 0 || segments.length > 1 ? "invalid" : null;
    }
  }
  if (!pairs.length) return null;
  return { rest: value.slice(0, start).trimEnd(), pairs };
}

/** Parse one bullet's body into text and merged metadata. */
export function parseEntryBody(
  body: string,
): { text: string; meta: MemoryMeta } | { error: string } {
  let rest = body;
  const groups: Array<Array<[string, string]>> = [];
  for (;;) {
    const group = splitTrailingGroup(rest);
    if (group === "invalid")
      return {
        error:
          "Metadata must be `[key: value; key: value]` with a word key before each colon.",
      };
    if (!group) break;
    groups.unshift(group.pairs);
    rest = group.rest;
  }
  const meta: MemoryMeta = {};
  for (const pairs of groups) {
    for (const [key, value] of pairs) {
      if (!value) continue;
      (meta[key] ??= []).push(value);
    }
  }
  return { text: rest.trim(), meta };
}

export function parseMemoryFile(path: string, text: string): ParsedMemoryFile {
  const lines = text.split("\n");
  const entryPoint = isEntryPoint(path);
  const indexLine = entryPoint
    ? lines.findIndex((line) => INDEX_HEADING.test(line.trim()))
    : -1;
  const entries: ParsedEntry[] = [];
  const problems: FormatProblem[] = [];
  let inFence = false;
  lines.forEach((line, index) => {
    if (/^\s*(```|~~~)/.test(line)) inFence = !inFence;
    if (inFence) return;
    const match = BULLET.exec(line);
    if (!match) return;
    const parsed = parseEntryBody(match[2]);
    if ("error" in parsed) {
      problems.push({ line: index, message: parsed.error });
      return;
    }
    if (!parsed.text) return;
    // A bullet that is only a link is an index line, not a memory.
    if (/^\[\[[^\]]+\]\]$/.test(parsed.text)) return;
    entries.push({
      line: index,
      text: parsed.text,
      meta: parsed.meta,
      marker: match[1],
      pinned: entryPoint && (indexLine < 0 || index < indexLine),
    });
  });
  return { path, lines, entries, problems, indexLine };
}

/** Values cannot contain the group syntax or a line break. */
export function cleanMetaValue(value: string): string {
  return value
    .replace(/[\r\n]+/g, " ")
    .replace(/;/g, ",")
    .replace(/\]/g, ")")
    .replace(/\[/g, "(")
    .trim();
}

/** Entry text is one line. A trailing bracket group would read as metadata. */
export function cleanEntryText(text: string): string {
  let clean = text.replace(/\s*[\r\n]+\s*/g, " ").trim();
  if (clean.endsWith("]") && !clean.endsWith("]]")) clean = `${clean}.`;
  return clean;
}

export function renderEntry(
  text: string,
  meta: MemoryMeta,
  marker = "-",
): string {
  const keys = [
    ...KNOWN_META_KEYS.filter((key) => meta[key]?.length),
    ...Object.keys(meta)
      .filter(
        (key) =>
          !(KNOWN_META_KEYS as readonly string[]).includes(key) &&
          meta[key]?.length,
      )
      .sort(),
  ];
  const pairs = keys.flatMap((key) =>
    meta[key]!.map((value) => cleanMetaValue(value))
      .filter(Boolean)
      .map((value) => `${key}: ${value}`),
  );
  const body = cleanEntryText(text);
  return pairs.length
    ? `${marker} ${body} [${pairs.join("; ")}]`
    : `${marker} ${body}`;
}

export function firstMeta(meta: MemoryMeta, key: string): string | undefined {
  return meta[key]?.[0];
}

/** Every `[[path]]` target in a text, as written. */
export function extractLinks(text: string): string[] {
  const out: string[] = [];
  for (const match of text.matchAll(/\[\[([^\]\n]+)\]\]/g)) {
    const target = match[1].trim();
    if (target) out.push(target);
  }
  return out;
}

/** Resolve a link target to a repository path (Markdown targets omit `.md`). */
export function linkTargetPath(target: string): string {
  const clean = target.replace(/^\/+/, "").split("#")[0].trim();
  if (!clean) return clean;
  return /\.[A-Za-z0-9]+$/.test(clean) ? clean : `${clean}.md`;
}

/** The link target for a repository path. */
export function linkFor(path: string): string {
  return path.replace(/\.md$/i, "");
}

/** Replace one line. Returns the new file text. */
export function replaceLine(
  file: ParsedMemoryFile,
  line: number,
  next: string | null,
): string {
  const lines = [...file.lines];
  if (next === null) {
    lines.splice(line, 1);
    // Do not leave two blank lines where the entry was.
    if (
      line > 0 &&
      line < lines.length &&
      !lines[line - 1].trim() &&
      !lines[line].trim()
    )
      lines.splice(line, 1);
  } else lines[line] = next;
  return lines.join("\n");
}

/**
 * Insert an entry. In an entry point it goes into the pinned region (above
 * `## Index`), otherwise at the end of the file.
 */
export function appendEntry(
  path: string,
  text: string | undefined,
  entry: string,
  opts: { title?: string } = {},
): string {
  if (!text?.trim()) {
    const title =
      opts.title ?? (isEntryPoint(path) ? "# Memory" : `# ${titleFor(path)}`);
    return isEntryPoint(path)
      ? `${title}\n\n${entry}\n\n## Index\n`
      : `${title}\n\n${entry}\n`;
  }
  const file = parseMemoryFile(path, text);
  const lines = [...file.lines];
  if (file.indexLine >= 0) {
    let at = file.indexLine;
    while (at > 0 && !lines[at - 1].trim()) at--;
    if (at > 0 && /^#/.test(lines[at - 1].trim())) {
      lines.splice(at, 0, "", entry);
    } else {
      lines.splice(at, 0, entry);
    }
    // Keep one blank line before the Index heading.
    const heading = lines.findIndex((line) => INDEX_HEADING.test(line.trim()));
    if (heading > 0 && lines[heading - 1].trim()) lines.splice(heading, 0, "");
    return lines.join("\n");
  }
  while (lines.length && !lines[lines.length - 1].trim()) lines.pop();
  lines.push(entry);
  return `${lines.join("\n")}\n`;
}

/** Add `- [[target]]` under `## Index` when no line links there yet. */
export function ensureIndexLink(
  text: string | undefined,
  target: string,
): string {
  const base = text?.trim() ? text : "# Memory\n\n## Index\n";
  if (
    extractLinks(base).some((link) => linkFor(linkTargetPath(link)) === target)
  )
    return base;
  const lines = base.split("\n");
  let heading = lines.findIndex((line) => INDEX_HEADING.test(line.trim()));
  if (heading < 0) {
    while (lines.length && !lines[lines.length - 1].trim()) lines.pop();
    lines.push("", "## Index");
    heading = lines.length - 1;
  }
  let at = heading + 1;
  let next = at;
  while (next < lines.length && /^\s*$/.test(lines[next])) next++;
  const link = `- [[${target}]]`;
  if (next < lines.length && /^[-*]\s/.test(lines[next])) {
    // Alphabetical among the existing links, so the order never depends on
    // which file was written first; a hand-ordered list is left as it is.
    at = next;
    while (
      at < lines.length &&
      /^[-*]\s/.test(lines[at]) &&
      lines[at].localeCompare(link) <= 0
    )
      at++;
  }
  lines.splice(at, 0, link);
  const joined = lines.join("\n");
  return joined.endsWith("\n") ? joined : `${joined}\n`;
}

export function titleFor(path: string): string {
  const base = (path.split("/").pop() || path).replace(/\.md$/i, "");
  const words = base.replace(/^\d{4}-\d{2}-\d{2}-/, "").replace(/[-_]+/g, " ");
  return words.charAt(0).toUpperCase() + words.slice(1);
}

export function slugify(text: string, maxWords = 7): string {
  const slug = text
    .toLowerCase()
    .replace(/`[^`]*`/g, (code) => code.replace(/[^a-z0-9]+/g, " "))
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .split(/\s+/)
    .slice(0, maxWords)
    .join("-");
  return slug || "note";
}

/** `added:` style date (YYYY-MM-DD) for an ISO timestamp. */
export function isoDay(iso: string | Date): string {
  const date = typeof iso === "string" ? new Date(iso) : iso;
  return Number.isFinite(date.getTime())
    ? date.toISOString().slice(0, 10)
    : new Date().toISOString().slice(0, 10);
}

/** Parse a metadata date. Bare days become midnight UTC (or end of day). */
export function metaDate(
  value: string | undefined,
  endOfDay = false,
): string | undefined {
  if (!value) return undefined;
  const trimmed = value.trim();
  const iso = /^\d{4}-\d{2}-\d{2}$/.test(trimmed)
    ? `${trimmed}T${endOfDay ? "23:59:59.999" : "00:00:00.000"}Z`
    : trimmed;
  const ms = Date.parse(iso);
  return Number.isFinite(ms) ? new Date(ms).toISOString() : undefined;
}

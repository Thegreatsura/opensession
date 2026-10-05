import type { TranscriptEntry } from "./types";

function safeStringify(value: unknown): string {
  try {
    return JSON.stringify(value) ?? "";
  } catch {
    return "";
  }
}

const SEPARATED_WORDS = /^[\p{L}\p{N}]+(?:[^\p{L}\p{N}]+[\p{L}\p{N}]+)+$/u;

let lastPattern: { needle: string; pattern: RegExp | null } | null = null;

/** Separator-tolerant pattern for a query of several words, or null. One
 *  search tests every row against the same query, so the last one is kept. */
function separatorPattern(needle: string): RegExp | null {
  if (lastPattern?.needle === needle) return lastPattern.pattern;
  const pattern = SEPARATED_WORDS.test(needle)
    ? new RegExp(needle.split(/[^\p{L}\p{N}]+/u).join("[^\\p{L}\\p{N}]*"), "u")
    : null;
  lastPattern = { needle, pattern };
  return pattern;
}

/** Where `needle` occurs in `hay`. A literal hit wins; failing that, the
 *  words of a multi-word query may be joined by any punctuation or spacing,
 *  so "pi-durable" finds "Pi Durable" and "pi_durable". */
function findQuery(
  hay: string,
  needle: string,
): { index: number; length: number } | null {
  const index = hay.indexOf(needle);
  if (index >= 0) return { index, length: needle.length };
  const match = separatorPattern(needle)?.exec(hay);
  return match ? { index: match.index, length: match[0].length } : null;
}

/** Build a compact one-line snippet around a visible transcript-text match. */
export function transcriptEntryMatchSnippet(
  entry: TranscriptEntry,
  query: string,
  context = 60,
): string | null {
  const needle = query.trim().toLowerCase();
  if (!needle) return null;
  const hay =
    entry.type === "tool_use" && entry.toolInput
      ? `${entry.content || ""}\n${safeStringify(entry.toolInput)}`
      : entry.content || "";
  const match = findQuery(hay.toLowerCase(), needle);
  if (!match) return null;
  const { index, length } = match;
  const start = Math.max(0, index - context);
  const end = Math.min(hay.length, index + length + context);
  let snippet = hay.slice(start, end).replace(/\s+/g, " ").trim();
  if (start > 0) snippet = `…${snippet}`;
  if (end < hay.length) snippet = `${snippet}…`;
  return snippet;
}

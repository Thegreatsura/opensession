/**
 * Memory repository files -> index records.
 *
 * The index (a memory-v2 MemoryStore at its own path) is derived from each
 * repository's HEAD: every entry becomes one record, so ranking, budgeting,
 * the prompt layout and the Settings API keep working unchanged. Pure: the
 * caller reads the files.
 */

import { createHash } from "crypto";
import {
  MEMORY_KINDS,
  type MemoryKind,
  type MemoryRecord,
  type MemorySource,
} from "../memory-v2/types";
import { memoryFingerprint } from "../memory-v2/store";
import {
  extractLinks,
  firstMeta,
  isEntryPoint,
  isMarkdownPath,
  linkTargetPath,
  metaDate,
  parseMemoryFile,
  type ParsedEntry,
} from "./format";
import { isScopeEntryPoint, scopeForPath } from "./layout";

export const SUMMARY_LIMIT = 400;
export const DETAILS_LIMIT_BYTES = 20_000;

export interface RepoFile {
  path: string;
  text: string;
}

export interface RepoRecord extends MemoryRecord {
  path: string;
  /** 0-based line of the entry, or -1 for a whole-file record. */
  line: number;
}

function hash(value: string, length = 12): string {
  return createHash("sha256").update(value).digest("hex").slice(0, length);
}

/** Stable id for an entry written without `id:` (people, other tools). */
export function syntheticEntryId(path: string, text: string): string {
  return `h-${hash(`${path}\0${text.trim().replace(/\s+/g, " ")}`)}`;
}

export function isNotePath(path: string): boolean {
  return /(^|\/)notes\//.test(path);
}

export function fileRecordId(path: string): string {
  return `f-${hash(path)}`;
}

function capBytes(text: string, limit = DETAILS_LIMIT_BYTES): string {
  if (Buffer.byteLength(text, "utf8") <= limit) return text;
  let out = text.slice(0, limit);
  while (Buffer.byteLength(out, "utf8") > limit) out = out.slice(0, -64);
  return `${out}\n…`;
}

function capSummary(text: string): { summary: string; overflow: boolean } {
  const clean = text.replace(/\s+/g, " ").trim();
  const chars = Array.from(clean);
  if (chars.length <= SUMMARY_LIMIT) return { summary: clean, overflow: false };
  return {
    summary: `${chars.slice(0, SUMMARY_LIMIT - 1).join("")}…`,
    overflow: true,
  };
}

export function sessionIdFromUrl(url: string | undefined): string | undefined {
  if (!url) return undefined;
  const match = /\/session\/([A-Za-z0-9._-]+)/.exec(url);
  return match?.[1];
}

function sourceFor(entry: ParsedEntry): MemorySource {
  const via = firstMeta(entry.meta, "via");
  const url = firstMeta(entry.meta, "source");
  const type: MemorySource["type"] =
    via === "settings" || via === "slack" || via === "user-explicit"
      ? via
      : "agent-verified";
  const source: MemorySource = { type };
  const sessionId = sessionIdFromUrl(url);
  if (sessionId) source.sessionId = sessionId;
  if (url) source.url = url;
  const by = firstMeta(entry.meta, "by");
  if (by) source.actor = by.slice(0, 200);
  return source;
}

function list(value: string[] | undefined): string[] {
  return [
    ...new Set(
      (value ?? [])
        .flatMap((item) => item.split(","))
        .map((item) => item.trim())
        .filter(Boolean),
    ),
  ];
}

function tagsFor(entry: ParsedEntry): string[] {
  return list(entry.meta.tags)
    .map((tag) => tag.toLocaleLowerCase("en-US").slice(0, 80))
    .slice(0, 12);
}

function kindFor(
  entry: ParsedEntry,
  expiresAt: string | undefined,
): MemoryKind {
  const raw = firstMeta(entry.meta, "kind")?.toLowerCase();
  const kind = MEMORY_KINDS.includes(raw as MemoryKind)
    ? (raw as MemoryKind)
    : "reference";
  // A status without an expiry is a fact that never ages out: index it as a
  // reference rather than dropping it.
  return kind === "status" && !expiresAt ? "reference" : kind;
}

export interface RecordsResult {
  records: RepoRecord[];
  /** Entries that could not be indexed (duplicates), for diagnostics. */
  skipped: number;
}

/**
 * Build index records for one repository. `fallbackTime` dates entries that
 * carry no `added:` (the HEAD commit time is a good choice).
 */
export function recordsForRepo(
  repo: string,
  files: RepoFile[],
  opts: { fallbackTime: string; now?: Date },
): RecordsResult {
  const now = opts.now ?? new Date();
  const byPath = new Map(files.map((file) => [file.path, file.text]));
  const linkedFromEntries = new Set<string>();
  const records: RepoRecord[] = [];
  const seenIds = new Set<string>();
  const seenFingerprints = new Set<string>();
  let skipped = 0;

  const push = (record: RepoRecord) => {
    const fpKey = `${record.scopeKey}\0${record.fingerprint}`;
    if (seenFingerprints.has(fpKey)) {
      skipped++;
      return;
    }
    if (seenIds.has(record.id))
      record.id = syntheticEntryId(
        record.path,
        `${record.line}:${record.summary}`,
      );
    if (seenIds.has(record.id)) {
      skipped++;
      return;
    }
    seenIds.add(record.id);
    seenFingerprints.add(fpKey);
    records.push(record);
  };

  // Files under a `notes/` folder hold the long detail of the entry that
  // links them; their bullets are part of that detail, not entries.
  const markdown = files.filter(
    (file) => isMarkdownPath(file.path) && !isNotePath(file.path),
  );
  for (const file of markdown) {
    const parsed = parseMemoryFile(file.path, file.text);
    const scopeKey = scopeForPath(repo, file.path);
    const scopeEntryPoint = isScopeEntryPoint(repo, file.path);
    for (const entry of parsed.entries) {
      const expiresAt = metaDate(firstMeta(entry.meta, "expires"), true);
      // "… See [[x/notes/y]]." points at the detail, which is indexed as
      // details; keep the note's file name out of the ranked summary.
      const { summary, overflow } = capSummary(
        entry.text.replace(/\s*See \[\[[^\]]*notes\/[^\]]+\]\]\.?\s*$/, "") ||
          entry.text,
      );
      const linked = extractLinks(entry.text)
        .map(linkTargetPath)
        .filter((path) => path && path !== file.path && byPath.has(path));
      linked.forEach((path) => linkedFromEntries.add(path));
      const detailParts = [
        overflow ? entry.text : "",
        ...linked
          .filter((path) => isMarkdownPath(path) && !isEntryPoint(path))
          .slice(0, 3)
          .map((path) => byPath.get(path) ?? ""),
      ].filter((part) => part.trim());
      const details = detailParts.length
        ? capBytes(detailParts.join("\n\n"))
        : undefined;
      const createdAt =
        metaDate(firstMeta(entry.meta, "added")) ?? opts.fallbackTime;
      const updatedAt = metaDate(firstMeta(entry.meta, "updated")) ?? createdAt;
      const id =
        firstMeta(entry.meta, "id")?.slice(0, 120) ||
        syntheticEntryId(file.path, entry.text);
      push({
        id,
        scopeKey,
        summary,
        details,
        kind: kindFor(entry, expiresAt),
        tier: entry.pinned && scopeEntryPoint ? "pinned" : "retrievable",
        state:
          expiresAt && Date.parse(expiresAt) <= now.getTime()
            ? "expired"
            : "active",
        source: sourceFor(entry),
        createdAt,
        updatedAt,
        lastConfirmedAt: metaDate(firstMeta(entry.meta, "confirmed")),
        expiresAt,
        supersedes: list(entry.meta.supersedes),
        fingerprint: memoryFingerprint(summary, details),
        tags: tagsFor(entry),
        retrievalCount: 0,
        path: file.path,
        line: entry.line,
      });
    }
  }

  // Files that hold no entries and are not an entry's linked note still
  // carry knowledge (a topic page in prose, a saved query, a script). Index
  // each as one record so search reaches it.
  const entryFiles = new Set(
    records.map((record) => record.path).filter(Boolean),
  );
  for (const file of files) {
    if (entryFiles.has(file.path) || linkedFromEntries.has(file.path)) continue;
    if (isEntryPoint(file.path)) continue;
    if (/(^|\/)\.[^/]+$/.test(file.path)) continue;
    const text = file.text.trim();
    if (!text) continue;
    // A topic file whose entries were all moved away is just its heading.
    if (
      isMarkdownPath(file.path) &&
      !text.split("\n").some((line) => line.trim() && !/^#/.test(line.trim()))
    )
      continue;
    const heading = /^#\s+(.+)$/m.exec(text)?.[1];
    const firstLine = text.split("\n").find((line) => line.trim()) ?? "";
    const label = isMarkdownPath(file.path)
      ? heading || firstLine.replace(/^[#>*\-\s]+/, "")
      : `${file.path}: ${firstLine.replace(/^[-#/*\s]+/, "")}`;
    const { summary } = capSummary(label || file.path);
    const details = capBytes(text);
    push({
      id: fileRecordId(file.path),
      scopeKey: scopeForPath(repo, file.path),
      summary,
      details,
      kind: "reference",
      tier: "retrievable",
      state: "active",
      source: { type: "agent-verified" },
      createdAt: opts.fallbackTime,
      updatedAt: opts.fallbackTime,
      supersedes: [],
      fingerprint: memoryFingerprint(summary, details),
      tags: [isMarkdownPath(file.path) ? "file" : "saved-file"],
      retrievalCount: 0,
      path: file.path,
      line: -1,
    });
  }
  return { records, skipped };
}

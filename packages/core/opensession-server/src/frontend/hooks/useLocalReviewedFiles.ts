import { useState } from "react";
import { z } from "zod";
import { splitPatchByFile } from "../lib/pr-review-guide";

const PREFIX = "opensession-reviewed-files:";
const INDEX_KEY = "opensession-reviewed-files-index";
/** Reviews remembered per browser; the oldest are forgotten first. */
const MAX_REVIEWS = 100;

/** FNV-1a over a file's hunks, ignoring the `index` line's blob ids. */
export function filePatchHash(text: string): string {
  let hash = 0x811c9dc5;
  for (const line of text.split("\n")) {
    if (line.startsWith("index ")) continue;
    for (let index = 0; index < line.length; index++) {
      hash ^= line.charCodeAt(index);
      hash = Math.imul(hash, 0x01000193);
    }
    hash ^= 10;
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(36);
}

type Stored = Record<string, string>;

const STORED = z.record(z.string(), z.string());
const INDEX = z.array(z.string());

function parseStored(text: string | null, fallback: string) {
  try {
    return JSON.parse(text || fallback);
  } catch {
    return undefined;
  }
}

function read(key: string): Stored {
  try {
    const parsed = STORED.safeParse(
      parseStored(localStorage.getItem(PREFIX + key), "{}"),
    );
    return parsed.success ? parsed.data : {};
  } catch {
    return {};
  }
}

function write(key: string, value: Stored): void {
  try {
    const parsedIndex = INDEX.safeParse(
      parseStored(localStorage.getItem(INDEX_KEY), "[]"),
    );
    const index = parsedIndex.success ? parsedIndex.data : [];
    const next = [...index.filter((entry) => entry !== key), key];
    for (const evicted of next.splice(
      0,
      Math.max(0, next.length - MAX_REVIEWS),
    ))
      localStorage.removeItem(PREFIX + evicted);
    localStorage.setItem(INDEX_KEY, JSON.stringify(next));
    if (Object.keys(value).length)
      localStorage.setItem(PREFIX + key, JSON.stringify(value));
    else localStorage.removeItem(PREFIX + key);
  } catch {
    // Storage full or blocked: the state still holds for this page.
  }
}

/** Reviewed and changed-since-review sets from a stored map and the current diff. */
export function localReviewState(
  stored: Stored,
  hashes: ReadonlyMap<string, string>,
) {
  const reviewed = new Set<string>();
  const changed = new Set<string>();
  for (const [path, hash] of hashes) {
    const seen = stored[path];
    if (seen === undefined) continue;
    (seen === hash ? reviewed : changed).add(path);
  }
  return { reviewed, changed };
}

/**
 * Per-file review state kept in this browser, for diffs with no provider-side
 * viewed state (a session's worktree, code.storage changes). Each mark stores
 * the file's diff hash, so a file that changes after review reads as changed
 * rather than reviewed, the same way GitHub reports it.
 */
export function useLocalReviewedFiles(key: string | null, patch: string) {
  const [stored, setStored] = useState<{
    key: string | null;
    value: Stored;
  }>(() => ({ key, value: key === null ? {} : read(key) }));
  // A new target reads its own marks once; the stored object then stays the
  // same between renders so the derived sets keep their identity.
  if (stored.key !== key)
    setStored({ key, value: key === null ? {} : read(key) });
  const value = stored.value;
  const hashes = new Map<string, string>();
  if (key !== null)
    for (const [path, text] of splitPatchByFile(patch))
      hashes.set(path, filePatchHash(text));
  const { reviewed, changed } = localReviewState(value, hashes);
  const setReviewed = (paths: readonly string[], next: boolean) => {
    if (key === null) return;
    const updated = { ...read(key) };
    for (const path of paths) {
      const hash = hashes.get(path);
      if (next && hash) updated[path] = hash;
      else delete updated[path];
    }
    write(key, updated);
    setStored({ key, value: updated });
  };
  return key === null
    ? { reviewed: undefined, changed: undefined, setReviewed }
    : { reviewed, changed, setReviewed };
}

/**
 * Fitting a unified diff into a model prompt without losing files.
 *
 * Cutting a large diff at a character limit hides every file past the cut, so
 * a model grouping the change never learns those files exist. These helpers
 * split the diff per file and share the budget fairly instead: small files
 * stay whole, large ones are trimmed to their share, and every file keeps at
 * least its header.
 */
import { createHash } from "crypto";

export interface FilePatch {
  path: string;
  text: string;
  additions: number;
  deletions: number;
}

/** Split a unified diff into per-file chunks keyed by the new-side path. */
export function splitPatchByFile(patch: string): FilePatch[] {
  const files: FilePatch[] = [];
  for (const part of patch.split(/^(?=diff --git )/m)) {
    if (!part.startsWith("diff --git ")) continue;
    const match = part.match(/^diff --git a\/(.+?) b\/(.+)$/m);
    if (!match) continue;
    let additions = 0;
    let deletions = 0;
    let inHunk = false;
    for (const line of part.split("\n")) {
      if (line.startsWith("@@")) inHunk = true;
      else if (!inHunk) continue;
      else if (line.startsWith("+")) additions++;
      else if (line.startsWith("-")) deletions++;
    }
    files.push({ path: match[2], text: part, additions, deletions });
  }
  return files;
}

/**
 * A content hash per file. The `index` line carries blob ids that move with
 * unrelated history, so only the path and hunks decide whether a file changed.
 */
export function filePatchHashes(patch: string): Record<string, string> {
  const hashes: Record<string, string> = {};
  for (const file of splitPatchByFile(patch)) {
    const body = file.text
      .split("\n")
      .filter((line) => !line.startsWith("index "))
      .join("\n");
    hashes[file.path] = createHash("sha1").update(body).digest("hex");
  }
  return hashes;
}

/** One line per changed file, so the model sees the full list even when trimmed. */
export function fileManifest(files: readonly FilePatch[]): string {
  return files
    .map((file) => `${file.path} (+${file.additions} -${file.deletions})`)
    .join("\n");
}

/** Characters always kept for a file: enough for its header and first hunk line. */
const MIN_FILE_SHARE = 300;

function trimFile(text: string, limit: number): string {
  if (text.length <= limit) return text;
  const cut = text.lastIndexOf("\n", limit);
  const kept = text.slice(0, cut > 0 ? cut : limit);
  const omitted = text.slice(kept.length).split("\n").length - 1;
  return `${kept}\n[... ${omitted} more lines of this file omitted]\n`;
}

/**
 * The diff within `budget` characters, with every file represented. Shares
 * are filled smallest-first so a file that fits is never trimmed to make room
 * for one that would be trimmed anyway.
 */
export function fitPatchToBudget(
  patch: string,
  budget: number,
): { patch: string; trimmed: boolean } {
  if (patch.length <= budget) return { patch, trimmed: false };
  const files = splitPatchByFile(patch);
  if (!files.length) return { patch: trimFile(patch, budget), trimmed: true };
  const order = files
    .map((file, index) => ({ index, size: file.text.length }))
    .sort((left, right) => left.size - right.size);
  const allotment = new Array<number>(files.length).fill(0);
  let remaining = budget;
  order.forEach(({ index, size }, position) => {
    const share = Math.max(
      MIN_FILE_SHARE,
      Math.floor(remaining / (order.length - position)),
    );
    allotment[index] = Math.min(size, share);
    remaining = Math.max(0, remaining - allotment[index]);
  });
  return {
    patch: files
      .map((file, index) => trimFile(file.text, allotment[index]))
      .join(""),
    trimmed: true,
  };
}

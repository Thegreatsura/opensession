/**
 * What a push to a memory repository must satisfy. The receive hook runs
 * this over every file a push changes, and server-side writes run it before
 * committing. Only what would break the repository for everyone is refused;
 * there is no approval step and no cap on how much a session writes.
 */

import { MEMORY_KINDS } from "../memory-v2/types";
import { firstMeta, isMarkdownPath, metaDate, parseMemoryFile } from "./format";
import { findSecrets } from "./secrets";

export const MAX_MARKDOWN_BYTES = 256 * 1024;
export const MAX_FILE_BYTES = 1024 * 1024;

export interface FileProblem {
  path: string;
  /** 1-based, for people. */
  line?: number;
  message: string;
}

export function validateRepoFile(
  path: string,
  bytes: Uint8Array,
  mode = "100644",
): FileProblem[] {
  const problems: FileProblem[] = [];
  if (mode === "120000")
    return [{ path, message: "Symbolic links are not allowed in memory." }];
  if (mode === "160000")
    return [{ path, message: "Submodules are not allowed in memory." }];
  if (mode === "100755")
    problems.push({
      path,
      message:
        "Executable files are not allowed. Save scripts without the executable bit; memory is data to read.",
    });
  const limit = isMarkdownPath(path) ? MAX_MARKDOWN_BYTES : MAX_FILE_BYTES;
  if (bytes.byteLength > limit)
    return [
      ...problems,
      {
        path,
        message: `File is ${bytes.byteLength} bytes; the limit is ${limit}. Split it or link to a smaller note.`,
      },
    ];
  if (bytes.subarray(0, 8000).includes(0))
    return [
      ...problems,
      { path, message: "Binary files are not allowed in memory." },
    ];
  const text = new TextDecoder().decode(bytes);
  for (const finding of findSecrets(text)) {
    problems.push({
      path,
      line: finding.line + 1,
      message: `Looks like a ${finding.name}. Memory never stores credentials.`,
    });
  }
  if (!isMarkdownPath(path)) return problems;
  const parsed = parseMemoryFile(path, text);
  for (const problem of parsed.problems) {
    problems.push({ path, line: problem.line + 1, message: problem.message });
  }
  for (const entry of parsed.entries) {
    const kind = firstMeta(entry.meta, "kind");
    if (kind && !MEMORY_KINDS.includes(kind.toLowerCase() as never)) {
      problems.push({
        path,
        line: entry.line + 1,
        message: `Unknown kind "${kind}". Use one of: ${MEMORY_KINDS.join(", ")}.`,
      });
    }
    for (const key of ["added", "updated", "confirmed", "expires"]) {
      const value = firstMeta(entry.meta, key);
      if (value && !metaDate(value)) {
        problems.push({
          path,
          line: entry.line + 1,
          message: `\`${key}: ${value}\` is not a date. Use YYYY-MM-DD.`,
        });
      }
    }
  }
  return problems;
}

export function formatProblems(problems: FileProblem[]): string {
  return problems
    .map(
      (problem) =>
        `${problem.path}${problem.line ? `:${problem.line}` : ""}: ${problem.message}`,
    )
    .join("\n");
}

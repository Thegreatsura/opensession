/**
 * Answers the server's local folder operations (server/local-folders.ts) on
 * top of a provider: the Mac app's native bridge or the browser's File System
 * Access API. Walk and search run here, next to the files, so the agent does
 * not pay a network round trip per directory.
 *
 * Every path is folder-relative. A provider never receives `..`, an absolute
 * path, or a write to a read-only folder; the Mac app checks the same rules
 * again against the real filesystem.
 */
import { z } from "zod";

export type EntryKind = "file" | "dir" | "other";

export interface FolderEntry {
  name: string;
  kind: EntryKind;
  size?: number;
  mtimeMs?: number;
}

export interface FolderStat {
  kind: EntryKind;
  size: number;
  mtimeMs: number;
}

export interface FolderChunk {
  data: Uint8Array;
  size: number;
  mtimeMs: number;
}

/** Filesystem primitives for one granted folder. */
export interface FolderAccess {
  list(path: string): Promise<FolderEntry[]>;
  stat(path: string): Promise<FolderStat>;
  read(path: string, offset: number, length: number): Promise<FolderChunk>;
  write(path: string, data: Uint8Array, append: boolean): Promise<void>;
  mkdir(path: string): Promise<void>;
  move(from: string, to: string): Promise<void>;
  /** Missing where deleting cannot be undone (the browser). */
  trash?(path: string): Promise<void>;
}

export class FolderOpError extends Error {}

const SKIP_DIRS = new Set([".git", "node_modules"]);
const MAX_CHUNK = 4 * 1024 * 1024;
const SEARCH_MAX_FILE_BYTES = 2 * 1024 * 1024;
const SEARCH_BUDGET_MS = 150_000;

const optionalPath = z.string().max(4096).optional();
const requiredPath = z.string().max(4096);

/** One operation as the server sends it. Unknown operations fail to parse. */
export const folderOpSchema = z.discriminatedUnion("op", [
  z.object({ op: z.literal("list"), args: z.object({ path: optionalPath }) }),
  z.object({ op: z.literal("stat"), args: z.object({ path: optionalPath }) }),
  z.object({
    op: z.literal("read"),
    args: z.object({
      path: requiredPath,
      offset: z.number().int().min(0).catch(0),
      length: z.number().int().min(0).catch(MAX_CHUNK),
    }),
  }),
  z.object({
    op: z.literal("write"),
    args: z.object({
      path: requiredPath,
      data: z.string(),
      append: z.boolean().catch(false),
    }),
  }),
  z.object({ op: z.literal("mkdir"), args: z.object({ path: requiredPath }) }),
  z.object({
    op: z.literal("move"),
    args: z.object({ from: requiredPath, to: requiredPath }),
  }),
  z.object({ op: z.literal("trash"), args: z.object({ path: requiredPath }) }),
  z.object({
    op: z.literal("walk"),
    args: z.object({
      path: optionalPath,
      recursive: z.boolean().catch(false),
      limit: z.number().int().catch(500),
    }),
  }),
  z.object({
    op: z.literal("search"),
    args: z.object({
      pattern: z.string().min(1).max(2000),
      ignoreCase: z.boolean().catch(false),
      path: optionalPath,
      glob: z.string().max(400).optional(),
      limit: z.number().int().catch(100),
    }),
  }),
]);
export type FolderOp = z.infer<typeof folderOpSchema>;

export interface WalkEntry {
  path: string;
  kind: EntryKind;
  size?: number;
}
export interface SearchMatch {
  path: string;
  line: number;
  text: string;
}
export type FolderOpResult =
  | { entries: FolderEntry[] }
  | FolderStat
  | { data: string; size: number; mtimeMs: number }
  | { ok: true }
  | { entries: WalkEntry[]; truncated: boolean }
  | { matches: SearchMatch[]; truncated: boolean; filesScanned: number };

/** Folder-relative, `/`-separated, no `.`/`..`. "" is the folder itself. */
export function normalizeFolderPath(raw: string | undefined): string {
  const value = (raw ?? "").replace(/\\/g, "/").trim();
  if (
    value.startsWith("/") ||
    /^[A-Za-z]:/.test(value) ||
    value.startsWith("~")
  )
    throw new FolderOpError("Paths must be relative to the folder");
  const parts: string[] = [];
  for (const part of value.split("/")) {
    if (!part || part === ".") continue;
    if (part === ".." || part.includes("\0"))
      throw new FolderOpError("Paths cannot leave the folder");
    parts.push(part);
  }
  return parts.join("/");
}

export function joinFolderPath(dir: string, name: string): string {
  return dir ? `${dir}/${name}` : name;
}

/** `*.md`, `src/**\/*.ts`, `{a,b}.txt`. Matches the base name when the glob
 *  has no slash, the whole path otherwise. */
export function globMatcher(
  glob: string | undefined,
): (path: string) => boolean {
  const source = glob?.trim();
  if (!source) return () => true;
  let pattern = "";
  let braces = 0;
  for (let i = 0; i < source.length; i++) {
    const char = source[i]!;
    if (char === "*") {
      if (source[i + 1] === "*") {
        pattern += ".*";
        i++;
        if (source[i + 1] === "/") i++;
      } else pattern += "[^/]*";
    } else if (char === "?") pattern += "[^/]";
    else if (char === "{") {
      braces++;
      pattern += "(?:";
    } else if (char === "}" && braces > 0) {
      braces--;
      pattern += ")";
    } else if (char === "," && braces > 0) pattern += "|";
    else pattern += char.replace(/[.+^$()|[\]\\]/g, "\\$&");
  }
  if (braces) throw new FolderOpError(`Invalid glob ${source}`);
  const regex = new RegExp(`^${pattern}$`);
  const onName = !source.includes("/");
  return (path) =>
    regex.test(onName ? path.slice(path.lastIndexOf("/") + 1) : path);
}

export function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000)
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

export function base64ToBytes(value: string): Uint8Array {
  const binary = atob(value);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

function looksBinary(bytes: Uint8Array): boolean {
  const end = Math.min(bytes.length, 8000);
  for (let i = 0; i < end; i++) if (bytes[i] === 0) return true;
  return false;
}

interface WalkOptions {
  recursive: boolean;
  limit: number;
  deadline?: number;
}

/** Breadth-first walk. `visit` returns false to stop early. */
async function walk(
  access: FolderAccess,
  root: string,
  options: WalkOptions,
  visit: (path: string, entry: FolderEntry) => Promise<boolean>,
): Promise<boolean> {
  const queue = [root];
  let seen = 0;
  while (queue.length) {
    const dir = queue.shift()!;
    const entries = await access.list(dir);
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      if (options.deadline && Date.now() > options.deadline) return true;
      const path = joinFolderPath(dir, entry.name);
      if (++seen > options.limit) return true;
      if (!(await visit(path, entry))) return true;
      if (
        options.recursive &&
        entry.kind === "dir" &&
        !SKIP_DIRS.has(entry.name)
      )
        queue.push(path);
    }
  }
  return false;
}

const clamp = (value: number, min: number, max: number) =>
  Math.min(Math.max(value, min), max);

const WRITES = new Set<FolderOp["op"]>(["write", "mkdir", "move", "trash"]);

/** Run one parsed server operation against a granted folder. */
export async function runFolderOp(
  access: FolderAccess,
  folder: { readOnly: boolean },
  request: FolderOp,
): Promise<FolderOpResult> {
  if (WRITES.has(request.op) && folder.readOnly)
    throw new FolderOpError("This folder is connected read-only");
  switch (request.op) {
    case "list":
      return {
        entries: await access.list(normalizeFolderPath(request.args.path)),
      };
    case "stat":
      return await access.stat(normalizeFolderPath(request.args.path));
    case "read": {
      const chunk = await access.read(
        normalizeFolderPath(request.args.path),
        request.args.offset,
        clamp(request.args.length, 0, MAX_CHUNK),
      );
      return {
        data: bytesToBase64(chunk.data),
        size: chunk.size,
        mtimeMs: chunk.mtimeMs,
      };
    }
    case "write": {
      const path = normalizeFolderPath(request.args.path);
      if (!path) throw new FolderOpError("Name a file to write");
      await access.write(
        path,
        base64ToBytes(request.args.data),
        request.args.append,
      );
      return { ok: true };
    }
    case "mkdir": {
      const path = normalizeFolderPath(request.args.path);
      if (!path) throw new FolderOpError("Name a folder to create");
      await access.mkdir(path);
      return { ok: true };
    }
    case "move": {
      const from = normalizeFolderPath(request.args.from);
      const to = normalizeFolderPath(request.args.to);
      if (!from || !to) throw new FolderOpError("Name both paths");
      if (to === from || to.startsWith(`${from}/`))
        throw new FolderOpError("Cannot move a folder into itself");
      await access.move(from, to);
      return { ok: true };
    }
    case "trash": {
      const path = normalizeFolderPath(request.args.path);
      if (!path) throw new FolderOpError("Cannot trash the folder itself");
      if (!access.trash)
        throw new FolderOpError(
          "Deleting needs the Open Session Mac app, which moves files to the Trash. A browser can only delete permanently, so it does not.",
        );
      await access.trash(path);
      return { ok: true };
    }
    case "walk": {
      const entries: WalkEntry[] = [];
      const truncated = await walk(
        access,
        normalizeFolderPath(request.args.path),
        {
          recursive: request.args.recursive,
          limit: clamp(request.args.limit, 1, 5000),
        },
        async (path, entry) => {
          const item: WalkEntry = { path, kind: entry.kind };
          if (entry.size !== undefined) item.size = entry.size;
          entries.push(item);
          return true;
        },
      );
      return { entries, truncated };
    }
    case "search": {
      let regex: RegExp;
      try {
        regex = new RegExp(
          request.args.pattern,
          request.args.ignoreCase ? "i" : "",
        );
      } catch (error) {
        throw new FolderOpError(
          `Invalid pattern: ${error instanceof Error ? error.message : "unreadable"}`,
        );
      }
      const matchesGlob = globMatcher(request.args.glob);
      const limit = clamp(request.args.limit, 1, 1000);
      const matches: SearchMatch[] = [];
      let filesScanned = 0;
      const decoder = new TextDecoder();
      const truncated = await walk(
        access,
        normalizeFolderPath(request.args.path),
        {
          recursive: true,
          limit: 200_000,
          deadline: Date.now() + SEARCH_BUDGET_MS,
        },
        async (path, entry) => {
          if (entry.kind !== "file" || !matchesGlob(path)) return true;
          if ((entry.size ?? 0) > SEARCH_MAX_FILE_BYTES) return true;
          const { data } = await access.read(path, 0, SEARCH_MAX_FILE_BYTES);
          filesScanned++;
          if (looksBinary(data)) return true;
          const lines = decoder.decode(data).split("\n");
          for (let i = 0; i < lines.length; i++) {
            if (!regex.test(lines[i]!)) continue;
            matches.push({ path, line: i + 1, text: lines[i]!.slice(0, 400) });
            if (matches.length >= limit) return false;
          }
          return true;
        },
      );
      return { matches, truncated, filesScanned };
    }
  }
}

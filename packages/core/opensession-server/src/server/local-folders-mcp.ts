/**
 * opensession-local-folders: work in a folder on the person's own computer
 * (local-folders.ts). Interactive runs only, and only in turns the folder's
 * owner prompted. File tools only: there is no shell on the device.
 */
import { mkdir, open, realpath, rm, stat } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { z } from "zod";
import { createSdkMcpServer, tool } from "./inprocess-mcp";
import {
  LocalFolderError,
  localFolderOp,
  resolveLocalFolder,
  sessionLocalFolders,
  type LocalFolderView,
} from "./local-folders";

export interface LocalFoldersMcpContext {
  sessionId: string;
  user?: string;
  /** Where copies land and where files may be copied out from. Null when
   *  the session's workspace is not on this machine. */
  workspace: () => { scratchDir: string; roots: string[] } | null;
}

/** One frame per chunk keeps every message well under the socket limit. */
export const LOCAL_FOLDER_CHUNK_BYTES = 1024 * 1024;
const MAX_TEXT_BYTES = 8 * 1024 * 1024;
const MAX_COPY_BYTES = 512 * 1024 * 1024;
const MAX_READ_OUTPUT_CHARS = 60_000;

type StatResult = {
  kind: "file" | "dir" | "other";
  size: number;
  mtimeMs: number;
};
type ReadResult = { data: string; size: number; mtimeMs: number };
type Entry = { path: string; kind: "file" | "dir" | "other"; size?: number };

function text(value: string) {
  return { content: [{ type: "text" as const, text: value }] };
}

function failure(error: unknown) {
  const message = error instanceof Error ? error.message : String(error);
  return {
    content: [{ type: "text" as const, text: message }],
    isError: true,
  };
}

function formatBytes(bytes: number): string {
  const units = ["B", "KB", "MB", "GB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return `${value.toFixed(unit === 0 ? 0 : 1)} ${units[unit]}`;
}

/** Normalize a folder-relative path the way the device does, so errors
 *  surface here with a clear message. */
export function folderPath(raw: string | undefined): string {
  const value = (raw ?? "").replace(/\\/g, "/").trim();
  if (
    value.startsWith("/") ||
    /^[A-Za-z]:/.test(value) ||
    value.startsWith("~")
  )
    throw new LocalFolderError(
      "Use a path relative to the connected folder, not an absolute path.",
    );
  const parts: string[] = [];
  for (const part of value.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..")
      throw new LocalFolderError("Paths cannot leave the connected folder.");
    parts.push(part);
  }
  return parts.join("/");
}

export function looksBinary(bytes: Uint8Array): boolean {
  const end = Math.min(bytes.length, 8000);
  for (let i = 0; i < end; i++) if (bytes[i] === 0) return true;
  return false;
}

export function applyExactEdits(
  original: string,
  edits: Array<{ oldText: string; newText: string }>,
): string {
  // Every edit is matched against the original, like the local edit tool.
  const spans: Array<{ start: number; end: number; newText: string }> = [];
  for (const [index, edit] of edits.entries()) {
    if (!edit.oldText)
      throw new LocalFolderError(`Edit ${index + 1} has an empty oldText.`);
    const start = original.indexOf(edit.oldText);
    if (start < 0)
      throw new LocalFolderError(`Edit ${index + 1}: oldText was not found.`);
    if (original.indexOf(edit.oldText, start + 1) >= 0)
      throw new LocalFolderError(
        `Edit ${index + 1}: oldText matches more than once. Include more context.`,
      );
    spans.push({
      start,
      end: start + edit.oldText.length,
      newText: edit.newText,
    });
  }
  spans.sort((a, b) => a.start - b.start);
  for (let i = 1; i < spans.length; i++)
    if (spans[i]!.start < spans[i - 1]!.end)
      throw new LocalFolderError("Two edits overlap. Merge them into one.");
  let out = "";
  let cursor = 0;
  for (const span of spans) {
    out += original.slice(cursor, span.start) + span.newText;
    cursor = span.end;
  }
  return out + original.slice(cursor);
}

export function createLocalFoldersMcpServer(ctx: LocalFoldersMcpContext) {
  const op = <T>(
    folder: LocalFolderView,
    name: Parameters<typeof localFolderOp>[3],
    args: Record<string, unknown>,
    timeoutMs?: number,
  ) =>
    localFolderOp<T>(ctx.sessionId, ctx.user, undefined, name, args, {
      folder,
      timeoutMs,
    });
  const pick = (ref?: string) =>
    resolveLocalFolder(ctx.sessionId, ctx.user, ref);

  /** Read a whole file in chunks, up to `max` bytes. */
  async function readAll(folder: LocalFolderView, path: string, max: number) {
    const head = await op<StatResult>(folder, "stat", { path });
    if (head.kind !== "file")
      throw new LocalFolderError(`${path || "."} is not a file.`);
    if (head.size > max)
      throw new LocalFolderError(
        `${path} is ${formatBytes(head.size)}, over the ${formatBytes(max)} limit for this tool.`,
      );
    const chunks: Uint8Array[] = [];
    let offset = 0;
    let mtimeMs = head.mtimeMs;
    while (offset < head.size || offset === 0) {
      const chunk = await op<ReadResult>(folder, "read", {
        path,
        offset,
        length: LOCAL_FOLDER_CHUNK_BYTES,
      });
      const bytes = Buffer.from(chunk.data, "base64");
      chunks.push(bytes);
      offset += bytes.length;
      mtimeMs = chunk.mtimeMs;
      if (!bytes.length || offset >= chunk.size) break;
    }
    return { bytes: Buffer.concat(chunks), mtimeMs };
  }

  async function writeAll(
    folder: LocalFolderView,
    path: string,
    bytes: Uint8Array,
  ) {
    let offset = 0;
    do {
      const chunk = bytes.subarray(offset, offset + LOCAL_FOLDER_CHUNK_BYTES);
      await op(folder, "write", {
        path,
        data: Buffer.from(chunk).toString("base64"),
        append: offset > 0,
      });
      offset += chunk.length;
    } while (offset < bytes.length);
  }

  const folderArg = z
    .string()
    .optional()
    .describe(
      "Folder name from list_local_folders. Optional when only one is connected.",
    );
  const pathArg = z
    .string()
    .describe("Path relative to the connected folder, such as notes/todo.md");

  return createSdkMcpServer({
    name: "opensession-local-folders",
    version: "1.0.0",
    tools: [
      tool(
        "list_local_folders",
        "List the folders on the person's own computer connected to this session, whether each is online, and whether it is read-only. Only the person who connected a folder can use it, in turns they prompted.",
        {},
        async () => {
          const folders = sessionLocalFolders(ctx.sessionId);
          if (!folders.length)
            return text(
              "No local folder is connected. The person can connect one from the composer's + menu (Connect a folder) in the Open Session Mac app, Chrome, or Edge.",
            );
          return text(
            folders
              .map(
                (f) =>
                  `${f.name}${f.displayPath ? ` (${f.displayPath})` : ""}\nkey: ${f.key}\ndevice: ${f.deviceLabel} (${f.online ? "online" : "offline"})\naccess: ${f.readOnly ? "read-only" : "can edit"}\nconnected by: ${f.owner}`,
              )
              .join("\n\n"),
          );
        },
      ),
      tool(
        "local_list",
        "List a directory in a connected local folder. Set recursive to walk subfolders (skips .git and node_modules).",
        {
          folder: folderArg,
          path: z
            .string()
            .optional()
            .describe("Directory, default the folder root"),
          recursive: z.boolean().optional(),
          limit: z.number().optional().describe("Max entries, default 500"),
        },
        async (args: {
          folder?: string;
          path?: string;
          recursive?: boolean;
          limit?: number;
        }) => {
          try {
            const folder = pick(args.folder);
            const path = folderPath(args.path);
            const limit = Math.min(Math.max(args.limit ?? 500, 1), 5000);
            const result = await op<{ entries: Entry[]; truncated?: boolean }>(
              folder,
              "walk",
              { path, recursive: args.recursive === true, limit },
              120_000,
            );
            if (!result.entries.length) return text("(empty)");
            return text(
              result.entries
                .map(
                  (e) =>
                    `${e.path}${e.kind === "dir" ? "/" : ""}${e.kind === "file" && typeof e.size === "number" ? `  ${formatBytes(e.size)}` : ""}`,
                )
                .join("\n") +
                (result.truncated ? `\n… stopped at ${limit} entries` : ""),
            );
          } catch (error) {
            return failure(error);
          }
        },
      ),
      tool(
        "local_read",
        "Read a text file from a connected local folder. offset and limit are 1-based line numbers. For binary files (PDF, images, spreadsheets) use copy_from_local_folder and process the copy.",
        {
          folder: folderArg,
          path: pathArg,
          offset: z.number().optional(),
          limit: z.number().optional(),
        },
        async (args: {
          folder?: string;
          path: string;
          offset?: number;
          limit?: number;
        }) => {
          try {
            const folder = pick(args.folder);
            const path = folderPath(args.path);
            const { bytes } = await readAll(folder, path, MAX_TEXT_BYTES);
            if (looksBinary(bytes))
              return text(
                `${path} is binary (${formatBytes(bytes.length)}). Use copy_from_local_folder to work with it.`,
              );
            const lines = new TextDecoder().decode(bytes).split("\n");
            const start = Math.max((args.offset ?? 1) - 1, 0);
            const end = Math.min(start + (args.limit ?? 2000), lines.length);
            let out = lines.slice(start, end).join("\n");
            let note =
              end < lines.length
                ? `\n\n[Lines ${start + 1}-${end} of ${lines.length}. Use offset to read more.]`
                : "";
            if (out.length > MAX_READ_OUTPUT_CHARS) {
              out = out.slice(0, MAX_READ_OUTPUT_CHARS);
              note = `\n\n[Cut at ${MAX_READ_OUTPUT_CHARS} characters. Use offset and limit to read less at once.]`;
            }
            return text(out + note);
          } catch (error) {
            return failure(error);
          }
        },
      ),
      tool(
        "local_search",
        "Search file contents in a connected local folder with a JavaScript regular expression. Skips binary files, files over 2 MB, .git and node_modules.",
        {
          folder: folderArg,
          pattern: z.string(),
          path: z
            .string()
            .optional()
            .describe("Directory to search, default the root"),
          glob: z.string().optional().describe("File name filter such as *.md"),
          ignoreCase: z.boolean().optional(),
          limit: z.number().optional().describe("Max matches, default 100"),
        },
        async (args: {
          folder?: string;
          pattern: string;
          path?: string;
          glob?: string;
          ignoreCase?: boolean;
          limit?: number;
        }) => {
          try {
            new RegExp(args.pattern, args.ignoreCase ? "i" : "");
          } catch (error) {
            return failure(
              new Error(`Invalid pattern: ${(error as Error).message}`),
            );
          }
          try {
            const folder = pick(args.folder);
            const result = await op<{
              matches: Array<{ path: string; line: number; text: string }>;
              truncated?: boolean;
              filesScanned?: number;
            }>(
              folder,
              "search",
              {
                pattern: args.pattern,
                ignoreCase: args.ignoreCase === true,
                path: folderPath(args.path),
                glob: args.glob,
                limit: Math.min(Math.max(args.limit ?? 100, 1), 1000),
              },
              180_000,
            );
            if (!result.matches.length)
              return text(
                `No matches${typeof result.filesScanned === "number" ? ` in ${result.filesScanned} files` : ""}.`,
              );
            return text(
              result.matches
                .map((m) => `${m.path}:${m.line}: ${m.text.slice(0, 400)}`)
                .join("\n") +
                (result.truncated ? "\n… more matches not shown" : ""),
            );
          } catch (error) {
            return failure(error);
          }
        },
      ),
      tool(
        "local_write",
        "Create or overwrite a text file in a connected local folder. Parent folders are created. The file is on the person's computer, so do not overwrite without reason.",
        { folder: folderArg, path: pathArg, content: z.string() },
        async (args: { folder?: string; path: string; content: string }) => {
          try {
            const folder = pick(args.folder);
            const path = folderPath(args.path);
            if (!path) throw new LocalFolderError("Name a file to write.");
            const bytes = new TextEncoder().encode(args.content);
            if (bytes.length > MAX_TEXT_BYTES)
              throw new LocalFolderError(
                `Content is over ${formatBytes(MAX_TEXT_BYTES)}. Use copy_to_local_folder for large files.`,
              );
            await writeAll(folder, path, bytes);
            return text(`Wrote ${formatBytes(bytes.length)} to ${path}.`);
          } catch (error) {
            return failure(error);
          }
        },
      ),
      tool(
        "local_edit",
        "Edit a text file in a connected local folder by exact text replacement. Each oldText must match exactly once in the original file.",
        {
          folder: folderArg,
          path: pathArg,
          edits: z
            .array(z.object({ oldText: z.string(), newText: z.string() }))
            .min(1),
        },
        async (args: {
          folder?: string;
          path: string;
          edits: Array<{ oldText: string; newText: string }>;
        }) => {
          try {
            const folder = pick(args.folder);
            const path = folderPath(args.path);
            const { bytes, mtimeMs } = await readAll(
              folder,
              path,
              MAX_TEXT_BYTES,
            );
            if (looksBinary(bytes))
              throw new LocalFolderError(`${path} is binary.`);
            const next = applyExactEdits(
              new TextDecoder().decode(bytes),
              args.edits,
            );
            const now = await op<StatResult>(folder, "stat", { path });
            if (now.mtimeMs !== mtimeMs)
              throw new LocalFolderError(
                `${path} changed while editing. Read it again and retry.`,
              );
            await writeAll(folder, path, new TextEncoder().encode(next));
            return text(
              `Applied ${args.edits.length} edit${args.edits.length === 1 ? "" : "s"} to ${path}.`,
            );
          } catch (error) {
            return failure(error);
          }
        },
      ),
      tool(
        "local_move",
        "Move or rename a file or directory inside a connected local folder. Never overwrites an existing path.",
        { folder: folderArg, from: z.string(), to: z.string() },
        async (args: { folder?: string; from: string; to: string }) => {
          try {
            const folder = pick(args.folder);
            const from = folderPath(args.from);
            const to = folderPath(args.to);
            if (!from || !to)
              throw new LocalFolderError(
                "Name both the source and the target.",
              );
            await op(folder, "move", { from, to });
            return text(`Moved ${from} to ${to}.`);
          } catch (error) {
            return failure(error);
          }
        },
      ),
      tool(
        "local_trash",
        "Move a file or directory in a connected local folder to the computer's Trash, where the person can restore it. Needs the Open Session Mac app; a browser cannot delete.",
        { folder: folderArg, path: pathArg },
        async (args: { folder?: string; path: string }) => {
          try {
            const folder = pick(args.folder);
            const path = folderPath(args.path);
            if (!path)
              throw new LocalFolderError("Cannot trash the folder itself.");
            await op(folder, "trash", { path });
            return text(`Moved ${path} to the Trash.`);
          } catch (error) {
            return failure(error);
          }
        },
      ),
      tool(
        "copy_from_local_folder",
        "Copy one file from a connected local folder into this session's scratch directory, so shell tools can process it (PDFs, images, spreadsheets, archives). Returns the local path of the copy. The copy is deleted with the session.",
        { folder: folderArg, path: pathArg },
        async (args: { folder?: string; path: string }) => {
          try {
            const workspace = ctx.workspace();
            if (!workspace)
              throw new LocalFolderError(
                "This session's workspace is not on this server, so a copy cannot land where your shell runs.",
              );
            const folder = pick(args.folder);
            const path = folderPath(args.path);
            if (!path) throw new LocalFolderError("Name a file to copy.");
            const head = await op<StatResult>(folder, "stat", { path });
            if (head.kind !== "file")
              throw new LocalFolderError(`${path} is not a file.`);
            if (head.size > MAX_COPY_BYTES)
              throw new LocalFolderError(
                `${path} is ${formatBytes(head.size)}, over the ${formatBytes(MAX_COPY_BYTES)} copy limit.`,
              );
            const safeName = folder.name.replace(/[^\w .-]/g, "_") || "folder";
            const target = join(
              workspace.scratchDir,
              "local-folders",
              safeName,
              ...path.split("/"),
            );
            await mkdir(dirname(target), { recursive: true });
            const handle = await open(target, "w");
            let offset = 0;
            try {
              while (offset < head.size) {
                const chunk = await op<ReadResult>(folder, "read", {
                  path,
                  offset,
                  length: LOCAL_FOLDER_CHUNK_BYTES,
                });
                const bytes = Buffer.from(chunk.data, "base64");
                if (!bytes.length) break;
                await handle.write(bytes);
                offset += bytes.length;
              }
            } catch (error) {
              await handle.close();
              await rm(target, { force: true });
              throw error;
            }
            await handle.close();
            return text(`Copied ${path} (${formatBytes(offset)}) to ${target}`);
          } catch (error) {
            return failure(error);
          }
        },
      ),
      tool(
        "copy_to_local_folder",
        "Copy one file from this session's workspace or scratch directory into a connected local folder, such as a finished report or a converted image. Overwrites the target file.",
        {
          source: z
            .string()
            .describe("Path in this session's workspace or scratch directory"),
          folder: folderArg,
          path: pathArg,
        },
        async (args: { source: string; folder?: string; path: string }) => {
          try {
            const workspace = ctx.workspace();
            if (!workspace)
              throw new LocalFolderError(
                "This session's workspace is not on this server, so its files cannot be copied from here.",
              );
            const roots = [workspace.scratchDir, ...workspace.roots];
            const candidate = isAbsolute(args.source)
              ? args.source
              : resolve(
                  workspace.roots[0] ?? workspace.scratchDir,
                  args.source,
                );
            const real = await realpath(candidate).catch(() => null);
            if (!real)
              throw new LocalFolderError(`${args.source} does not exist.`);
            const realRoots = await Promise.all(
              roots.map((root) => realpath(root).catch(() => null)),
            );
            const inside = realRoots.some((root) => {
              if (!root) return false;
              const rel = relative(root, real);
              return (
                rel === "" ||
                (!rel.startsWith("..") &&
                  !isAbsolute(rel) &&
                  !rel.startsWith(`..${sep}`))
              );
            });
            if (!inside)
              throw new LocalFolderError(
                "Only files in this session's workspace or scratch directory can be copied out.",
              );
            const info = await stat(real);
            if (!info.isFile())
              throw new LocalFolderError(`${args.source} is not a file.`);
            if (info.size > MAX_COPY_BYTES)
              throw new LocalFolderError(
                `${args.source} is ${formatBytes(info.size)}, over the ${formatBytes(MAX_COPY_BYTES)} copy limit.`,
              );
            const folder = pick(args.folder);
            const path = folderPath(args.path);
            if (!path) throw new LocalFolderError("Name the target file.");
            const handle = await open(real, "r");
            let offset = 0;
            try {
              const buffer = Buffer.alloc(LOCAL_FOLDER_CHUNK_BYTES);
              do {
                const { bytesRead } = await handle.read(
                  buffer,
                  0,
                  LOCAL_FOLDER_CHUNK_BYTES,
                  offset,
                );
                await op(folder, "write", {
                  path,
                  data: buffer.subarray(0, bytesRead).toString("base64"),
                  append: offset > 0,
                });
                offset += bytesRead;
                if (!bytesRead) break;
              } while (offset < info.size);
            } finally {
              await handle.close();
            }
            return text(
              `Copied ${formatBytes(offset)} to ${path} in ${folder.name}.`,
            );
          } catch (error) {
            return failure(error);
          }
        },
      ),
    ],
  });
}

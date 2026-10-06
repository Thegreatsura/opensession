import { describe, expect, test } from "bun:test";
import {
  base64ToBytes,
  bytesToBase64,
  type FolderAccess,
  type FolderEntry,
  folderOpSchema,
  globMatcher,
  normalizeFolderPath,
  runFolderOp,
} from "./ops";

/** Parse the way the bridge does, then run. */
function run(
  folder: FolderAccess,
  access: { readOnly: boolean },
  op: string,
  args: Record<string, string | number | boolean>,
) {
  return runFolderOp(folder, access, folderOpSchema.parse({ op, args }));
}

/** An in-memory folder: file path -> content. Directories are implied. */
function memoryFolder(files: Record<string, string>): FolderAccess & {
  files: Map<string, Uint8Array>;
} {
  const map = new Map(
    Object.entries(files).map(([k, v]) => [k, new TextEncoder().encode(v)]),
  );
  const isDir = (path: string) =>
    path === "" || [...map.keys()].some((k) => k.startsWith(`${path}/`));
  return {
    files: map,
    async list(path) {
      if (!isDir(path)) throw new Error(`${path} does not exist`);
      const prefix = path ? `${path}/` : "";
      const out = new Map<string, FolderEntry>();
      for (const [key, value] of map) {
        if (!key.startsWith(prefix)) continue;
        const [name, ...rest] = key.slice(prefix.length).split("/");
        out.set(
          name!,
          rest.length
            ? { name: name!, kind: "dir" }
            : { name: name!, kind: "file", size: value.length },
        );
      }
      return [...out.values()];
    },
    async stat(path) {
      const file = map.get(path);
      if (file) return { kind: "file", size: file.length, mtimeMs: 1 };
      if (isDir(path)) return { kind: "dir", size: 0, mtimeMs: 0 };
      throw new Error(`${path} does not exist`);
    },
    async read(path, offset, length) {
      const file = map.get(path);
      if (!file) throw new Error(`${path} does not exist`);
      return {
        data: file.subarray(offset, offset + length),
        size: file.length,
        mtimeMs: 1,
      };
    },
    async write(path, data, append) {
      const before = append
        ? (map.get(path) ?? new Uint8Array())
        : new Uint8Array();
      const next = new Uint8Array(before.length + data.length);
      next.set(before);
      next.set(data, before.length);
      map.set(path, next);
    },
    async mkdir() {},
    async move(from, to) {
      map.set(to, map.get(from)!);
      map.delete(from);
    },
  };
}

const editable = { readOnly: false };

describe("local folder operations", () => {
  test("paths are folder-relative and cannot climb out", () => {
    expect(normalizeFolderPath(" a\\b/./c/ ")).toBe("a/b/c");
    expect(normalizeFolderPath(undefined)).toBe("");
    expect(() => folderOpSchema.parse({ op: "rm", args: {} })).toThrow();
    expect(() => normalizeFolderPath("../etc")).toThrow();
    expect(() => normalizeFolderPath("/etc")).toThrow();
    expect(() => normalizeFolderPath("C:/Windows")).toThrow();
  });

  test("globs match names, paths, and alternatives", () => {
    expect(globMatcher("*.md")("docs/readme.md")).toBe(true);
    expect(globMatcher("*.md")("docs/readme.txt")).toBe(false);
    expect(globMatcher("docs/**/*.ts")("docs/a/b/c.ts")).toBe(true);
    expect(globMatcher("*.{png,jpg}")("x.jpg")).toBe(true);
    expect(globMatcher("a,b")("a,b")).toBe(true);
    expect(() => globMatcher("{a")).toThrow();
  });

  test("base64 round trips binary", () => {
    const bytes = new Uint8Array([0, 1, 2, 250, 255]);
    expect([...base64ToBytes(bytesToBase64(bytes))]).toEqual([...bytes]);
  });

  test("walk lists recursively and skips dependency folders", async () => {
    const folder = memoryFolder({
      "a.md": "x",
      "docs/b.md": "y",
      "node_modules/pkg/index.js": "z",
    });
    expect(await run(folder, editable, "walk", { recursive: true })).toEqual({
      entries: [
        { path: "a.md", kind: "file", size: 1 },
        { path: "docs", kind: "dir" },
        { path: "node_modules", kind: "dir" },
        { path: "docs/b.md", kind: "file", size: 1 },
      ],
      truncated: false,
    });
    expect(
      await run(folder, editable, "walk", { recursive: true, limit: 2 }),
    ).toMatchObject({ truncated: true });
  });

  test("search finds lines, honours globs, and skips binary files", async () => {
    const folder = memoryFolder({
      "notes/todo.md": "buy milk\nPay taxes\n",
      "notes/old.txt": "pay rent",
      "image.png": "\0PNG pay",
    });
    expect(
      await run(folder, editable, "search", {
        pattern: "pay",
        ignoreCase: true,
        glob: "*.md",
      }),
    ).toMatchObject({
      matches: [{ path: "notes/todo.md", line: 2, text: "Pay taxes" }],
    });
    expect(
      await run(folder, editable, "search", { pattern: "pay" }),
    ).toMatchObject({
      matches: [{ path: "notes/old.txt", line: 1, text: "pay rent" }],
    });
  });

  test("reads and writes chunks as base64", async () => {
    const folder = memoryFolder({ "a.txt": "hello world" });
    expect(
      await run(folder, editable, "read", {
        path: "a.txt",
        offset: 6,
        length: 5,
      }),
    ).toEqual({
      data: bytesToBase64(new TextEncoder().encode("world")),
      size: 11,
      mtimeMs: 1,
    });
    await run(folder, editable, "write", {
      path: "b.txt",
      data: bytesToBase64(new TextEncoder().encode("ab")),
    });
    await run(folder, editable, "write", {
      path: "b.txt",
      data: bytesToBase64(new TextEncoder().encode("cd")),
      append: true,
    });
    expect(new TextDecoder().decode(folder.files.get("b.txt"))).toBe("abcd");
  });

  test("read-only folders, browser trash, and self-moves are refused", async () => {
    const folder = memoryFolder({ "a.txt": "x" });
    await expect(
      run(folder, { readOnly: true }, "write", {
        path: "a.txt",
        data: "",
      }),
    ).rejects.toThrow("read-only");
    await expect(
      run(folder, editable, "trash", { path: "a.txt" }),
    ).rejects.toThrow("Mac app");
    await expect(
      run(folder, editable, "move", { from: "a", to: "a/b" }),
    ).rejects.toThrow("into itself");
  });
});

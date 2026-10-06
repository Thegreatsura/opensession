const { afterEach, beforeEach, describe, expect, test } = require("bun:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const {
  LocalFolders,
  normalizeRelative,
  deviceLabel,
} = require("./local-folders");

const ORIGIN = "https://acme.example.test";
let base;
let folder;
let outside;
let trashed;

function make(pick = folder) {
  return new LocalFolders({
    file: () => path.join(base, "profile", "local-folders.json"),
    home: path.join(base, "home"),
    hostname: "Acme-MacBook-Pro.local",
    pickDirectory: async () => pick,
    trashItem: async (file) => {
      trashed.push(file);
      fs.rmSync(file, { recursive: true });
    },
  });
}

beforeEach(() => {
  base = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "os-folders-")));
  folder = path.join(base, "home", "project");
  outside = path.join(base, "secret");
  fs.mkdirSync(path.join(folder, "notes"), { recursive: true });
  fs.mkdirSync(outside, { recursive: true });
  fs.writeFileSync(path.join(folder, "notes", "todo.md"), "one\ntwo\n");
  fs.writeFileSync(path.join(outside, "key.txt"), "secret");
  fs.symlinkSync(outside, path.join(folder, "escape"));
  fs.symlinkSync(path.join(folder, "notes"), path.join(folder, "inner"));
  trashed = [];
});

afterEach(() => fs.rmSync(base, { recursive: true, force: true }));

describe("Mac local folder grants", () => {
  test("relative paths cannot climb out", () => {
    expect(normalizeRelative("a/./b//c")).toEqual(["a", "b", "c"]);
    expect(() => normalizeRelative("../x")).toThrow();
    expect(() => normalizeRelative("/etc/passwd")).toThrow();
    expect(() => normalizeRelative("~/x")).toThrow();
    expect(deviceLabel("Acme-MacBook-Pro.local")).toBe("Acme MacBook Pro");
  });

  test("picks, persists per origin, and shows a home-relative path", async () => {
    const folders = make();
    const grant = await folders.pick(ORIGIN, null);
    expect(grant.displayPath).toBe("~/project");
    expect(await folders.list("https://other.example.test")).toEqual([]);
    const again = make();
    expect((await again.list(ORIGIN)).map((g) => g.id)).toEqual([grant.id]);
    expect((await again.device()).id).toBe((await folders.device()).id);
    expect(await again.pick(ORIGIN, null)).toEqual(grant);
  });

  test("refuses the home folder and system roots", async () => {
    await expect(
      make(path.join(base, "home")).pick(ORIGIN, null),
    ).rejects.toThrow("project folder");
    await expect(make("/").pick(ORIGIN, null)).rejects.toThrow(
      "project folder",
    );
  });

  test("reads, writes, lists and moves inside the folder", async () => {
    const folders = make();
    const { id } = await folders.pick(ORIGIN, null);
    const read = await folders.op(ORIGIN, id, "read", {
      path: "notes/todo.md",
      offset: 4,
      length: 100,
    });
    expect(Buffer.from(read.data).toString()).toBe("two\n");
    await folders.op(ORIGIN, id, "write", {
      path: "out/report.txt",
      data: new TextEncoder().encode("hello"),
    });
    await folders.op(ORIGIN, id, "write", {
      path: "out/report.txt",
      data: new TextEncoder().encode(" world"),
      append: true,
    });
    expect(
      fs.readFileSync(path.join(folder, "out", "report.txt"), "utf8"),
    ).toBe("hello world");
    const entries = await folders.op(ORIGIN, id, "list", { path: "" });
    expect(entries.map((e) => `${e.name}:${e.kind}`).sort()).toEqual([
      "escape:other",
      "inner:other",
      "notes:dir",
      "out:dir",
    ]);
    // Symlinks that stay inside still work.
    const inner = await folders.op(ORIGIN, id, "stat", {
      path: "inner/todo.md",
    });
    expect(inner.kind).toBe("file");
    await folders.op(ORIGIN, id, "move", {
      from: "out/report.txt",
      to: "done.txt",
    });
    await expect(
      folders.op(ORIGIN, id, "move", { from: "done.txt", to: "notes/todo.md" }),
    ).rejects.toThrow("already exists");
    await folders.op(ORIGIN, id, "trash", { path: "done.txt" });
    expect(trashed).toEqual([path.join(folder, "done.txt")]);
  });

  test("symlinks that leave the folder are refused for reads and writes", async () => {
    const folders = make();
    const { id } = await folders.pick(ORIGIN, null);
    await expect(
      folders.op(ORIGIN, id, "read", {
        path: "escape/key.txt",
        offset: 0,
        length: 10,
      }),
    ).rejects.toThrow("outside the folder");
    await expect(
      folders.op(ORIGIN, id, "write", {
        path: "escape/new.txt",
        data: new TextEncoder().encode("x"),
      }),
    ).rejects.toThrow("outside the folder");
    expect(fs.existsSync(path.join(outside, "new.txt"))).toBe(false);
    await expect(
      folders.op(ORIGIN, id, "trash", { path: "escape" }),
    ).rejects.toThrow("outside the folder");
  });

  test("read-only grants and other origins cannot change anything", async () => {
    const folders = make();
    const { id } = await folders.pick(ORIGIN, null);
    await folders.update(ORIGIN, id, {
      readOnly: true,
      sessionIds: ["s1", "../x"],
    });
    expect((await folders.list(ORIGIN))[0].sessionIds).toEqual(["s1"]);
    await expect(
      folders.op(ORIGIN, id, "write", {
        path: "a.txt",
        data: new TextEncoder().encode("x"),
      }),
    ).rejects.toThrow("read-only");
    await expect(
      folders.op("https://other.example.test", id, "stat", { path: "" }),
    ).rejects.toThrow("no longer connected");
  });
});

/** Opening a WAL database must wait out another connection's lock.
 *
 * `PRAGMA journal_mode = WAL` runs before any table is touched. When it ran
 * before `PRAGMA busy_timeout`, a store opened while another connection held
 * the file (a sibling actor lane checkpointing on close, for example) failed
 * at once with SQLITE_BUSY. For per-session actor stores that error
 * quarantined the session mid-run ("Session ... is quarantined: database is
 * locked"). */
import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative, resolve } from "node:path";
import { SessionKernelStore } from "./session-kernel/store";
import { TranscriptStore } from "./transcript-store";

const sourceRoot = resolve(import.meta.dir, "..");

/** Holds `path` with an exclusive lock from another thread for `holdMs`. */
async function holdExclusively(path: string, holdMs: number): Promise<void> {
  const holder = new Worker(
    URL.createObjectURL(
      new Blob(
        [
          `import { Database } from "bun:sqlite";
          const db = new Database(${JSON.stringify(path)});
          db.exec("PRAGMA locking_mode = EXCLUSIVE; BEGIN IMMEDIATE; COMMIT;");
          postMessage("held");
          setTimeout(() => { db.close(); postMessage("released"); }, ${holdMs});`,
        ],
        { type: "application/typescript" },
      ),
    ),
  );
  await new Promise<void>((resolveHeld, reject) => {
    holder.onerror = (event) => reject(new Error(event.message));
    holder.onmessage = (event) => {
      if (event.data === "held") resolveHeld();
      if (event.data === "released") holder.terminate();
    };
  });
}

describe("SQLite stores opened under lock contention", () => {
  test("a session kernel store waits for a briefly locked database", async () => {
    const root = mkdtempSync(join(tmpdir(), "sqlite-open-busy-"));
    try {
      const path = join(root, "session.sqlite");
      new SessionKernelStore(path, { busyTimeoutMs: 250 }).close();
      await holdExclusively(path, 100);
      const store = new SessionKernelStore(path, { busyTimeoutMs: 2_000 });
      store.close();
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a transcript store waits for a briefly locked database", async () => {
    const root = mkdtempSync(join(tmpdir(), "sqlite-open-busy-"));
    try {
      const path = join(root, "session.sqlite");
      new TranscriptStore(path).close();
      await holdExclusively(path, 100);
      const store = new TranscriptStore(path);
      expect(store.needsImport("session")).toBe(true);
      store.close();
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("every WAL store installs its busy handler before switching journal mode", () => {
    const offenders: string[] = [];
    for (const file of new Bun.Glob("**/*.ts").scanSync(sourceRoot)) {
      if (file.endsWith(".test.ts")) continue;
      const text = readFileSync(resolve(sourceRoot, file), "utf8");
      // Each WAL switch must follow a busy_timeout on the same connection,
      // that is, after the nearest preceding `new Database(`.
      for (const match of text.matchAll(/journal_mode\s*=\s*WAL/gi)) {
        const opened = text.lastIndexOf("new Database(", match.index);
        const between = text.slice(Math.max(0, opened), match.index);
        if (!/busy_timeout\s*=/i.test(between))
          offenders.push(relative(sourceRoot, resolve(sourceRoot, file)));
      }
    }
    expect(offenders).toEqual([]);
  });
});

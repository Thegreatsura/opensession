import { afterAll, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { callSearchIndex } from "./session-search-client";

const root = mkdtempSync(join(tmpdir(), "session-search-worker-"));
const previous = process.env.OPENSESSION_SEARCH_DB;
afterAll(() => {
  if (previous === undefined) delete process.env.OPENSESSION_SEARCH_DB;
  else process.env.OPENSESSION_SEARCH_DB = previous;
  rmSync(root, { recursive: true, force: true });
});

const record = (id: string, question: string, ts: number) => ({
  id,
  source: "session",
  question,
  summary: "",
  resolution: "",
  files: "",
  ts,
  activityTs: ts,
  distilled: "mech" as const,
});

test("the worker indexes, searches and removes in request order", async () => {
  process.env.OPENSESSION_SEARCH_DB = join(root, "a.db");
  const now = Date.now();
  // Posted without awaiting: FIFO order makes the search see both writes.
  void callSearchIndex(
    "upsert",
    record("session:a", "flaky deploy rollback", now),
  );
  void callSearchIndex("upsert", record("session:b", "sidebar rollback", now));
  const hits = await callSearchIndex("search", "rollback", { now });
  expect(hits.map((hit) => hit.id).sort()).toEqual(["session:a", "session:b"]);
  const state = await callSearchIndex("indexState");
  expect(state).toBeInstanceOf(Map);
  expect(state.get("session:a")?.activityTs).toBe(now);
  await callSearchIndex("remove", "session:a");
  expect(await callSearchIndex("count")).toBe(1);
});

test("a changed database path gets its own worker and file", async () => {
  process.env.OPENSESSION_SEARCH_DB = join(root, "b.db");
  expect(await callSearchIndex("count")).toBe(0);
  process.env.OPENSESSION_SEARCH_DB = join(root, "a.db");
  expect(await callSearchIndex("count")).toBe(1);
});

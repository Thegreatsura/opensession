import { Database } from "bun:sqlite";
import { describe, expect, test } from "bun:test";
import {
  searchableEntryText,
  TranscriptTextIndex,
  transcriptIndexRows,
  transcriptMatchQuery,
  type TranscriptIndexBatch,
} from "./transcript-text-index";
import type { TranscriptEntry } from "./types";

const DAY = 86_400_000;
const NOW = 1_800_000_000_000;

function index(): TranscriptTextIndex {
  return new TranscriptTextIndex(new Database(":memory:"));
}

function batch(
  over: Partial<TranscriptIndexBatch> & { sessionId: string },
): TranscriptIndexBatch {
  return {
    epoch: 0,
    fromChangeSeq: 0,
    throughChangeSeq: 1,
    activityTs: NOW - DAY,
    rows: [],
    ...over,
  };
}

function entry(
  type: TranscriptEntry["type"],
  content: string,
  extra: Partial<TranscriptEntry> = {},
): TranscriptEntry {
  return {
    id: crypto.randomUUID(),
    type,
    content,
    timestamp: "2026-10-01T10:00:00Z",
    ...extra,
  } as TranscriptEntry;
}

describe("transcriptMatchQuery", () => {
  test("quotes words, reads punctuation as a phrase, prefixes the last term", () => {
    expect(transcriptMatchQuery("pi-durable")).toBe('"pi durable"*');
    expect(transcriptMatchQuery("deploy  watchdog")).toBe(
      '"deploy" AND "watchdog"*',
    );
    expect(transcriptMatchQuery('say "hi" OR NEAR(x)')).toBe(
      '"say" AND "hi" AND "or" AND "near x"',
    );
  });

  test("keeps a short last term exact and drops empty input", () => {
    expect(transcriptMatchQuery("fix pr")).toBe('"fix" AND "pr"');
    expect(transcriptMatchQuery(" -- ")).toBe("");
  });
});

describe("searchableEntryText", () => {
  test("keeps what people said and the agent replied", () => {
    expect(searchableEntryText(entry("user", "  find pi durable "))).toBe(
      "find pi durable",
    );
    expect(
      searchableEntryText(entry("assistant", "x".repeat(9_000))),
    ).toHaveLength(4_000);
  });

  test("keeps a short tool input but never tool output", () => {
    const call = searchableEntryText(
      entry("tool_use", "", {
        toolName: "Bash",
        toolInput: { command: `rg needle ${"y".repeat(1_000)}` },
      }),
    );
    expect(call).toStartWith('Bash {"command":"rg needle');
    expect(call!.length).toBeLessThan(320);
    expect(searchableEntryText(entry("tool_result", "needle"))).toBeNull();
  });

  test("rows skip entries without a seq", () => {
    expect(
      transcriptIndexRows([
        { ...entry("user", "hello"), seq: 3 },
        entry("user", "no seq"),
      ]),
    ).toEqual([
      { seq: 3, ts: Date.parse("2026-10-01T10:00:00Z"), text: "hello" },
    ]);
  });
});

describe("TranscriptTextIndex", () => {
  test("finds a session by a hyphenated query written with spaces", () => {
    const ix = index();
    ix.apply(
      batch({
        sessionId: "cloudflare",
        rows: [
          {
            seq: 1,
            ts: 0,
            text: "Cloudflare integrated Pi Durable in the SDK",
          },
          { seq: 2, ts: 0, text: "unrelated reply" },
        ],
      }),
    );
    ix.apply(
      batch({
        sessionId: "apart",
        rows: [{ seq: 1, ts: 0, text: "pi release, durable storage" }],
      }),
    );
    const hits = ix.search("pi-durable", { now: NOW });
    expect(hits.map((hit) => hit.id)).toEqual(["cloudflare"]);
    expect(hits[0]!.snippet).toContain("Pi Durable");
    expect(
      ix
        .search("dura", { now: NOW })
        .map((hit) => hit.id)
        .sort(),
    ).toEqual(["apart", "cloudflare"]);
  });

  test("returns one row per session, recent work first on equal matches", () => {
    const ix = index();
    for (const [id, age] of [
      ["old", 200],
      ["new", 1],
    ] as const)
      ix.apply(
        batch({
          sessionId: id,
          activityTs: NOW - age * DAY,
          rows: [
            { seq: 1, ts: 0, text: "the watchdog restarted" },
            { seq: 2, ts: 0, text: "watchdog again" },
          ],
        }),
      );
    expect(ix.search("watchdog", { now: NOW }).map((hit) => hit.id)).toEqual([
      "new",
      "old",
    ]);
  });

  test("a query too common to rank takes the newest matching rows", () => {
    const ix = index();
    for (const id of ["first", "second", "third"])
      ix.apply(
        batch({
          sessionId: id,
          activityTs: NOW,
          rows: [{ seq: 1, ts: 0, text: `the ${id} reply` }],
        }),
      );
    expect(
      ix
        .search("the", { now: NOW, limit: 2, rankedMatchLimit: 2 })
        .map((hit) => hit.id),
    ).toEqual(["third", "second"]);
  });

  test("continues only from the stored cursor", () => {
    const ix = index();
    expect(
      ix.apply(
        batch({
          sessionId: "s",
          throughChangeSeq: 5,
          rows: [{ seq: 1, ts: 0, text: "first draft" }],
        }),
      ),
    ).toBe(true);
    expect(ix.cursor("s")).toEqual({ epoch: 0, changeSeq: 5 });
    // A writer that read an older cursor is refused.
    expect(
      ix.apply(
        batch({ sessionId: "s", fromChangeSeq: 3, throughChangeSeq: 6 }),
      ),
    ).toBe(false);
    // An edited row replaces the old text; a null text drops it.
    expect(
      ix.apply(
        batch({
          sessionId: "s",
          fromChangeSeq: 5,
          throughChangeSeq: 7,
          rows: [
            { seq: 1, ts: 0, text: "final version" },
            { seq: 2, ts: 0, text: null },
          ],
        }),
      ),
    ).toBe(true);
    expect(ix.search("draft", { now: NOW })).toEqual([]);
    expect(ix.search("final", { now: NOW }).map((hit) => hit.id)).toEqual([
      "s",
    ]);
    expect(ix.stats()).toEqual({ sessions: 1, rows: 1 });
  });

  test("a new epoch must start over, and starting over drops old rows", () => {
    const ix = index();
    ix.apply(
      batch({
        sessionId: "s",
        throughChangeSeq: 9,
        rows: [{ seq: 1, ts: 0, text: "before the reset" }],
      }),
    );
    expect(
      ix.apply(batch({ sessionId: "s", epoch: 9, fromChangeSeq: 9 })),
    ).toBe(false);
    expect(
      ix.apply(
        batch({
          sessionId: "s",
          epoch: 9,
          throughChangeSeq: 11,
          rows: [{ seq: 1, ts: 0, text: "after the reset" }],
        }),
      ),
    ).toBe(true);
    expect(ix.search("before", { now: NOW })).toEqual([]);
    expect(ix.cursor("s")).toEqual({ epoch: 9, changeSeq: 11 });
  });

  test("remove forgets a session entirely", () => {
    const ix = index();
    ix.apply(
      batch({ sessionId: "s", rows: [{ seq: 1, ts: 0, text: "needle" }] }),
    );
    ix.remove("s");
    expect(ix.search("needle", { now: NOW })).toEqual([]);
    expect(ix.cursor("s")).toBeNull();
    expect(ix.stats()).toEqual({ sessions: 0, rows: 0 });
  });
});

describe("offline backfill", () => {
  test("indexes an actor database once and leaves current sessions alone", async () => {
    const { mkdtempSync, rmSync } = await import("node:fs");
    const { join } = await import("node:path");
    const { tmpdir } = await import("node:os");
    const { TranscriptStore } = await import("./transcript-store");
    const { backfillActorDatabase } =
      await import("./transcript-index-backfill");
    const dir = mkdtempSync(join(tmpdir(), "transcript-backfill-"));
    try {
      const path = join(dir, "actor.sqlite");
      const actor = new TranscriptStore(path);
      actor.appendTranscriptEvents("s", [
        entry("user", "explore Pi Durable objects"),
        entry("tool_result", "durable output nobody searches"),
        entry("assistant", "here is the plan"),
      ]);
      actor.close();

      const ix = index();
      const first = backfillActorDatabase(path, ix, ix.cursors());
      expect(first).toEqual({ sessions: 1, skipped: 0, rows: 2 });
      expect(
        ix.search("pi-durable", { now: NOW }).map((hit) => hit.id),
      ).toEqual(["s"]);
      expect(ix.search("output", { now: NOW })).toEqual([]);
      expect(backfillActorDatabase(path, ix, ix.cursors())).toEqual({
        sessions: 0,
        skipped: 1,
        rows: 0,
      });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

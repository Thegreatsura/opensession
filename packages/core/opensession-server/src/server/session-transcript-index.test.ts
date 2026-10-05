import { afterAll, beforeEach, expect, test } from "bun:test";
import type { TranscriptPage } from "./transcript-store";
import type { TranscriptEntry } from "./types";

// A fake transcript: rows keyed by seq, each stamped with the change that
// last wrote it, behind the same reads the indexer uses.
let epoch = 0;
let nextChange = 1;
let rows = new Map<
  number,
  TranscriptEntry & { seq: number; changeSeq: number }
>();
let reads = 0;

function write(seq: number, content: string): void {
  rows.set(seq, {
    id: `e${seq}`,
    type: "assistant",
    content,
    timestamp: "2026-10-01T10:00:00Z",
    seq,
    changeSeq: nextChange++,
  });
}

const { transcript } = await import("./actor-transcript");
const real = { ...transcript };
Object.assign(transcript, {
  getLastResetChangeSeq: async () => epoch,
  getLastChangeSeq: async () => nextChange - 1,
  readChangesSince: async (
    _id: string,
    since: number,
    limit: number,
  ): Promise<TranscriptPage> => {
    reads++;
    const entries = [...rows.values()]
      .filter((row) => row.changeSeq > since)
      .sort((a, b) => a.changeSeq - b.changeSeq)
      .slice(0, limit);
    return {
      entries,
      firstSeq: entries[0]?.seq ?? 0,
      lastSeq: entries.at(-1)?.seq ?? 0,
    };
  },
});

const { indexSessionTranscript } = await import("./session-index");
const { __setSessionSearchStoreForTest } =
  await import("./session-search-client");
const { SessionSearchStore } = await import("./session-search-store");

let store = new SessionSearchStore(":memory:");
const previous = __setSessionSearchStoreForTest(store);
afterAll(() => {
  __setSessionSearchStoreForTest(previous);
  Object.assign(transcript, real);
});

beforeEach(() => {
  store = new SessionSearchStore(":memory:");
  __setSessionSearchStoreForTest(store);
  epoch = 0;
  nextChange = 1;
  rows = new Map();
  reads = 0;
});

const ids = (query: string) =>
  store.searchTranscripts(query).map((match) => match.id);

test("pages through a long transcript, then applies only what changed", async () => {
  for (let seq = 1; seq <= 1_200; seq++) write(seq, `ordinary reply ${seq}`);
  write(1_201, "Cloudflare shipped Pi Durable");
  expect(await indexSessionTranscript("s", Date.now())).toEqual({
    applied: 1_201,
  });
  expect(reads).toBe(3);
  expect(ids("pi-durable")).toEqual(["s"]);

  reads = 0;
  expect(await indexSessionTranscript("s", Date.now())).toEqual({ applied: 0 });
  expect(reads).toBe(1);

  write(1_201, "rewritten without the phrase");
  write(1_202, "a new turn about watchdogs");
  expect(await indexSessionTranscript("s", Date.now())).toEqual({ applied: 2 });
  expect(ids("pi-durable")).toEqual([]);
  expect(ids("watchdogs")).toEqual(["s"]);
});

test("a reset epoch starts the session over", async () => {
  write(1, "before the reset");
  await indexSessionTranscript("s", Date.now());

  epoch = nextChange;
  rows = new Map();
  write(1, "after the reset");
  await indexSessionTranscript("s", Date.now());
  expect(ids("before")).toEqual([]);
  expect(ids("after")).toEqual(["s"]);
});

test("a transcript recreated under the same id and epoch starts over", async () => {
  for (let seq = 1; seq <= 5; seq++) write(seq, `old turn ${seq}`);
  await indexSessionTranscript("s", Date.now());
  nextChange = 1;
  rows = new Map();
  write(1, "fresh start");
  await indexSessionTranscript("s", Date.now());
  expect(ids("old")).toEqual([]);
  expect(ids("fresh")).toEqual(["s"]);
});

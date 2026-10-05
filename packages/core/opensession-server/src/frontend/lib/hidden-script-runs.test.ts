import { beforeEach, expect, test } from "bun:test";

const store = new Map<string, string>();
Object.assign(globalThis, {
  localStorage: {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => void store.set(key, value),
    removeItem: (key: string) => void store.delete(key),
  },
});

const { hiddenScriptRunIds, hideScriptRun } =
  await import("./hidden-script-runs");
const DAY = 24 * 60 * 60_000;

beforeEach(() => store.clear());

test("a hidden run stays hidden", () => {
  hideScriptRun("run-a", 1_000);
  hideScriptRun("run-b", 2_000);
  expect([...hiddenScriptRunIds(3_000)].sort()).toEqual(["run-a", "run-b"]);
});

test("hides expire after a week and are pruned on the next write", () => {
  hideScriptRun("old", 0);
  expect(hiddenScriptRunIds(8 * DAY).has("old")).toBe(false);
  hideScriptRun("new", 8 * DAY);
  expect(Object.keys(JSON.parse(store.values().next().value!))).toEqual([
    "new",
  ]);
});

test("unreadable storage hides nothing", () => {
  store.set("opensession-hidden-script-runs", "{not json");
  expect(hiddenScriptRunIds().size).toBe(0);
});

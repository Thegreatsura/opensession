import { describe, expect, test } from "bun:test";
import { placeActiveOrder, sortActiveRows } from "./active-order";

const row = (key: string, createdAt: string) => ({
  key,
  workspace: null,
  createdAt,
  sessions: [],
});

describe("active order", () => {
  const a = row("a", "2026-01-01T00:00:00Z");
  const b = row("b", "2026-01-02T00:00:00Z");
  const c = row("c", "2026-01-03T00:00:00Z");

  test("without a saved order, newest work is first", () => {
    expect(sortActiveRows([a, b, c], []).map((r) => r.key)).toEqual([
      "c",
      "b",
      "a",
    ]);
  });

  test("placed rows keep their saved order under new work", () => {
    const d = row("d", "2026-01-04T00:00:00Z");
    expect(
      sortActiveRows([a, b, c, d], ["a", "c", "b"]).map((r) => r.key),
    ).toEqual(["d", "a", "c", "b"]);
  });

  test("a drop leads with the section and keeps other saved keys", () => {
    expect(placeActiveOrder(["x", "a", "y", "b"], ["b", "a"])).toEqual([
      "b",
      "a",
      "x",
      "y",
    ]);
  });
});

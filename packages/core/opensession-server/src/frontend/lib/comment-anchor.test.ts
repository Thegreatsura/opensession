import { describe, expect, test } from "bun:test";
import { anchorFromOffsets, locateAnchor } from "./comment-anchor";
import { stackCards } from "./comment-layout";

describe("comment anchors", () => {
  const text = "Run it on Sunday. Tests pass. Run it on Sunday again later.";

  test("captures the words with context and trims whitespace", () => {
    const start = text.indexOf("Tests") - 1;
    const anchor = anchorFromOffsets(text, start, start + 12, "e1");
    expect(anchor).toEqual({
      entryId: "e1",
      exact: "Tests pass.",
      prefix: "Run it on Sunday. ",
      suffix: " Run it on Sunday again later.",
    });
  });

  test("a stray character is not a passage", () => {
    expect(anchorFromOffsets(text, 0, 1, "e1")).toBeNull();
    expect(anchorFromOffsets("a   b", 1, 4, "e1")).toBeNull();
  });

  test("repeated words resolve to the occurrence with the matching context", () => {
    const second = text.lastIndexOf("Run it on Sunday");
    const anchor = anchorFromOffsets(text, second, second + 16, "e1")!;
    expect(locateAnchor(text, anchor)).toEqual({
      start: second,
      end: second + 16,
    });
    const first = anchorFromOffsets(text, 0, 16, "e1")!;
    expect(locateAnchor(text, first)).toEqual({ start: 0, end: 16 });
  });

  test("context that drifted still finds the words", () => {
    expect(
      locateAnchor("Now: Tests pass, mostly.", {
        exact: "Tests pass",
        prefix: "Sunday. ",
        suffix: ". Run",
      }),
    ).toEqual({ start: 5, end: 15 });
  });

  test("words that are gone resolve to nothing", () => {
    expect(
      locateAnchor(text, { exact: "Monday", prefix: "", suffix: "" }),
    ).toBeNull();
  });
});

describe("margin card stacking", () => {
  test("cards keep their wanted position when they fit", () => {
    const tops = stackCards([
      { id: "a", want: 0, height: 50 },
      { id: "b", want: 100, height: 50 },
    ]);
    expect(tops.get("a")).toBe(0);
    expect(tops.get("b")).toBe(100);
  });

  test("overlapping cards push down in order", () => {
    const tops = stackCards([
      { id: "b", want: 10, height: 50 },
      { id: "a", want: 0, height: 50 },
    ]);
    expect(tops.get("a")).toBe(0);
    expect(tops.get("b")).toBe(58);
  });

  test("the active card stays level and the one above makes room", () => {
    const tops = stackCards(
      [
        { id: "a", want: 0, height: 100 },
        { id: "b", want: 40, height: 50 },
        { id: "c", want: 60, height: 50 },
      ],
      "b",
    );
    expect(tops.get("b")).toBe(40);
    expect(tops.get("a")).toBe(40 - 8 - 100);
    expect(tops.get("c")).toBe(40 + 50 + 8);
  });
});

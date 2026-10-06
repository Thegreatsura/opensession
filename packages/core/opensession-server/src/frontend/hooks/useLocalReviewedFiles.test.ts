import { describe, expect, test } from "bun:test";
import { filePatchHash, localReviewState } from "./useLocalReviewedFiles";

describe("local review state", () => {
  test("a file whose diff changed after review reads as changed", () => {
    const before = filePatchHash("diff --git a/a b/a\nindex 1..2\n+one\n");
    const sameContent = filePatchHash("diff --git a/a b/a\nindex 3..4\n+one\n");
    const after = filePatchHash("diff --git a/a b/a\nindex 1..2\n+two\n");
    expect(sameContent).toBe(before);
    const state = localReviewState(
      { a: before, b: "stale", gone: before },
      new Map([
        ["a", sameContent],
        ["b", after],
        ["c", after],
      ]),
    );
    expect([...state.reviewed]).toEqual(["a"]);
    expect([...state.changed]).toEqual(["b"]);
  });
});

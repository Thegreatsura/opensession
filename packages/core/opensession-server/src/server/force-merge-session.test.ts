import { describe, expect, test } from "bun:test";
import { forceMergeRefusal } from "./force-merge-session";

describe("forceMergeRefusal", () => {
  test("automation runs can never open a card", () => {
    expect(forceMergeRefusal({ automationId: "a1" }, "Ada", true)).toContain(
      "not available to automation runs",
    );
    expect(
      forceMergeRefusal({ automationDescendantPolicy: {} }, "Ada", true),
    ).toContain("not available to automation runs");
  });

  test("without GitHub sign-in nobody could confirm, so it refuses", () => {
    expect(forceMergeRefusal({}, "Ada", false)).toContain(
      "needs GitHub sign-in",
    );
  });

  test("an unknown driver cannot confirm", () => {
    expect(forceMergeRefusal({}, undefined, true)).toContain(
      "signed-in teammate",
    );
    expect(forceMergeRefusal({}, "nobody-on-the-roster", true)).toContain(
      "signed-in teammate",
    );
  });
});

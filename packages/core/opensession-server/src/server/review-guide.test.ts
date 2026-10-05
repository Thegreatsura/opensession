import { describe, expect, test } from "bun:test";
import { carryForward, changedSinceGuide, parseGuide } from "./review-guide";

describe("review guide", () => {
  test("maps model paths onto the diff and drops invented or repeated ones", () => {
    const sections = parseGuide(
      JSON.stringify({
        sections: [
          {
            title: "Core change",
            explanation: "Does the thing.",
            files: ["app.ts", "src/lib/util.ts", "made/up.ts"],
          },
          {
            title: "Tests",
            explanation: "Covers it.",
            files: ["src/lib/util.ts", "test/app.test.ts"],
          },
        ],
      }),
      ["src/app.ts", "src/lib/util.ts", "test/app.test.ts"],
    );
    expect(sections).toEqual([
      {
        title: "Core change",
        explanation: "Does the thing.",
        files: ["src/app.ts", "src/lib/util.ts"],
      },
      {
        title: "Tests",
        explanation: "Covers it.",
        files: ["test/app.test.ts"],
      },
    ]);
  });

  test("rejects output without sections", () => {
    expect(parseGuide("not json", ["a.ts"])).toBeNull();
    expect(parseGuide('{"sections":[]}', ["a.ts"])).toBeNull();
  });

  test("finds files new or changed since the guide", () => {
    expect(
      changedSinceGuide(
        { "a.ts": "1", "b.ts": "2", "gone.ts": "3" },
        { "a.ts": "1", "b.ts": "9", "new.ts": "4" },
      ),
    ).toEqual(["b.ts", "new.ts"]);
  });

  test("carries a guide forward without removed files or empty sections", () => {
    expect(
      carryForward(
        [
          { title: "One", explanation: "x", files: ["a.ts", "gone.ts"] },
          { title: "Two", explanation: "y", files: ["gone2.ts"] },
        ],
        new Set(["a.ts", "new.ts"]),
      ),
    ).toEqual([{ title: "One", explanation: "x", files: ["a.ts"] }]);
  });
});

import { describe, expect, it } from "bun:test";
import {
  MAX_PREDICTION_LENGTH,
  closingExchange,
  sanitizePrediction,
  styleSamples,
} from "./composer-prediction";

describe("sanitizePrediction", () => {
  it("keeps a plain one-line message", () => {
    expect(sanitizePrediction("fix both and push")).toBe("fix both and push");
  });

  it("treats NONE and empty answers as no prediction", () => {
    expect(sanitizePrediction("NONE")).toBeNull();
    expect(sanitizePrediction("none.")).toBeNull();
    expect(sanitizePrediction("")).toBeNull();
    expect(sanitizePrediction(null)).toBeNull();
  });

  it("strips quotes, role prefixes and em dashes", () => {
    expect(sanitizePrediction('"ship it"')).toBe("ship it");
    expect(sanitizePrediction("person: run the tests")).toBe("run the tests");
    expect(sanitizePrediction("looks good — merge it")).toBe(
      "looks good, merge it",
    );
  });

  it("drops a narrated preamble", () => {
    expect(sanitizePrediction("Here is the message:\nrun bun test")).toBe(
      "run bun test",
    );
  });

  it("rejects a paragraph", () => {
    expect(
      sanitizePrediction("x".repeat(MAX_PREDICTION_LENGTH + 1)),
    ).toBeNull();
  });
});

describe("styleSamples", () => {
  it("returns the person's recent typed messages, oldest first", () => {
    const entries = [
      { type: "user", content: "first" },
      { type: "assistant", content: "ok" },
      {
        type: "user",
        content: "<opensession:context>ignored</opensession:context>second",
      },
      { type: "tool_use", content: "" },
      { type: "user", content: "third" },
    ];
    expect(styleSamples(entries, 2)).toEqual(["second", "third"]);
  });
});

describe("closingExchange", () => {
  it("keeps the newest messages when the budget runs out", () => {
    const entries = [
      { type: "user", content: "old ".repeat(400) },
      { type: "assistant", content: "Want me to fix both?" },
    ];
    const out = closingExchange(entries, 200);
    expect(out.endsWith("agent: Want me to fix both?")).toBe(true);
  });

  it("skips tool traffic", () => {
    const out = closingExchange([
      { type: "user", content: "go" },
      { type: "tool_result", content: "secret output" },
      { type: "assistant", content: "Done." },
    ]);
    expect(out).toBe("person: go\nagent: Done.");
  });
});

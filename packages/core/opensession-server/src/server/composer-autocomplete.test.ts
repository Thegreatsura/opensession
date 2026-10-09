import { describe, expect, it } from "bun:test";
import {
  MAX_COMPLETION_CHARS,
  RATE_PER_MINUTE,
  sanitizeCompletion,
  takeAutocompleteSlot,
} from "./composer-autocomplete";

describe("sanitizeCompletion", () => {
  it("starts a new word with one space after a finished word", () => {
    expect(sanitizeCompletion("fix both but", " add tests")).toBe(" add tests");
    expect(sanitizeCompletion("fix both but", "   add tests")).toBe(
      " add tests",
    );
  });

  it("finishes a word in progress without a space", () => {
    expect(sanitizeCompletion("fix bo", "th issues")).toBe("th issues");
  });

  it("drops the leading space when the draft already ends with one", () => {
    expect(sanitizeCompletion("fix both ", " issues")).toBe("issues");
  });

  it("strips an echoed draft, newlines and em dashes", () => {
    expect(sanitizeCompletion("fix both", "fix both and push")).toBe(
      " and push",
    );
    expect(sanitizeCompletion("ok", " merge it\nand deploy")).toBe(" merge it");
    expect(sanitizeCompletion("ok", " merge it — then deploy")).toBe(
      " merge it, then deploy",
    );
  });

  it("returns null for nothing and caps a long answer at a word", () => {
    expect(sanitizeCompletion("done", "   ")).toBeNull();
    const long = sanitizeCompletion("go", ` ${"word ".repeat(80)}`);
    expect(long!.length).toBeLessThanOrEqual(MAX_COMPLETION_CHARS);
    expect(long!.endsWith(" ")).toBe(false);
  });
});

describe("takeAutocompleteSlot", () => {
  it("allows RATE_PER_MINUTE calls a minute per person", () => {
    const now = 1_000_000;
    for (let i = 0; i < RATE_PER_MINUTE; i++)
      expect(takeAutocompleteSlot("acme", now + i)).toBe(true);
    expect(takeAutocompleteSlot("acme", now + 100)).toBe(false);
    expect(takeAutocompleteSlot("other", now + 100)).toBe(true);
    expect(takeAutocompleteSlot("acme", now + 61_000)).toBe(true);
  });
});

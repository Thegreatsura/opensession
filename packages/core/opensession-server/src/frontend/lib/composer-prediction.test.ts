import { describe, expect, it } from "bun:test";
import { takesPrediction } from "./composer-prediction";

const tab = {
  key: "Tab",
  shiftKey: false,
  metaKey: false,
  ctrlKey: false,
  altKey: false,
};

describe("takesPrediction", () => {
  it("takes a bare Tab in an empty composer", () => {
    expect(takesPrediction(tab, "", "ship it")).toBe(true);
    expect(takesPrediction(tab, "  ", "ship it")).toBe(true);
  });

  it("leaves Tab alone with a draft, no prediction, or a modifier", () => {
    expect(takesPrediction(tab, "hi", "ship it")).toBe(false);
    expect(takesPrediction(tab, "", null)).toBe(false);
    expect(takesPrediction({ ...tab, shiftKey: true }, "", "ship it")).toBe(
      false,
    );
    expect(takesPrediction({ ...tab, key: "Enter" }, "", "ship it")).toBe(
      false,
    );
  });
});

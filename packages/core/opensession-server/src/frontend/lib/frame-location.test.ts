import { expect, test } from "bun:test";
import { FRAME_LOCATION_MESSAGE, frameLocationReport } from "./frame-location";

// SAFETY: the report only compares the source by identity.
const frame = {} as Window;
// SAFETY: as above.
const other = {} as Window;
const report = (href: string | number, origin = "https://a.example.test") => ({
  data: { type: FRAME_LOCATION_MESSAGE, href },
  origin,
  source: frame,
});

test("reads the page's own location", () => {
  expect(
    frameLocationReport(report("https://a.example.test/x?y=1"), frame),
  ).toBe("https://a.example.test/x?y=1");
});

test("ignores other windows, other origins, and other messages", () => {
  expect(
    frameLocationReport(report("https://a.example.test/"), other),
  ).toBeNull();
  expect(
    frameLocationReport(report("https://b.example.test/"), frame),
  ).toBeNull();
  expect(frameLocationReport(report("javascript:alert(1)"), frame)).toBeNull();
  expect(frameLocationReport(report(42), frame)).toBeNull();
  expect(
    frameLocationReport(
      { data: "hello", origin: "https://a.example.test", source: frame },
      frame,
    ),
  ).toBeNull();
});

import { describe, expect, test } from "bun:test";
import { summarizeGatewayProfile } from "./gateway-profiler";

const frame = (name: string, line = 1) => ({
  name,
  sourceURL: `/srv/app/packages/core/server/${name}.ts`,
  line,
});

describe("summarizeGatewayProfile", () => {
  test("splits busy samples into stretches and attributes the longest", () => {
    const traces = [
      // A 120 ms stretch inside buildList → stringify.
      ...Array.from({ length: 121 }, (_, i) => ({
        timestamp: 10 + i / 1000,
        frames: [{ name: "stringify" }, frame("buildList", 42)],
      })),
      // A short unrelated blip two seconds later.
      ...Array.from({ length: 5 }, (_, i) => ({
        timestamp: 12 + i / 1000,
        frames: [frame("tick")],
      })),
    ];
    const report = summarizeGatewayProfile(traces, 30_000);
    expect(report).toContain("126 busy samples");
    expect(report).toMatch(/ {2}120 ms at \+0\.0 s \(121 samples\)/);
    expect(report).toContain(
      "121\tbuildList packages/core/server/buildList.ts:42",
    );
    expect(report).toContain("leaf 121\tstringify [native]");
    expect(report).not.toMatch(/ms at \+2\.0 s/);
  });

  test("reports an idle window without stretches", () => {
    expect(summarizeGatewayProfile([], 30_000)).toContain("  none");
  });
});

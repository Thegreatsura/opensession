import { describe, expect, test } from "bun:test";
import {
  fileManifest,
  filePatchHashes,
  fitPatchToBudget,
  splitPatchByFile,
} from "./review-patch-budget";

function filePatch(path: string, lines: number, index = "abc..def") {
  const body = Array.from({ length: lines }, (_, i) => `+line ${i}`).join("\n");
  return `diff --git a/${path} b/${path}\nindex ${index} 100644\n--- a/${path}\n+++ b/${path}\n@@ -0,0 +1,${lines} @@\n${body}\n`;
}

describe("review patch budget", () => {
  test("splits files and counts their changes", () => {
    const files = splitPatchByFile(filePatch("a.ts", 3) + filePatch("b.ts", 1));
    expect(files.map((file) => [file.path, file.additions])).toEqual([
      ["a.ts", 3],
      ["b.ts", 1],
    ]);
    expect(fileManifest(files)).toBe("a.ts (+3 -0)\nb.ts (+1 -0)");
  });

  test("keeps a diff that fits untouched", () => {
    const patch = filePatch("a.ts", 3);
    expect(fitPatchToBudget(patch, 10_000)).toEqual({ patch, trimmed: false });
  });

  test("keeps every file when the diff is over budget", () => {
    const patch =
      filePatch("big.ts", 5_000) +
      filePatch("small.ts", 2) +
      filePatch("last.ts", 4_000);
    const fitted = fitPatchToBudget(patch, 6_000);
    expect(fitted.trimmed).toBe(true);
    expect(fitted.patch.length).toBeLessThan(7_000);
    expect(fitted.patch).toContain("diff --git a/last.ts b/last.ts");
    // A small file is never trimmed to make room for a large one.
    expect(fitted.patch).toContain(filePatch("small.ts", 2));
    expect(fitted.patch).toContain("more lines of this file omitted");
  });

  test("hashes ignore blob ids but see content changes", () => {
    const before = filePatchHashes(filePatch("a.ts", 3, "111..222"));
    expect(filePatchHashes(filePatch("a.ts", 3, "333..444"))).toEqual(before);
    expect(filePatchHashes(filePatch("a.ts", 4))["a.ts"]).not.toBe(
      before["a.ts"],
    );
  });
});

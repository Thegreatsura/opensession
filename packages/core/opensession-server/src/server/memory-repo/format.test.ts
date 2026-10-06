import { describe, expect, test } from "bun:test";
import {
  appendEntry,
  ensureIndexLink,
  extractLinks,
  linkTargetPath,
  parseEntryBody,
  parseMemoryFile,
  renderEntry,
  replaceLine,
} from "./format";
import { recordsForRepo, syntheticEntryId } from "./records";
import { locateScope, scopeForPath } from "./layout";
import { validateRepoFile } from "./validate";
import { findSecrets } from "./secrets";

describe("Agent Memory Repo format", () => {
  test("parses entries, merged metadata groups and prose", () => {
    const file = parseMemoryFile(
      "MEMORY.md",
      [
        "# Memory: Joe",
        "",
        "- Joe leads the product team [source: https://example.test/sessions/100]",
        "- Cause found [source: https://example.test/s/1] [source: https://example.test/s/2]",
        "Some prose that is not an entry.",
        "",
        "## Index",
        "- [[team_structure]]",
        "- Below the index [id: m-1]",
      ].join("\n"),
    );
    expect(file.entries.map((entry) => entry.text)).toEqual([
      "Joe leads the product team",
      "Cause found",
      "Below the index",
    ]);
    expect(file.entries[1].meta.source).toHaveLength(2);
    expect(file.entries.map((entry) => entry.pinned)).toEqual([
      true,
      true,
      false,
    ]);
    expect(file.problems).toEqual([]);
  });

  test("keeps link-only and text brackets out of metadata, flags malformed groups", () => {
    expect(parseEntryBody("See [[projects/payments]]")).toEqual({
      text: "See [[projects/payments]]",
      meta: {},
    });
    expect(parseEntryBody("Arrays look like [a, b]")).toEqual({
      text: "Arrays look like [a, b]",
      meta: {},
    });
    expect("error" in parseEntryBody("Broken [id: m-1; oops]")).toBe(true);
  });

  test("ignores bullets inside code fences", () => {
    const file = parseMemoryFile(
      "notes.md",
      "```\n- not an entry\n```\n- entry\n",
    );
    expect(file.entries.map((entry) => entry.text)).toEqual(["entry"]);
  });

  test("renders known keys first and round-trips", () => {
    const line = renderEntry("Uses bun; not npm", {
      tags: ["tooling"],
      id: ["m-1"],
      kind: ["preference"],
      weird: ["x]y;z"],
    });
    expect(line).toBe(
      "- Uses bun; not npm [id: m-1; kind: preference; tags: tooling; weird: x)y,z]",
    );
    const parsed = parseEntryBody(line.slice(2));
    expect(parsed).toEqual({
      text: "Uses bun; not npm",
      meta: {
        id: ["m-1"],
        kind: ["preference"],
        tags: ["tooling"],
        weird: ["x)y,z"],
      },
    });
  });

  test("appends into the pinned region and maintains the index", () => {
    let text = appendEntry("MEMORY.md", undefined, "- first [id: a]", {
      title: "# Memory: Team",
    });
    text = appendEntry("MEMORY.md", text, "- second [id: b]");
    text = ensureIndexLink(text, "gotchas");
    text = ensureIndexLink(text, "gotchas");
    expect(text).toBe(
      "# Memory: Team\n\n- first [id: a]\n- second [id: b]\n\n## Index\n- [[gotchas]]\n",
    );
    const file = parseMemoryFile("MEMORY.md", text);
    expect(file.entries.every((entry) => entry.pinned)).toBe(true);
    expect(replaceLine(file, file.entries[0].line, null)).toBe(
      "# Memory: Team\n\n- second [id: b]\n\n## Index\n- [[gotchas]]\n",
    );
  });

  test("links resolve from the memory root", () => {
    expect(extractLinks("see [[projects/payments]] and [[q/x.sql]]")).toEqual([
      "projects/payments",
      "q/x.sql",
    ]);
    expect(linkTargetPath("projects/payments")).toBe("projects/payments.md");
    expect(linkTargetPath("q/x.sql")).toBe("q/x.sql");
  });
});

describe("layout", () => {
  test("maps scopes to repositories and folders", () => {
    expect(locateScope("workspace")).toEqual({ repo: "team", dir: "" });
    expect(locateScope("repo-acme")).toEqual({
      repo: "team",
      dir: "repos/acme",
    });
    expect(locateScope("user-U123ABC")).toEqual({
      repo: "user-U123ABC",
      dir: "",
    });
    expect(locateScope("repo-../etc")).toBeNull();
    expect(scopeForPath("team", "repos/acme/ci.md")).toBe("repo-acme");
    expect(scopeForPath("team", "release.md")).toBe("workspace");
    expect(scopeForPath("user-U1", "notes/x.md")).toBe("user-U1");
  });
});

describe("index records", () => {
  test("derives tiers, kinds, details from linked notes, and synthetic ids", () => {
    const { records } = recordsForRepo(
      "team",
      [
        {
          path: "repos/acme/MEMORY.md",
          text: "# Memory: acme\n\n- Pinned fact [id: m-1; kind: decision]\n\n## Index\n- [[repos/acme/ci]]\n",
        },
        {
          path: "repos/acme/ci.md",
          text: "# CI\n\n- CI is slow; see [[repos/acme/notes/ci]] [kind: gotcha; added: 2026-09-01]\n- Status without expiry [kind: status]\n",
        },
        { path: "repos/acme/notes/ci.md", text: "# CI notes\n\nLong story.\n" },
        { path: "queries/keep_rate.sql", text: "-- keep rate\nSELECT 1;\n" },
      ],
      {
        fallbackTime: "2026-10-01T00:00:00.000Z",
        now: new Date("2026-10-05T00:00:00Z"),
      },
    );
    const byText = new Map(records.map((record) => [record.summary, record]));
    expect(byText.get("Pinned fact")).toMatchObject({
      id: "m-1",
      tier: "pinned",
      kind: "decision",
      scopeKey: "repo-acme",
    });
    const slow = byText.get("CI is slow; see [[repos/acme/notes/ci]]")!;
    expect(slow.id).toBe(syntheticEntryId("repos/acme/ci.md", slow.summary));
    expect(slow.details).toContain("Long story.");
    expect(slow.createdAt).toBe("2026-09-01T00:00:00.000Z");
    expect(byText.get("Status without expiry")!.kind).toBe("reference");
    // The linked note is not indexed on its own; the saved query is.
    expect(
      records.some((record) => record.path === "repos/acme/notes/ci.md"),
    ).toBe(false);
    expect(
      records.find((record) => record.path === "queries/keep_rate.sql"),
    ).toMatchObject({
      scopeKey: "workspace",
      tags: ["saved-file"],
    });
  });
});

describe("push validation", () => {
  const bytes = (text: string) => new TextEncoder().encode(text);
  test("refuses credentials, binaries, executables and malformed entries", () => {
    const token = `ghp_${"a".repeat(36)}`;
    expect(findSecrets(`ok\nuse ${token}`)).toEqual([
      { name: "GitHub token", line: 1 },
    ]);
    expect(validateRepoFile("a.md", bytes(`- key ${token}`))[0].line).toBe(1);
    expect(validateRepoFile("b.bin", new Uint8Array([1, 0, 2]))).toHaveLength(
      1,
    );
    expect(validateRepoFile("run.sh", bytes("echo hi"), "100755")).toHaveLength(
      1,
    );
    expect(
      validateRepoFile("c.md", bytes("- x [kind: vibe]"))[0].message,
    ).toContain("Unknown kind");
    expect(
      validateRepoFile("d.md", bytes("- x [added: soon]"))[0].message,
    ).toContain("not a date");
    expect(
      validateRepoFile("e.md", bytes("- fine [id: m-1; kind: gotcha]")),
    ).toEqual([]);
  });
});

test("index links are inserted in alphabetical order", () => {
  let text = ensureIndexLink(undefined, "reference");
  text = ensureIndexLink(text, "repos/acme/MEMORY");
  text = ensureIndexLink(text, "decisions");
  expect(text).toBe(
    "# Memory\n\n## Index\n- [[decisions]]\n- [[reference]]\n- [[repos/acme/MEMORY]]\n",
  );
});

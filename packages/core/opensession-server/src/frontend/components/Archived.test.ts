import { expect, test } from "bun:test";
import type { UnifiedSession } from "../lib/types";
import { archivedMatchesSearch } from "./Archived";
import {
  archivedResults,
  conversationResults,
  searchArchived,
} from "./SessionSearch";

function row(over: Partial<UnifiedSession> = {}): UnifiedSession {
  // SAFETY: the matchers under test read only the fields set here.
  return {
    id: "os-0001-acme",
    source: "opensession",
    title: "Reduce GPU costs",
    branch: "how-many-t4-gpus",
    repo: "acme-app",
    startedBy: "Ada",
    lastActivity: "2026-01-01T00:00:00.000Z",
    archived: true,
    ...over,
  } as UnifiedSession;
}

test("archive search matches the title, branch, repo, owner and id", () => {
  const s = row();
  expect(archivedMatchesSearch(s, "gpu")).toBe(true);
  expect(archivedMatchesSearch(s, "T4")).toBe(true);
  expect(archivedMatchesSearch(s, "acme-app")).toBe(true);
  expect(archivedMatchesSearch(s, "ada")).toBe(true);
  expect(archivedMatchesSearch(s, " os-0001-acme ")).toBe(true);
  expect(archivedMatchesSearch(s, "billing")).toBe(false);
  expect(archivedMatchesSearch(s, "   ")).toBe(true);
});

test("archive search reads branch separators as spaces and matches every word", () => {
  const s = row({ title: "Debug review" });
  expect(archivedMatchesSearch(s, "how many t4")).toBe(true);
  expect(archivedMatchesSearch(s, "t4 gpus")).toBe(true);
  expect(archivedMatchesSearch(s, "gpus t4")).toBe(true);
  expect(archivedMatchesSearch(s, "t4 billing")).toBe(false);
});

test("the command menu finds archived sessions by branch", () => {
  const byBranch = row();
  const unrelated = row({ id: "os-0003-acme", title: "Docs", branch: "docs" });
  expect(searchArchived("t4", [byBranch, unrelated])).toEqual([
    { session: byBranch, metaMatch: true },
  ]);
  expect(searchArchived("", [byBranch, unrelated])).toEqual([]);
});

test("conversation hits keep the server's order across live and archived", () => {
  const live = row({ id: "os-live", title: "Live work", archived: false });
  const archived = row({ id: "os-archived", title: "Explore Cloudflare" });
  const listed = row({ id: "os-listed", title: "Already shown" });
  const snippets = new Map([
    ["os-archived", "…Pi Durable in the agents SDK…"],
    ["os-listed", "…pi durable…"],
    ["os-gone", "…not in the pool…"],
    ["os-live", "…durable pi…"],
  ]);
  const rows = conversationResults(
    snippets,
    [live, archived, listed],
    new Set(["session:os-listed"]),
  );
  expect(
    rows.map((r) => (r.type === "session" ? [r.session.id, r.snippet] : r)),
  ).toEqual([
    ["os-archived", "…Pi Durable in the agents SDK…"],
    ["os-live", "…durable pi…"],
  ]);
  expect(rows.every((r) => r.category === "In conversations")).toBe(true);
});

test("archive search matches the workspace name the sidebar showed", () => {
  const s = row({
    title: "Debug review",
    branch: "fix-thing",
    workspaceName: "How many T4 GPUs do we use",
  });
  expect(archivedMatchesSearch(s, "t4 gpus")).toBe(true);
});

test("the command menu lists an archived workspace by its name", () => {
  const ws = {
    workspaceId: "ws-t4",
    workspaceName: "How many T4 GPUs do we use",
  };
  const pool = [
    row({ id: "os-a", title: "Debug review", ...ws }),
    row({ id: "os-b", title: "Reduce GPU costs", ...ws }),
    row({ id: "os-c", title: "T4 pricing notes", ...ws }),
  ];
  const results = archivedResults("t4", pool, new Set(), new Map());
  expect(results[0]).toMatchObject({
    type: "workspace",
    category: "Archived",
    workspace: { id: "ws-t4", name: "How many T4 GPUs do we use" },
  });
  // Sessions the workspace row covers stay folded into it, unless their own
  // title matches too.
  expect(
    results.slice(1).map((r) => (r.type === "session" ? r.session.id : r.type)),
  ).toEqual(["os-c"]);
  // A workspace with live sessions is the live group's to show.
  expect(
    archivedResults("t4", pool, new Set(["ws-t4"]), new Map())[0],
  ).toMatchObject({ type: "session" });
});

test("a hyphenated query finds a title written with spaces", () => {
  const s = row({ title: "Explore Pi Durable objects", branch: "explore" });
  expect(searchArchived("pi-durable", [s]).map((h) => h.session)).toEqual([s]);
});

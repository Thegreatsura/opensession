import { expect, test } from "bun:test";
import { reviewLines } from "./review-lines";
import type { PrDetails, UnifiedSession } from "./types";

type ReviewPr = Pick<PrDetails, "state" | "reviewers">;
type ReviewRequest = NonNullable<UnifiedSession["reviewRequest"]>;

const team = {
  name: "Core team",
  github: "acme/core",
  members: ["Ada", "Grace"],
};

test("a team review request is one row, not the team plus its members", () => {
  const pr: ReviewPr = {
    state: "OPEN",
    reviewers: [{ login: "acme/core", state: "PENDING", isTeam: true }],
  };
  const lines = reviewLines(pr, null, ["ada", "grace", "linus"], [team]);
  expect(lines.map((line) => [line.name, line.state, !!line.team])).toEqual([
    ["Core team", "Awaiting review", true],
    ["Linus", "Awaiting review", false],
  ]);
  expect(lines[0]?.requested && lines[0]?.human).toBe(true);
});

test("an Open Session team request folds onto GitHub's team request", () => {
  const pr: ReviewPr = {
    state: "OPEN",
    reviewers: [{ login: "acme/core", state: "PENDING", isTeam: true }],
  };
  const request: ReviewRequest = {
    to: "acme/core",
    recipients: ["Ada", "Grace"],
    by: "Linus",
    at: "2026-01-01T00:00:00Z",
  };
  const lines = reviewLines(pr, request, ["ada", "grace"], [team]);
  expect(lines.map((line) => [line.name, line.state])).toEqual([
    ["Core team", "Review asked"],
  ]);
});

test("a member's own verdict still shows beside the team", () => {
  const pr: ReviewPr = {
    state: "OPEN",
    reviewers: [
      { login: "acme/core", state: "PENDING", isTeam: true },
      { login: "ada-gh", state: "APPROVED" },
    ],
  };
  const lines = reviewLines(pr, null, ["ada", "grace"], [team]);
  expect(lines.map((line) => line.state)).toEqual([
    "Awaiting review",
    "Approved",
  ]);
});

test("no pull request means no reviewer rows", () => {
  expect(reviewLines(null, null, ["ada"], [team])).toEqual([]);
});

test("a reviewer who only commented is not the requested slot", () => {
  const pr: ReviewPr = {
    state: "OPEN",
    reviewers: [
      { login: "ada-gh", state: "COMMENTED" },
      { login: "grace-gh", state: "PENDING" },
    ],
  };
  const lines = reviewLines(pr, null, [], [team]);
  expect(lines.map((line) => line.requested)).toEqual([false, true]);
});

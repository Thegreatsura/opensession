import { describe, expect, test } from "bun:test";
import {
  evaluateApprovalGate,
  latestDecisiveReviews,
  normalizeApprovalGateConfig,
  type GateInput,
} from "./approval-gate-policy";
import type { LastReviewState } from "./state";

const HEAD = "a".repeat(40);
const OLD = "b".repeat(40);

function review(over: Partial<LastReviewState> = {}): LastReviewState {
  return {
    verdict: "approve",
    confidence: 5,
    risk: "low",
    findings: 0,
    blocking: 0,
    sha: HEAD,
    at: "2026-10-08T00:00:00.000Z",
    ...over,
  };
}

function input(over: Partial<GateInput> = {}): GateInput {
  return {
    headSha: HEAD,
    author: "alice",
    fromFork: false,
    files: ["src/app.ts"],
    filesComplete: true,
    lastReview: review(),
    reviews: [],
    approvers: new Set(["bob", "carol"]),
    humanPaths: [".github/**", "infra/**"],
    matchGlob: (glob, path) => new Bun.Glob(glob).match(path),
    ...over,
  };
}

const approve = (login: string, commitId = HEAD) => ({
  login,
  userType: "User",
  state: "APPROVED",
  commitId,
});

function outcome(i: GateInput) {
  const r = evaluateApprovalGate(i);
  return r.status === "completed" ? r.conclusion : r.status;
}

describe("approval gate policy", () => {
  test("a 5/5, low-risk, approving review of the head passes", () => {
    const r = evaluateApprovalGate(input());
    expect(r).toMatchObject({ status: "completed", conclusion: "success" });
    expect(r.title).toBe("OS review: approve · 5/5 · risk low");
  });

  test("anything short of approve, 5/5, low risk and no blockers needs a human", () => {
    for (const over of [
      { confidence: 4 },
      { risk: "medium" as const },
      { risk: undefined },
      { verdict: "comment" },
      { blocking: 1 },
    ]) {
      const r = evaluateApprovalGate(input({ lastReview: review(over) }));
      expect(r).toMatchObject({ conclusion: "action_required" });
      expect(r.title).toStartWith("Needs a human approval: OS review");
    }
  });

  test("a review of an older head, or none, waits", () => {
    expect(outcome(input({ lastReview: review({ sha: OLD }) }))).toBe(
      "in_progress",
    );
    expect(outcome(input({ lastReview: null }))).toBe("in_progress");
  });

  test("a human approval of the head passes whatever the review says", () => {
    const r = evaluateApprovalGate(
      input({
        lastReview: review({ confidence: 2, risk: "high" }),
        reviews: [approve("bob")],
      }),
    );
    expect(r).toMatchObject({ conclusion: "success" });
    expect(r.title).toBe("Approved by @bob");
    // ...including with no review at all, or on a human-review path.
    expect(
      outcome(
        input({
          lastReview: null,
          files: [".github/workflows/ci.yml"],
          reviews: [approve("bob")],
        }),
      ),
    ).toBe("success");
  });

  test("approvals count only on the head, from approvers other than the author", () => {
    const low = review({ confidence: 3 });
    expect(
      outcome(input({ lastReview: low, reviews: [approve("bob", OLD)] })),
    ).toBe("action_required");
    expect(
      evaluateApprovalGate(
        input({ lastReview: low, reviews: [approve("bob", OLD)] }),
      ).summary,
    ).toContain("older commit");
    // Not in the approver set (no write access, or a bot).
    expect(
      outcome(input({ lastReview: low, reviews: [approve("mallory")] })),
    ).toBe("action_required");
    // The author never counts, even if the caller listed them.
    expect(
      outcome(
        input({
          lastReview: low,
          approvers: new Set(["alice"]),
          reviews: [approve("alice")],
        }),
      ),
    ).toBe("action_required");
  });

  test("an outstanding change request blocks both paths", () => {
    const changes = {
      login: "carol",
      userType: "User",
      state: "CHANGES_REQUESTED",
      commitId: OLD,
    };
    const r = evaluateApprovalGate(
      input({ reviews: [changes, approve("bob")] }),
    );
    expect(r).toMatchObject({ conclusion: "action_required" });
    expect(r.title).toBe("Changes requested by @carol");
    // A later comment does not clear it; a later approval or dismissal does.
    const comment = { ...changes, state: "COMMENTED", commitId: HEAD };
    expect(outcome(input({ reviews: [changes, comment] }))).toBe(
      "action_required",
    );
    expect(outcome(input({ reviews: [changes, approve("carol")] }))).toBe(
      "success",
    );
    expect(
      outcome(
        input({ reviews: [changes, { ...changes, state: "DISMISSED" }] }),
      ),
    ).toBe("success");
  });

  test("human-review paths, the review policy, forks and truncated file lists need a human", () => {
    for (const files of [
      [".github/workflows/validate.yml"],
      ["src/app.ts", "infra/main.tf"],
      [".os-review.json"],
    ]) {
      const r = evaluateApprovalGate(input({ files }));
      expect(r).toMatchObject({ conclusion: "action_required" });
      expect(r.title).toContain("human-review path");
    }
    expect(evaluateApprovalGate(input({ fromFork: true })).title).toBe(
      "Needs a human approval: opened from a fork",
    );
    expect(evaluateApprovalGate(input({ filesComplete: false })).title).toBe(
      "Needs a human approval: too many files to check",
    );
  });

  test("latest decisive review per login ignores comments and pending reviews", () => {
    const latest = latestDecisiveReviews([
      approve("Bob"),
      { login: "bob", userType: "User", state: "COMMENTED", commitId: HEAD },
      { login: "bob", userType: "User", state: "PENDING", commitId: HEAD },
    ]);
    expect(latest.get("bob")?.state).toBe("APPROVED");
  });
});

describe("approval gate config", () => {
  test("off unless configured", () => {
    expect(normalizeApprovalGateConfig(undefined)).toBeNull();
    expect(normalizeApprovalGateConfig(false)).toBeNull();
    expect(normalizeApprovalGateConfig({ enabled: false })).toBeNull();
    expect(normalizeApprovalGateConfig([])).toBeNull();
  });

  test("true or an object enables it", () => {
    expect(normalizeApprovalGateConfig(true)).toEqual({
      checkName: "OS approval gate",
      humanPaths: [],
    });
    expect(
      normalizeApprovalGateConfig({
        checkName: "  Gate ",
        humanPaths: ["infra/**", 3, ""],
      }),
    ).toEqual({ checkName: "Gate", humanPaths: ["infra/**"] });
  });
});

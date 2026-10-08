/**
 * Approval gate policy: the pure decision behind the "OS approval gate" check
 * (approval-gate.ts posts it). A repository that requires this check in its
 * default-branch ruleset can drop the blanket "one approving review" rule:
 *
 *   - the OS review of the CURRENT head is approve, quality 5/5, merge risk
 *     low, with no blocking findings, and the PR touches no human-review
 *     path → success; or
 *   - a human with write access, who is neither the author nor a bot, has
 *     approved the current head, and no such human's latest review requests
 *     changes → success;
 *   - a PR from a fork, or one touching a human-review path, never passes on
 *     the model review alone;
 *   - no review of this head yet → in progress (blocks like a running check);
 *   - anything else → action_required, with the reason in the title.
 *
 * The model review can make the gate pass only inside the policy the
 * repository wrote on its default branch. `.os-review.json` is always a
 * human-review path: its rules can override the review's verdict and scores,
 * and the review reads them from the PR head, so a PR that edits them must
 * not be able to approve itself.
 *
 * Enabled per repository from `.os-review.json` on the default branch:
 *
 *   "approvalGate": {
 *     "checkName": "OS approval gate",        // optional
 *     "humanPaths": [".github/**", "infra/**"] // globs that always need a human
 *   }
 *
 * `"approvalGate": true` enables it with no extra human-review paths.
 */
import type { LastReviewState } from "./state";

export const DEFAULT_GATE_CHECK_NAME = "OS approval gate";
/** Always human-review: the review policy itself. */
export const ALWAYS_HUMAN_PATHS = [".os-review.json"];

export interface ApprovalGateConfig {
  checkName: string;
  humanPaths: string[];
}

/** Parse the `approvalGate` key of `.os-review.json`. Null = gate off. */
export function normalizeApprovalGateConfig(
  raw: unknown,
): ApprovalGateConfig | null {
  if (raw === true) return { checkName: DEFAULT_GATE_CHECK_NAME, humanPaths: [] };
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const o = raw as Record<string, unknown>;
  if (o.enabled === false) return null;
  const name =
    typeof o.checkName === "string" && o.checkName.trim()
      ? o.checkName.trim().slice(0, 100)
      : DEFAULT_GATE_CHECK_NAME;
  const humanPaths = Array.isArray(o.humanPaths)
    ? o.humanPaths.filter(
        (g): g is string => typeof g === "string" && !!g.trim(),
      )
    : [];
  return { checkName: name, humanPaths };
}

/** One formal PR review, as GitHub lists them (chronological). */
export interface GateReview {
  login: string;
  /** "User" or "Bot". */
  userType: string;
  /** APPROVED | CHANGES_REQUESTED | COMMENTED | DISMISSED | PENDING. */
  state: string;
  commitId: string;
}

export interface GateInput {
  headSha: string;
  author: string;
  /** The head lives in another repository: an outside contributor, whose PR
   *  the model alone never clears. */
  fromFork: boolean;
  /** Paths the PR changes (renames list both sides). */
  files: string[];
  /** False when GitHub truncated the file list: paths cannot be cleared. */
  filesComplete: boolean;
  lastReview?: LastReviewState | null;
  reviews: GateReview[];
  /** Logins allowed to approve: write access, not a bot, not the author. */
  approvers: ReadonlySet<string>;
  humanPaths: string[];
  /** Matches a path against one glob; injected so the policy stays pure. */
  matchGlob: (glob: string, path: string) => boolean;
}

export type GateResult =
  | { status: "in_progress"; title: string; summary: string }
  | {
      status: "completed";
      conclusion: "success" | "action_required";
      title: string;
      summary: string;
    };

/** The latest decisive review per login, as GitHub counts them: a comment
 *  does not replace an earlier approval or change request; a dismissal does. */
export function latestDecisiveReviews(
  reviews: GateReview[],
): Map<string, GateReview> {
  const latest = new Map<string, GateReview>();
  for (const r of reviews) {
    const key = r.login.toLowerCase();
    if (!key) continue;
    if (
      r.state === "APPROVED" ||
      r.state === "CHANGES_REQUESTED" ||
      r.state === "DISMISSED"
    )
      latest.set(key, r);
  }
  return latest;
}

/** The human-review paths a PR touches, in file order. */
export function humanPathsTouched(
  files: string[],
  globs: string[],
  matchGlob: GateInput["matchGlob"],
): string[] {
  const all = [...ALWAYS_HUMAN_PATHS, ...globs];
  return files.filter((f) => all.some((g) => g === f || matchGlob(g, f)));
}

function short(sha: string): string {
  return sha.slice(0, 7);
}

function list(items: string[], max = 5): string {
  const shown = items.slice(0, max).map((s) => `\`${s}\``);
  const more = items.length > max ? ` and ${items.length - max} more` : "";
  return shown.join(", ") + more;
}

function reviewLabel(r: LastReviewState): string {
  const verdict = (r.verdict || "no verdict").replace(/_/g, " ");
  const quality =
    typeof r.confidence === "number" ? `${r.confidence}/5` : "no score";
  const risk = r.risk ? `risk ${r.risk}` : "no risk score";
  return `${verdict} · ${quality} · ${risk}`;
}

const HOW =
  "Passes when the OS review of the current head is approve, 5/5 and risk low and the PR touches no human-review path, or when someone with write access other than the author approves the current head.";

export function evaluateApprovalGate(input: GateInput): GateResult {
  const head = input.headSha;
  const latest = latestDecisiveReviews(input.reviews);
  const author = input.author.toLowerCase();
  const counted = [...latest.entries()].filter(
    ([login]) => login !== author && input.approvers.has(login),
  );

  const blockers = counted
    .filter(([, r]) => r.state === "CHANGES_REQUESTED")
    .map(([, r]) => `@${r.login}`);
  if (blockers.length) {
    return {
      status: "completed",
      conclusion: "action_required",
      title: `Changes requested by ${blockers.join(", ")}`,
      summary: `A human review requests changes. It stops blocking once that reviewer approves the current head or the review is dismissed.\n\n${HOW}`,
    };
  }

  const approvedBy = counted
    .filter(([, r]) => r.state === "APPROVED" && r.commitId === head)
    .map(([, r]) => `@${r.login}`);
  if (approvedBy.length) {
    return {
      status: "completed",
      conclusion: "success",
      title: `Approved by ${approvedBy.join(", ")}`,
      summary: `A human with write access approved \`${short(head)}\`.\n\n${HOW}`,
    };
  }
  const staleApproval = counted.some(([, r]) => r.state === "APPROVED");
  const reapprove = staleApproval
    ? "\n\nAn earlier approval was for an older commit; approvals count only on the current head."
    : "";

  if (input.fromFork) {
    return {
      status: "completed",
      conclusion: "action_required",
      title: "Needs a human approval: opened from a fork",
      summary: `Pull requests from other repositories always need a human approval.${reapprove}\n\n${HOW}`,
    };
  }

  if (!input.filesComplete) {
    return {
      status: "completed",
      conclusion: "action_required",
      title: "Needs a human approval: too many files to check",
      summary: `GitHub listed only part of this PR's files, so the human-review paths cannot be ruled out.${reapprove}\n\n${HOW}`,
    };
  }

  const reserved = humanPathsTouched(
    input.files,
    input.humanPaths,
    input.matchGlob,
  );
  if (reserved.length) {
    return {
      status: "completed",
      conclusion: "action_required",
      title: `Needs a human approval: touches ${reserved.length === 1 ? "a human-review path" : `${reserved.length} human-review paths`}`,
      summary: `Changes to ${list(reserved)} always need a human approval, whatever the OS review says.${reapprove}\n\n${HOW}`,
    };
  }

  const review = input.lastReview;
  if (!review || review.sha !== head) {
    return {
      status: "in_progress",
      title: `Waiting for the OS review of ${short(head)}`,
      summary: `${review ? `The last OS review was of \`${short(review.sha)}\`. ` : ""}This check updates when the review of \`${short(head)}\` finishes, or when someone approves.${reapprove}\n\n${HOW}`,
    };
  }

  const passes =
    review.verdict === "approve" &&
    review.confidence === 5 &&
    review.risk === "low" &&
    review.blocking === 0;
  if (passes) {
    return {
      status: "completed",
      conclusion: "success",
      title: `OS review: ${reviewLabel(review)}`,
      summary: `The OS review of \`${short(head)}\` cleared the automatic path: approve, 5/5, risk low, no blocking findings, no human-review paths.\n\n${HOW}`,
    };
  }
  return {
    status: "completed",
    conclusion: "action_required",
    title: `Needs a human approval: OS review ${reviewLabel(review)}`,
    summary: `The OS review of \`${short(head)}\` did not clear the automatic path (it needs approve, 5/5, risk low and no blocking findings${review.blocking ? `; this review has ${review.blocking} blocking` : ""}).${reapprove}\n\n${HOW}`,
  };
}

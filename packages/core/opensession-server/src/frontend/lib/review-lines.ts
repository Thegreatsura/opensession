import { isBotAuthor } from "./pr-comments";
import {
  personNameForGithubLogin,
  personNameForKey,
  type ReviewTeam,
} from "./people";
import type { PrDetails, PrReviewer, UnifiedSession } from "./types";

/** What a reviewer's GitHub state says, in words and a tone token. */
export function reviewerVerdict(state: PrReviewer["state"]) {
  switch (state) {
    case "APPROVED":
      return { label: "Approved", tone: "green" };
    case "CHANGES_REQUESTED":
      return { label: "Requested changes", tone: "red" };
    case "COMMENTED":
      return { label: "Commented", tone: "muted" };
    default:
      return { label: "Awaiting review", tone: "yellow" };
  }
}

export type ReviewLine = {
  key: string;
  name: string;
  login?: string;
  state: string;
  tone: string;
  human: boolean;
  /** A GitHub team rather than one person; drawn with the team glyph. */
  team?: boolean;
  /** This person was asked to review, here or on GitHub. The reviewer picker
   *  hangs on this row; a row that merely commented is a fact, not a slot. */
  requested: boolean;
};

/**
 * A team request is one fact, so it is one row. GitHub requests the team and
 * Open Session expands it to its members for "asked of me", which used to put
 * the team and every member on the card as separate "Awaiting review" rows.
 */
export function reviewLines(
  pr: Pick<PrDetails, "state" | "reviewers"> | null,
  request: UnifiedSession["reviewRequest"] | null | undefined,
  prReviewRequested: string[] | undefined,
  teams: ReviewTeam[] = [],
): ReviewLine[] {
  if (!pr) return [];

  const lines: ReviewLine[] = [];
  const seen = new Map<string, ReviewLine>();
  const add = (line: ReviewLine) => {
    const existing = seen.get(line.key);
    if (existing) return existing;
    seen.set(line.key, line);
    lines.push(line);
    return line;
  };
  const teamFor = (spec: string) => {
    const lower = spec.toLowerCase();
    return teams.find(
      (team) =>
        team.github.toLowerCase() === lower ||
        team.github.toLowerCase().split("/").pop() === lower,
    );
  };
  const teamKey = (spec: string) =>
    `team:${(teamFor(spec)?.github || spec).toLowerCase()}`;
  // Members a standing team request already speaks for.
  const coveredByTeam = new Set<string>();
  const coverTeam = (spec: string) => {
    for (const member of teamFor(spec)?.members || [])
      coveredByTeam.add(personNameForKey(member).toLowerCase());
  };

  // Whoever we asked, first: this is the row whose picker can change the
  // current request while the connected pull request is still visible.
  const requestState = request?.accepted ? "Signed off" : "Review asked";
  const requestTone = request?.accepted ? "text-green" : "text-dim";
  const requestTeam = request?.to ? teamFor(request.to) : undefined;
  if (request?.to && (requestTeam || request.recipients?.length)) {
    coverTeam(request.to);
    for (const member of requestTeam ? [] : request.recipients || [])
      coveredByTeam.add(personNameForKey(member).toLowerCase());
    add({
      key: teamKey(request.to),
      name: requestTeam?.name || request.to,
      state: requestState,
      tone: requestTone,
      human: true,
      team: true,
      requested: true,
    });
  } else if (request?.to) {
    const name = personNameForKey(request.to);
    add({
      key: name.toLowerCase(),
      name,
      state: requestState,
      tone: requestTone,
      human: true,
      requested: true,
    });
  }
  const openReviewers = pr.state === "OPEN" ? pr.reviewers || [] : [];
  for (const reviewer of openReviewers) {
    if (!reviewer.isTeam || reviewer.state !== "PENDING") continue;
    coverTeam(reviewer.login);
    add({
      key: teamKey(reviewer.login),
      name: teamFor(reviewer.login)?.name || reviewer.login,
      state: "Awaiting review",
      tone: "text-dim",
      human: true,
      team: true,
      requested: true,
    });
  }
  for (const key of prReviewRequested || []) {
    if (!key) continue;
    const name = personNameForKey(key);
    if (coveredByTeam.has(name.toLowerCase())) continue;
    add({
      key: name.toLowerCase(),
      name,
      state: "Awaiting review",
      tone: "text-dim",
      human: true,
      requested: true,
    });
  }

  // Then the PR's own, folded onto the same person where they match. Only
  // while it is open: once it lands the review is history, and the card is for
  // what is still live.
  if (pr?.state === "OPEN") {
    const byLogin = new Map<string, PrReviewer>();
    for (const reviewer of pr.reviewers || []) {
      const previous = byLogin.get(reviewer.login);
      if (!previous || previous.state === "PENDING")
        byLogin.set(reviewer.login, reviewer);
    }
    for (const reviewer of byLogin.values()) {
      if (reviewer.isTeam && reviewer.state === "PENDING") continue;
      const meta = reviewerVerdict(reviewer.state);
      const personName = reviewer.isTeam
        ? null
        : personNameForGithubLogin(reviewer.login);
      const name = personName || reviewer.login;
      const line = add({
        key: name.toLowerCase(),
        name,
        login: reviewer.isTeam ? undefined : reviewer.login,
        state: meta.label,
        tone: meta.tone === "muted" ? "text-dim" : `text-${meta.tone}`,
        human: !reviewer.isTeam && !isBotAuthor(reviewer.login),
        requested: reviewer.state === "PENDING",
      });
      // Merged onto a request row: keep the request's name, take GitHub's
      // verdict once there is one to take.
      if (line.state !== meta.label && reviewer.state !== "PENDING") {
        line.state = meta.label;
        line.tone = meta.tone === "muted" ? "text-dim" : `text-${meta.tone}`;
        line.login = line.login || reviewer.login;
      }
      line.human ||= !reviewer.isTeam && !isBotAuthor(reviewer.login);
      line.requested ||= reviewer.state === "PENDING";
    }
  }
  return lines;
}

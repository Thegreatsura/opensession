/**
 * Which memory repository and folder holds each memory scope.
 *
 * One repository per access boundary:
 *
 *   team          today's `workspace` scope at the root, and every
 *                 `repo-<id>` scope in `repos/<id>/`. Every teammate can read
 *                 and write both, so they share one repository.
 *   user-<id>     one personal repository per person.
 *   channel-<id>  one repository per private Slack channel.
 *
 * Scope keys stay the index's unit, so ranking, the Settings API and the
 * native app keep working on the same keys.
 */

import { ENTRY_POINT } from "./format";

export const TEAM_REPO = "team";

export interface ScopeLocation {
  /** Repository name, e.g. "team" or "user-U123". */
  repo: string;
  /** Folder inside the repository, "" for the root. No trailing slash. */
  dir: string;
}

const NAME = /^[A-Za-z0-9@._-]+$/;

export function isValidRepoName(name: string): boolean {
  return (
    (name === TEAM_REPO || /^(user|channel)-[A-Za-z0-9@._-]+$/.test(name)) &&
    !name.includes("..")
  );
}

export function locateScope(scopeKey: string): ScopeLocation | null {
  if (scopeKey === "workspace") return { repo: TEAM_REPO, dir: "" };
  const match = /^(repo|user|channel)-(.+)$/.exec(scopeKey);
  if (!match || !NAME.test(match[2]) || match[2].includes("..")) return null;
  if (match[1] === "repo") return { repo: TEAM_REPO, dir: `repos/${match[2]}` };
  return { repo: scopeKey, dir: "" };
}

/** The scope a file belongs to. */
export function scopeForPath(repo: string, path: string): string {
  if (repo !== TEAM_REPO) return repo;
  const match = /^repos\/([^/]+)\//.exec(path);
  if (match && NAME.test(match[1])) return `repo-${match[1]}`;
  return "workspace";
}

export function joinDir(dir: string, name: string): string {
  return dir ? `${dir}/${name}` : name;
}

/** The entry point whose pinned region holds a scope's pinned entries. */
export function entryPointFor(location: ScopeLocation): string {
  return joinDir(location.dir, ENTRY_POINT);
}

/** True when a path is the entry point of the scope it belongs to. */
export function isScopeEntryPoint(repo: string, path: string): boolean {
  const scope = scopeForPath(repo, path);
  const location = locateScope(scope);
  return !!location && entryPointFor(location) === path;
}

/** Default topic file for a kind of entry ("gotcha" -> "gotchas.md"). */
export function topicFileFor(location: ScopeLocation, kind: string): string {
  const name =
    kind === "reference"
      ? "reference.md"
      : kind === "status"
        ? "status.md"
        : `${kind}s.md`;
  return joinDir(location.dir, name);
}

export function notesDirFor(location: ScopeLocation): string {
  return joinDir(location.dir, "notes");
}

/** Repositories a run sees: team always, then each person's and channel's. */
export function reposForScopes(scopeKeys: string[]): string[] {
  const out: string[] = [];
  for (const key of scopeKeys) {
    const location = locateScope(key);
    if (location && !out.includes(location.repo)) out.push(location.repo);
  }
  return out;
}

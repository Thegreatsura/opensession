/**
 * Receive hooks for memory repositories. Installed by service.ts as
 * `hooks/pre-receive` and `hooks/post-receive` in each canonical bare
 * repository, so every push (a session's checkout, the service itself,
 * remote sync) passes through it.
 *
 *   pre-receive   refuses pushes that would break the repository for
 *                 everyone: other branches, deletions, oversized, binary or
 *                 executable files, credentials, unreadable entries.
 *   post-receive  records which session pushed which commits, from the push
 *                 options a session's checkout sends (`session=<id>`), or the
 *                 authenticated user of an HTTP push.
 *
 * Runs as its own short process. Never imported by the server.
 */

import { appendPushLog } from "./service";
import { EMPTY_TREE, git, readBlobs, ZERO_SHA } from "./git";
import { formatProblems, validateRepoFile, type FileProblem } from "./validate";

function hookEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value !== undefined) env[key] = value;
  }
  return env;
}

function pushOptions(): Record<string, string> {
  const out: Record<string, string> = {};
  const count = Number(process.env.GIT_PUSH_OPTION_COUNT || 0);
  for (let i = 0; i < count; i++) {
    const raw = process.env[`GIT_PUSH_OPTION_${i}`] || "";
    const eq = raw.indexOf("=");
    if (eq > 0) out[raw.slice(0, eq)] = raw.slice(eq + 1).slice(0, 200);
  }
  return out;
}

async function updates(): Promise<
  Array<{ old: string; next: string; ref: string }>
> {
  const input = await new Response(Bun.stdin.stream()).text();
  return input
    .split("\n")
    .map((line) => line.trim().split(/\s+/))
    .filter((parts) => parts.length === 3)
    .map(([old, next, ref]) => ({ old, next, ref }));
}

async function preReceive(gitDir: string): Promise<number> {
  const env = hookEnv();
  const problems: FileProblem[] = [];
  const refusals: string[] = [];
  for (const { old, next, ref } of await updates()) {
    if (ref !== "refs/heads/main") {
      refusals.push(
        `Only main can be pushed (got ${ref}). Commit on main and push again.`,
      );
      continue;
    }
    if (ZERO_SHA.test(next)) {
      refusals.push("Deleting main is not allowed.");
      continue;
    }
    const base = ZERO_SHA.test(old) ? EMPTY_TREE : old;
    const { stdout } = await git(
      [
        "--git-dir",
        gitDir,
        "diff-tree",
        "-r",
        "-z",
        "--no-renames",
        base,
        next,
      ],
      { env },
    );
    const parts = stdout.split("\0");
    const changed: Array<{ path: string; mode: string; sha: string }> = [];
    for (let i = 0; i + 1 < parts.length; i += 2) {
      const header = parts[i];
      const path = parts[i + 1];
      if (!header.startsWith(":")) {
        i -= 1;
        continue;
      }
      const [, newMode, , newSha, status] = header.slice(1).split(" ");
      if (status === "D") continue;
      changed.push({ path, mode: newMode, sha: newSha });
    }
    const blobs = await readBlobs(
      gitDir,
      changed.filter((file) => file.mode !== "160000").map((file) => file.sha),
      env,
    );
    for (const file of changed) {
      problems.push(
        ...validateRepoFile(
          file.path,
          blobs.get(file.sha) ?? new Uint8Array(),
          file.mode,
        ),
      );
    }
  }
  if (!refusals.length && !problems.length) return 0;
  console.error("Memory push rejected:");
  for (const refusal of refusals) console.error(`  ${refusal}`);
  if (problems.length)
    console.error(formatProblems(problems).replace(/^/gm, "  "));
  console.error("Fix it, commit, and push again.");
  return 1;
}

async function postReceive(gitDir: string): Promise<number> {
  const env = hookEnv();
  const options = pushOptions();
  for (const { old, next } of await updates()) {
    if (ZERO_SHA.test(next)) continue;
    const range = ZERO_SHA.test(old) ? [next] : [`${old}..${next}`];
    const { stdout } = await git(
      ["--git-dir", gitDir, "rev-list", "--max-count=500", ...range],
      { env, check: false },
    );
    await appendPushLog(gitDir, {
      at: new Date().toISOString(),
      old,
      new: next,
      commits: stdout.split("\n").filter(Boolean),
      session:
        options.session || process.env.OPENSESSION_MEMORY_SESSION || undefined,
      actor: options.actor || process.env.REMOTE_USER || undefined,
    }).catch(() => {});
  }
  return 0;
}

if (import.meta.main) {
  const hook = process.argv[2];
  const gitDir = process.env.GIT_DIR || process.cwd();
  const code =
    hook === "pre-receive"
      ? await preReceive(gitDir)
      : hook === "post-receive"
        ? await postReceive(gitDir)
        : 0;
  process.exit(code);
}

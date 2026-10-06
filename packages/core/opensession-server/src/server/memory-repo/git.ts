/**
 * Async git subprocess helper for memory repositories. Never synchronous:
 * every call is a Bun.spawn the caller awaits.
 */

export interface GitResult {
  code: number;
  stdout: string;
  stderr: string;
}

export class GitError extends Error {
  constructor(
    public readonly args: string[],
    public readonly result: GitResult,
  ) {
    super(
      `git ${args.join(" ")} failed (${result.code}): ${(result.stderr || result.stdout).trim().slice(0, 2000)}`,
    );
    this.name = "GitError";
  }
}

export const SERVICE_AUTHOR = {
  name: "Open Session",
  email: "memory@opensession.local",
};

/** Environment that ignores the machine's global git config and identity. */
export function isolatedGitEnv(
  extra: Record<string, string | undefined> = {},
): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value === undefined) continue;
    if (key.startsWith("GIT_")) continue;
    env[key] = value;
  }
  env.GIT_CONFIG_NOSYSTEM = "1";
  env.GIT_TERMINAL_PROMPT = "0";
  env.GIT_AUTHOR_NAME = SERVICE_AUTHOR.name;
  env.GIT_AUTHOR_EMAIL = SERVICE_AUTHOR.email;
  env.GIT_COMMITTER_NAME = SERVICE_AUTHOR.name;
  env.GIT_COMMITTER_EMAIL = SERVICE_AUTHOR.email;
  for (const [key, value] of Object.entries(extra)) {
    if (value === undefined) delete env[key];
    else env[key] = value;
  }
  return env;
}

export async function git(
  args: string[],
  opts: {
    cwd?: string;
    env?: Record<string, string>;
    input?: string | Uint8Array;
    timeoutMs?: number;
    check?: boolean;
  } = {},
): Promise<GitResult> {
  const proc = Bun.spawn(["git", ...args], {
    cwd: opts.cwd,
    env: opts.env ?? isolatedGitEnv(),
    stdin: opts.input === undefined ? "ignore" : "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });
  if (opts.input !== undefined && proc.stdin) {
    proc.stdin.write(opts.input);
    await proc.stdin.end();
  }
  const timer = setTimeout(
    () => proc.kill("SIGKILL"),
    opts.timeoutMs ?? 60_000,
  );
  try {
    const [stdout, stderr, code] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
      proc.exited,
    ]);
    const result = { code, stdout, stderr };
    if (opts.check !== false && code !== 0) throw new GitError(args, result);
    return result;
  } finally {
    clearTimeout(timer);
  }
}

/** Raw stdout bytes, for blob reads. */
export async function gitBytes(
  args: string[],
  opts: { cwd?: string; env?: Record<string, string>; input?: string } = {},
): Promise<Uint8Array> {
  const proc = Bun.spawn(["git", ...args], {
    cwd: opts.cwd,
    env: opts.env ?? isolatedGitEnv(),
    stdin: opts.input === undefined ? "ignore" : "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });
  if (opts.input !== undefined && proc.stdin) {
    proc.stdin.write(opts.input);
    await proc.stdin.end();
  }
  const [out, stderr, code] = await Promise.all([
    new Response(proc.stdout).arrayBuffer(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  if (code !== 0) throw new GitError(args, { code, stdout: "", stderr });
  return new Uint8Array(out);
}

export const EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
export const ZERO_SHA = /^0+$/;

export interface TreeBlob {
  path: string;
  mode: string;
  sha: string;
  size: number;
}

/** Every blob in a commit's tree. */
export async function listTree(
  gitDir: string,
  rev: string,
): Promise<TreeBlob[]> {
  const { stdout } = await git([
    "--git-dir",
    gitDir,
    "ls-tree",
    "-r",
    "-l",
    "-z",
    rev,
  ]);
  const out: TreeBlob[] = [];
  for (const record of stdout.split("\0")) {
    if (!record) continue;
    const tab = record.indexOf("\t");
    const [mode, type, sha, size] = record.slice(0, tab).split(/\s+/);
    if (type !== "blob") continue;
    out.push({
      mode,
      sha,
      size: Number(size) || 0,
      path: record.slice(tab + 1),
    });
  }
  return out;
}

/** Read many blobs in one `cat-file --batch` round trip. */
export async function readBlobs(
  gitDir: string,
  shas: string[],
  env?: Record<string, string>,
): Promise<Map<string, Uint8Array>> {
  const result = new Map<string, Uint8Array>();
  const unique = [...new Set(shas)];
  if (!unique.length) return result;
  const bytes = await gitBytes(["--git-dir", gitDir, "cat-file", "--batch"], {
    input: `${unique.join("\n")}\n`,
    env,
  });
  let offset = 0;
  const decoder = new TextDecoder();
  while (offset < bytes.length) {
    const newline = bytes.indexOf(10, offset);
    if (newline < 0) break;
    const header = decoder.decode(bytes.subarray(offset, newline));
    offset = newline + 1;
    const [sha, type, size] = header.split(" ");
    if (type === "missing" || !size) continue;
    const length = Number(size);
    result.set(sha, bytes.subarray(offset, offset + length));
    offset += length + 1;
  }
  return result;
}

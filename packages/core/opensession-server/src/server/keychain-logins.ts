/**
 * Releasing a login's password to the session that was approved to use it
 * (keychain.ts claimLoginRelease, the use_login tool).
 *
 * The password goes to a file, never into a tool result: a tool result is
 * part of the transcript, which teammates watch and which is stored. The file
 * sits in the session's own scratch dir, where `$OPENSESSION_SCRATCH` points
 * for the agent, in a fresh 0700 directory as a 0600 file, so the agent can
 * read it from a script and type it into the sign-in page. It is deleted
 * after RELEASED_LOGIN_TTL_MS. A Sandbox session gets the file inside its
 * Sandbox, written by a command that receives the password in its
 * environment rather than its argv. A Runner workspace cannot take
 * environment variables, so it cannot receive a login.
 *
 * Nothing here keeps the agent from reading or copying the password: it is
 * the one keychain secret an agent does see. The file only keeps it out of
 * the transcript and bounds how long it sits on disk.
 */

import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import {
  hostSessionScratchDir,
  sandboxSessionScratchDir,
} from "./session-scratch";
import type { WorkspaceExec } from "./sandbox/workspace-exec";

/** Long enough to sign in, short enough not to linger. */
export const RELEASED_LOGIN_TTL_MS = 30 * 60 * 1000;

export interface ReleasedLoginFile {
  path: string;
  expiresAt: string;
}

/** Where a session's workspace runs, as far as a release cares. */
export type LoginReleaseTarget =
  | { kind: "host" }
  | { kind: "sandbox"; provider?: string; exec: WorkspaceExec };

function releaseDirName(): string {
  return `login-${crypto.randomUUID()}`;
}

function scheduleRemoval(remove: () => Promise<unknown>, ttlMs: number): void {
  const timer = setTimeout(() => {
    remove().catch((error) =>
      console.error(
        "[keychain] couldn't remove a released login file:",
        error?.message,
      ),
    );
  }, ttlMs);
  timer.unref?.();
}

const SANDBOX_WRITE = [
  "set -eu",
  "umask 077",
  'mkdir -p "$(dirname "$KEYCHAIN_LOGIN_FILE")"',
  'chmod 700 "$(dirname "$KEYCHAIN_LOGIN_FILE")"',
  'printf %s "$KEYCHAIN_LOGIN_PASSWORD" > "$KEYCHAIN_LOGIN_FILE"',
].join("\n");

/**
 * Write the password where the session can read it and schedule its removal.
 * Throws with a message that never contains the password.
 */
export async function writeReleasedLogin(input: {
  sessionId: string;
  password: string;
  target: LoginReleaseTarget;
  ttlMs?: number;
}): Promise<ReleasedLoginFile> {
  const ttlMs = input.ttlMs ?? RELEASED_LOGIN_TTL_MS;
  const expiresAt = new Date(Date.now() + ttlMs).toISOString();
  const name = releaseDirName();

  if (input.target.kind === "host") {
    const dir = join(hostSessionScratchDir(input.sessionId), "logins", name);
    try {
      await mkdir(dir, { recursive: true, mode: 0o700 });
      const path = join(dir, "password");
      await writeFile(path, input.password, { mode: 0o600, flag: "wx" });
      scheduleRemoval(() => rm(dir, { recursive: true, force: true }), ttlMs);
      return { path, expiresAt };
    } catch (error: any) {
      await rm(dir, { recursive: true, force: true }).catch(() => {});
      throw new Error(
        `couldn't write the password file (${error?.code || "write failed"})`,
      );
    }
  }

  const { exec, provider } = input.target;
  const dir = join(
    sandboxSessionScratchDir(input.sessionId, provider),
    "logins",
    name,
  );
  const path = join(dir, "password");
  const result = await exec(["sh", "-c", SANDBOX_WRITE], {
    env: { KEYCHAIN_LOGIN_FILE: path, KEYCHAIN_LOGIN_PASSWORD: input.password },
    timeoutMs: 30_000,
    workloadIdentity: false,
  });
  if (result.exitCode !== 0) {
    await exec(["rm", "-rf", dir], { timeoutMs: 30_000 }).catch(() => {});
    // stderr comes from mkdir/printf on a path, never the variable's value,
    // but it is not worth the risk of quoting it.
    throw new Error("couldn't write the password file in the Sandbox");
  }
  scheduleRemoval(
    () =>
      exec(["rm", "-rf", dir], { timeoutMs: 30_000, workloadIdentity: false }),
    ttlMs,
  );
  return { path, expiresAt };
}

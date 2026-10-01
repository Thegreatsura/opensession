import { afterAll, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { writeReleasedLogin } from "./keychain-logins";
import { hostSessionScratchDir } from "./session-scratch";

const root = mkdtempSync(join(tmpdir(), "keychain-logins-"));
const previous = process.env.OPENSESSION_STATE_DIR;

beforeEach(() => {
  // Per test: another suite in this process may have changed it.
  process.env.OPENSESSION_STATE_DIR = root;
});

afterAll(() => {
  if (previous === undefined) delete process.env.OPENSESSION_STATE_DIR;
  else process.env.OPENSESSION_STATE_DIR = previous;
  rmSync(root, { recursive: true, force: true });
});

test("a host release is a private file in the session's scratch dir, removed after its time", async () => {
  const file = await writeReleasedLogin({
    sessionId: "os-login-host",
    password: " pass word ",
    target: { kind: "host" },
    ttlMs: 50,
  });
  expect(file.path.startsWith(hostSessionScratchDir("os-login-host"))).toBe(
    true,
  );
  expect(readFileSync(file.path, "utf-8")).toBe(" pass word ");
  expect(statSync(file.path).mode & 0o777).toBe(0o600);
  expect(statSync(dirname(file.path)).mode & 0o777).toBe(0o700);
  await Bun.sleep(150);
  expect(existsSync(dirname(file.path))).toBe(false);
});

test("a Sandbox release passes the password in the environment, never in argv", async () => {
  const calls: Array<{ cmd: string[]; env?: Record<string, string> }> = [];
  const exec = Object.assign(
    async (cmd: string[], opts?: { env?: Record<string, string> }) => {
      calls.push({ cmd, ...(opts?.env ? { env: opts.env } : {}) });
      return { exitCode: 0, stdout: "", stderr: "" };
    },
    { sandboxed: true, remote: true } as const,
  );
  const file = await writeReleasedLogin({
    sessionId: "os-login-sandbox",
    password: "hunter2-secret",
    target: { kind: "sandbox", exec },
    ttlMs: 20,
  });
  expect(file.path).toContain("/session-scratch/os-login-sandbox/logins/");
  expect(calls[0]!.env).toEqual({
    KEYCHAIN_LOGIN_FILE: file.path,
    KEYCHAIN_LOGIN_PASSWORD: "hunter2-secret",
  });
  expect(calls[0]!.cmd.join(" ")).not.toContain("hunter2");
  await Bun.sleep(80);
  expect(calls[1]!.cmd).toEqual(["rm", "-rf", dirname(file.path)]);
});

test("a failed Sandbox write is reported without the password", async () => {
  const exec = Object.assign(
    async () => ({ exitCode: 1, stdout: "", stderr: "hunter2-secret: nope" }),
    { sandboxed: true, remote: true } as const,
  );
  await expect(
    writeReleasedLogin({
      sessionId: "os-login-fail",
      password: "hunter2-secret",
      target: { kind: "sandbox", exec },
    }),
  ).rejects.toThrow(/^couldn't write the password file in the Sandbox$/);
});

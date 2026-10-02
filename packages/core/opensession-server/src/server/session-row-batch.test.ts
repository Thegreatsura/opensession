import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { SessionKernelStore } from "./session-kernel/store";
import type { SidebarSessionScope } from "./sidebar-session-scope";
import type { UnifiedSession } from "./types";

// A whole window of row publishes flushes as one batch: every changed row
// reaches every subscribed lens with the right frame, siblings share one
// group evaluation, and a session the index no longer has is removed.

let root: string;
let kernel: SessionKernelStore;
let restore: Array<() => void> = [];

function session(
  id: string,
  patch: Partial<UnifiedSession> = {},
): UnifiedSession {
  return {
    id,
    source: "opensession",
    branch: null,
    worktreeDir: null,
    createdBy: "Ada",
    startedBy: "Ada",
    title: id,
    lastActivity: "2026-09-01T00:00:00.000Z",
    createdAt: "2026-09-01T00:00:00.000Z",
    isRunning: false,
    transcriptPath: null,
    ...patch,
  } as UnifiedSession;
}

beforeAll(async () => {
  root = await mkdtemp(join(tmpdir(), "session-row-batch-"));
  await writeFile(
    join(root, "config.json"),
    JSON.stringify({
      repos: { acme: { repo: join(root, "acme"), ghRepo: "acme/app" } },
    }),
  );
  const env = { ...process.env };
  restore.push(() => {
    process.env.HOME = env.HOME;
    process.env.OPENSESSION_STATE_DIR = env.OPENSESSION_STATE_DIR;
    process.env.OPENSESSION_CONFIG = env.OPENSESSION_CONFIG;
  });
  process.env.HOME = root;
  process.env.OPENSESSION_STATE_DIR = root;
  process.env.OPENSESSION_CONFIG = join(root, "config.json");
  await (await import("./config")).getConfigAsync();
  const ghBackoff = (await import("./github-limit")).__setGhBackoffForTest(
    Date.now() + 60 * 60 * 1000,
  );
  restore.push(() =>
    import("./github-limit").then((m) => m.__setGhBackoffForTest(ghBackoff)),
  );
  const { SessionKernelStore } = await import("./session-kernel/store");
  const { __setSessionKernelStoreForTest } =
    await import("./session-kernel/kernel");
  kernel = new SessionKernelStore(join(root, "kernel.sqlite"));
  const priorKernel = __setSessionKernelStoreForTest(kernel);
  restore.push(() => __setSessionKernelStoreForTest(priorKernel));
  const {
    SessionListStore,
    __setSessionListStoreForTest,
    upsertIndexedSessions,
  } = await import("./session-list-store");
  const priorIndex = __setSessionListStoreForTest(
    new SessionListStore(":memory:"),
  );
  restore.push(() => __setSessionListStoreForTest(priorIndex));
  await upsertIndexedSessions(
    [
      session("ada-1", { workspaceId: "ws-ada" }),
      session("ada-2", { workspaceId: "ws-ada" }),
      session("grace-1", {
        workspaceId: "ws-grace",
        createdBy: "Grace",
        startedBy: "Grace",
      }),
    ],
    "exclude",
  );
});

afterAll(async () => {
  for (const undo of restore.reverse()) await undo();
  kernel.close();
  await rm(root, { recursive: true, force: true });
});

test("one window publishes every changed row to every lens", async () => {
  const { allClients } = await import("./ws-hub");
  const { publishSessionRow, SESSION_ROW_COALESCE_MS } =
    await import("./session-row-events");
  const lens = (user: string): SidebarSessionScope => ({
    user,
    person: "me",
    repo: "all",
    autoCreated: "hide",
  });
  const sockets = [lens("Ada"), lens("Grace"), null].map((sidebarScope) => {
    const sent: Array<{ type: string; id?: string; row?: { id: string } }> = [];
    return {
      sent,
      data: { sidebarScope },
      send(payload: string) {
        sent.push(JSON.parse(payload));
      },
    };
  });
  for (const ws of sockets) allClients.add(ws as never);
  try {
    for (const id of ["ada-1", "ada-2", "grace-1", "gone"])
      publishSessionRow(id);
    const deadline = Date.now() + SESSION_ROW_COALESCE_MS + 5_000;
    while (sockets.some((ws) => ws.sent.length < 4) && Date.now() < deadline)
      await Bun.sleep(25);
    const seen = (index: number) =>
      Object.fromEntries(
        sockets[index].sent.map((frame) => [
          frame.row?.id ?? frame.id,
          frame.type,
        ]),
      );
    expect(seen(0)).toEqual({
      "ada-1": "session_row",
      "ada-2": "session_row",
      "grace-1": "session_row_removed",
      gone: "session_row_removed",
    });
    expect(seen(1)).toEqual({
      "ada-1": "session_row_removed",
      "ada-2": "session_row_removed",
      "grace-1": "session_row",
      gone: "session_row_removed",
    });
    expect(seen(2)).toEqual({
      "ada-1": "session_row",
      "ada-2": "session_row",
      "grace-1": "session_row",
      gone: "session_row_removed",
    });
    for (const ws of sockets) expect(ws.sent).toHaveLength(4);
  } finally {
    for (const ws of sockets) allClients.delete(ws as never);
  }
});

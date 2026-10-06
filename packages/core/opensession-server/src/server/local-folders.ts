/**
 * Local folders: a session reaches a folder on a person's own computer while
 * the Open Session app (or a Chrome or Edge tab) that connected it stays open.
 *
 * The agent and everything it runs stay on this server. The person's client
 * holds the folder: it opens a dedicated bridge socket, says which folders it
 * holds and which sessions each is connected to, and answers one file
 * operation at a time (list, stat, read, write, mkdir, move, trash, and the
 * recursive walk and search, which run on the device to avoid a round trip
 * per directory). The
 * client resolves every path inside the folder it was granted and refuses
 * anything else; this module never sees an absolute path on that computer.
 * There is no shell on the device.
 *
 * Nothing here is persisted. The client owns the grants and announces them
 * again on every connect, so a restart loses nothing; while it is gone the
 * folder is listed as offline (until this process restarts) and every
 * operation fails fast instead of hanging.
 *
 * Only the person who connected a folder can reach it: an operation is
 * dispatched only for a turn that person prompted. Automation runs never
 * mount the tools (interactive-mcp.ts).
 */
import { broadcastToSession, type WSClientData } from "./ws-hub";

export type LocalFolderOp =
  | "list"
  | "stat"
  | "read"
  | "write"
  | "mkdir"
  | "move"
  | "trash"
  | "walk"
  | "search";

const OPS = new Set<LocalFolderOp>([
  "list",
  "stat",
  "read",
  "write",
  "mkdir",
  "move",
  "trash",
  "walk",
  "search",
]);

/** What a session viewer and the agent see of one connected folder. */
export interface LocalFolderView {
  /** `deviceId:folderId`, unique across devices. */
  key: string;
  id: string;
  name: string;
  /** Home-relative display path, such as `~/Documents/Taxes`. */
  displayPath?: string;
  readOnly: boolean;
  deviceId: string;
  deviceLabel: string;
  /** The person who connected it; only their turns can reach it. */
  owner: string;
  online: boolean;
}

interface BridgeFolder {
  id: string;
  name: string;
  displayPath?: string;
  readOnly: boolean;
  sessionIds: string[];
}

interface BridgeSocket {
  data: WSClientData;
  send(data: string): unknown;
}

interface Bridge {
  deviceId: string;
  deviceLabel: string;
  owner: string;
  folders: BridgeFolder[];
}

type Pending = {
  socket: BridgeSocket;
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
};

const g = globalThis as {
  __localFolderBridges?: Map<BridgeSocket, Bridge>;
  __localFolderPending?: Map<string, Pending>;
  __localFolderKnown?: Map<string, Map<string, LocalFolderView>>;
};
const bridges: Map<BridgeSocket, Bridge> = (g.__localFolderBridges ??=
  new Map());
const pending: Map<string, Pending> = (g.__localFolderPending ??= new Map());
/** Last view per session, so a folder whose app closed reads as offline
 *  rather than vanishing. Cleared by an explicit disconnect. */
const known: Map<
  string,
  Map<string, LocalFolderView>
> = (g.__localFolderKnown ??= new Map());

export const LOCAL_FOLDER_OP_TIMEOUT_MS = 60_000;
const MAX_FOLDERS = 64;
const MAX_SESSIONS_PER_FOLDER = 500;

function clean(value: unknown, max: number): string {
  return typeof value === "string"
    ? value
        .replace(/[\x00-\x1f\x7f‪-‮⁦-⁩]/g, " ")
        .trim()
        .slice(0, max)
    : "";
}

function cleanId(value: unknown): string {
  const id = clean(value, 120);
  return /^[A-Za-z0-9._:-]+$/.test(id) ? id : "";
}

function sameUser(a: string | undefined, b: string | undefined): boolean {
  const left = a?.trim().toLowerCase();
  return !!left && left === b?.trim().toLowerCase();
}

function parseFolders(raw: unknown): BridgeFolder[] {
  if (!Array.isArray(raw)) return [];
  const out: BridgeFolder[] = [];
  const seen = new Set<string>();
  for (const item of raw.slice(0, MAX_FOLDERS)) {
    if (!item || typeof item !== "object") continue;
    const record = item as Record<string, unknown>;
    const id = cleanId(record.id);
    const name = clean(record.name, 120);
    if (!id || !name || seen.has(id)) continue;
    seen.add(id);
    const displayPath = clean(record.displayPath, 400);
    const sessionIds = Array.isArray(record.sessionIds)
      ? [
          ...new Set(
            record.sessionIds
              .slice(0, MAX_SESSIONS_PER_FOLDER)
              .map(cleanId)
              .filter(Boolean),
          ),
        ]
      : [];
    out.push({
      id,
      name,
      ...(displayPath ? { displayPath } : {}),
      readOnly: record.readOnly === true,
      sessionIds,
    });
  }
  return out;
}

function viewOf(
  bridge: Bridge,
  folder: BridgeFolder,
  online: boolean,
): LocalFolderView {
  return {
    key: `${bridge.deviceId}:${folder.id}`,
    id: folder.id,
    name: folder.name,
    ...(folder.displayPath ? { displayPath: folder.displayPath } : {}),
    readOnly: folder.readOnly,
    deviceId: bridge.deviceId,
    deviceLabel: bridge.deviceLabel,
    owner: bridge.owner,
    online,
  };
}

function sessionsOf(bridge: Bridge | undefined): Set<string> {
  const out = new Set<string>();
  for (const folder of bridge?.folders ?? [])
    for (const sessionId of folder.sessionIds) out.add(sessionId);
  return out;
}

/** Live folders for a session, plus the last view of any whose device left. */
export function sessionLocalFolders(sessionId: string): LocalFolderView[] {
  const live = new Map<string, LocalFolderView>();
  for (const bridge of bridges.values())
    for (const folder of bridge.folders)
      if (folder.sessionIds.includes(sessionId)) {
        const view = viewOf(bridge, folder, true);
        live.set(view.key, view);
      }
  const previous = known.get(sessionId);
  for (const [key, view] of previous ?? [])
    if (!live.has(key)) live.set(key, { ...view, online: false });
  return [...live.values()].sort((a, b) => a.name.localeCompare(b.name));
}

function publish(sessionIds: Iterable<string>): void {
  for (const sessionId of sessionIds) {
    const folders = sessionLocalFolders(sessionId);
    if (folders.length)
      known.set(sessionId, new Map(folders.map((view) => [view.key, view])));
    else known.delete(sessionId);
    broadcastToSession(sessionId, {
      type: "local_folders",
      sessionId,
      folders,
    });
  }
}

/** Forget a disconnected folder everywhere, including its offline view. */
function forget(sessionId: string, key: string): void {
  const views = known.get(sessionId);
  views?.delete(key);
  if (views && !views.size) known.delete(sessionId);
}

/**
 * Bridge frames from a person's client. Returns true when the frame was
 * consumed, before the socket counts as a person doing something: a bridge
 * holds no presence.
 */
export function localFolderWsMessage(
  ws: BridgeSocket,
  msg: { type?: unknown; [key: string]: unknown },
): boolean {
  if (msg.type === "local_folders_hello") {
    if (ws.data.authAutomation) return true;
    const owner = clean(ws.data.authUser || msg.user, 80);
    const deviceId = cleanId(msg.deviceId);
    if (!owner || !deviceId) {
      try {
        ws.send(
          JSON.stringify({
            type: "local_folders_rejected",
            reason: owner ? "missing device" : "sign in first",
          }),
        );
      } catch {}
      return true;
    }
    ws.data.localFolderBridge = true;
    ws.data.presenceSuppressed = true;
    const before = sessionsOf(bridges.get(ws));
    const bridge: Bridge = {
      deviceId,
      deviceLabel: clean(msg.deviceLabel, 80) || "This computer",
      owner,
      folders: parseFolders(msg.folders),
    };
    bridges.set(ws, bridge);
    const affected = new Set([...before, ...sessionsOf(bridge)]);
    // A folder this device dropped since its last hello was disconnected on
    // purpose, so it must not linger as "offline".
    for (const sessionId of affected) {
      const views = known.get(sessionId);
      for (const [key, view] of views ?? [])
        if (
          view.deviceId === deviceId &&
          !bridge.folders.some(
            (folder) =>
              `${deviceId}:${folder.id}` === key &&
              folder.sessionIds.includes(sessionId),
          )
        )
          forget(sessionId, key);
    }
    publish(affected);
    try {
      ws.send(JSON.stringify({ type: "local_folders_ready" }));
    } catch {}
    return true;
  }
  if (msg.type === "local_folder_result") {
    const requestId = typeof msg.requestId === "string" ? msg.requestId : "";
    const entry = pending.get(requestId);
    if (!entry || entry.socket !== ws) return true;
    pending.delete(requestId);
    clearTimeout(entry.timer);
    if (msg.ok === true) entry.resolve(msg.result ?? null);
    else
      entry.reject(
        new Error(clean(msg.error, 500) || "The folder operation failed"),
      );
    return true;
  }
  return false;
}

export function localFolderWsClose(ws: BridgeSocket): void {
  const bridge = bridges.get(ws);
  if (!bridge) return;
  bridges.delete(ws);
  for (const [requestId, entry] of pending)
    if (entry.socket === ws) {
      pending.delete(requestId);
      clearTimeout(entry.timer);
      entry.reject(
        new Error(`${bridge.deviceLabel} disconnected before it answered`),
      );
    }
  publish(sessionsOf(bridge));
}

export class LocalFolderError extends Error {}

/** Pick the folder a tool call means: by name, key or id, or the only one. */
export function resolveLocalFolder(
  sessionId: string,
  user: string | undefined,
  ref: string | undefined,
): LocalFolderView {
  const folders = sessionLocalFolders(sessionId);
  if (!folders.length)
    throw new LocalFolderError(
      "No local folder is connected to this session. Ask the person to connect one from the composer's + menu (Connect a folder) in the Open Session Mac app or in Chrome.",
    );
  const own = folders.filter((folder) => sameUser(folder.owner, user));
  if (!own.length)
    throw new LocalFolderError(
      `Only the person who connected a folder can use it, in a turn they prompted. Connected by: ${[...new Set(folders.map((folder) => folder.owner))].join(", ")}.`,
    );
  const wanted = ref?.trim().toLowerCase();
  let folder: LocalFolderView | undefined;
  if (!wanted) {
    if (own.length > 1)
      throw new LocalFolderError(
        `Several folders are connected (${own.map((f) => f.name).join(", ")}). Name one.`,
      );
    folder = own[0];
  } else {
    const matches = own.filter(
      (f) =>
        f.key === ref ||
        f.id === ref ||
        f.name.toLowerCase() === wanted ||
        f.displayPath?.toLowerCase() === wanted,
    );
    if (matches.length > 1)
      throw new LocalFolderError(
        `'${ref}' matches more than one folder. Use its key: ${matches.map((f) => f.key).join(", ")}.`,
      );
    folder = matches[0];
    if (!folder)
      throw new LocalFolderError(
        `No connected folder is called '${ref}'. Connected: ${own.map((f) => f.name).join(", ")}.`,
      );
  }
  if (!folder!.online)
    throw new LocalFolderError(
      `${folder!.name} is on ${folder!.deviceLabel}, which is offline. It comes back when the Open Session app (or the browser tab) that connected it is open again.`,
    );
  return folder!;
}

/** Send one operation to the device holding the folder and wait for it. */
export function localFolderOp<T = unknown>(
  sessionId: string,
  user: string | undefined,
  ref: string | undefined,
  op: LocalFolderOp,
  args: Record<string, unknown>,
  options: { timeoutMs?: number; folder?: LocalFolderView } = {},
): Promise<T> {
  if (!OPS.has(op)) return Promise.reject(new LocalFolderError("Unknown op"));
  let folder: LocalFolderView;
  try {
    folder = options.folder ?? resolveLocalFolder(sessionId, user, ref);
  } catch (error) {
    return Promise.reject(error);
  }
  if (
    folder.readOnly &&
    (op === "write" || op === "mkdir" || op === "move" || op === "trash")
  )
    return Promise.reject(
      new LocalFolderError(
        `${folder.name} is connected read-only. Ask the person to allow edits from the folder chip above the composer.`,
      ),
    );
  const socket = [...bridges.entries()].find(
    ([, bridge]) =>
      bridge.deviceId === folder.deviceId &&
      bridge.folders.some(
        (f) => f.id === folder.id && f.sessionIds.includes(sessionId),
      ),
  )?.[0];
  if (!socket)
    return Promise.reject(
      new LocalFolderError(`${folder.deviceLabel} is offline.`),
    );
  const requestId = crypto.randomUUID();
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(requestId);
      reject(
        new LocalFolderError(
          `${folder.deviceLabel} did not answer within ${Math.round((options.timeoutMs ?? LOCAL_FOLDER_OP_TIMEOUT_MS) / 1000)}s. The computer may be asleep.`,
        ),
      );
    }, options.timeoutMs ?? LOCAL_FOLDER_OP_TIMEOUT_MS);
    pending.set(requestId, {
      socket,
      resolve: resolve as (value: unknown) => void,
      reject,
      timer,
    });
    try {
      socket.send(
        JSON.stringify({
          type: "local_folder_op",
          requestId,
          sessionId,
          folderId: folder.id,
          op,
          args,
        }),
      );
    } catch (error) {
      pending.delete(requestId);
      clearTimeout(timer);
      reject(error as Error);
    }
  });
}

/**
 * Disconnect a folder from a session. The holding device forgets the grant
 * for that session and re-announces; the offline view is dropped at once.
 * Only the folder's owner may do this.
 */
export function detachLocalFolder(
  sessionId: string,
  key: string,
  user: string,
): boolean {
  const view = sessionLocalFolders(sessionId).find((f) => f.key === key);
  if (!view || !sameUser(view.owner, user)) return false;
  forget(sessionId, key);
  for (const [socket, bridge] of bridges) {
    if (bridge.deviceId !== view.deviceId) continue;
    // Stop serving at once, before the device's next hello arrives.
    for (const folder of bridge.folders)
      if (folder.id === view.id)
        folder.sessionIds = folder.sessionIds.filter((id) => id !== sessionId);
    try {
      socket.send(
        JSON.stringify({
          type: "local_folder_detach",
          sessionId,
          folderId: view.id,
        }),
      );
    } catch {}
  }
  publish([sessionId]);
  return true;
}

/** Fenced prompt note telling the agent which folders it can reach. */
export function localFoldersContextNote(
  sessionId: string,
  user: string | undefined,
): string | null {
  const folders = sessionLocalFolders(sessionId).filter((folder) =>
    sameUser(folder.owner, user),
  );
  if (!folders.length) return null;
  const lines = folders.map(
    (folder) =>
      `- ${folder.name}${folder.displayPath ? ` (${folder.displayPath})` : ""} on ${folder.deviceLabel}: ${folder.readOnly ? "read-only" : "can edit"}, ${folder.online ? "online" : "offline"}`,
  );
  return [
    "Local folders on the person's own computer are connected to this session:",
    ...lines,
    "Reach them only through the opensession-local-folders tools (local_list, local_read, local_search, local_write, local_edit, local_move, local_trash, copy_from_local_folder, copy_to_local_folder). Paths are relative to the folder. You have no shell there; copy a file into this session to process it, and copy results back. The folder is reachable only while the person's app is open.",
  ].join("\n");
}

/** Test seam: drop every bridge and pending call. */
export function resetLocalFoldersForTest(): void {
  for (const entry of pending.values()) clearTimeout(entry.timer);
  pending.clear();
  bridges.clear();
  known.clear();
}

/**
 * Pending force_merge_pull_request cards, per session (opensession-repos).
 *
 * Fed by the session subscription (useSessionViewerSubscription) with the
 * two socket frames, and read by ForceMergeCard through
 * useSyncExternalStore. The frames carry no viewer identity, so every new
 * request re-asks the server whether this viewer may confirm it.
 */
import { BASE_PATH } from "./base";
import type { WSServerMessage } from "./types";

export type ForceMergeRequest = NonNullable<
  Extract<WSServerMessage, { type: "force_merge_request" }>["forceMergeRequest"]
>;

export type OpenForceMerge = {
  request: ForceMergeRequest;
  canConfirm: boolean;
};

const open = new Map<string, OpenForceMerge | null>();
const listeners = new Map<string, Set<() => void>>();
/** Bumped per load, so a slow response cannot overwrite a newer one. */
const loads = new Map<string, number>();

function set(sessionId: string, value: OpenForceMerge | null): void {
  open.set(sessionId, value);
  for (const listener of listeners.get(sessionId) ?? []) listener();
}

function load(sessionId: string): void {
  const token = (loads.get(sessionId) ?? 0) + 1;
  loads.set(sessionId, token);
  fetch(
    `${BASE_PATH}/api/force-merge?sessionId=${encodeURIComponent(sessionId)}`,
  )
    .then((res) => (res.ok ? res.json() : null))
    .then((body) => {
      if (!body || loads.get(sessionId) !== token) return;
      set(
        sessionId,
        body.request
          ? { request: body.request, canConfirm: !!body.canConfirm }
          : null,
      );
    })
    .catch(() => {});
}

/** The first viewer loads what is already open; the broadcast only reaches
 *  viewers connected when it went out. Teardown is deferred a microtask so
 *  a resubscribe on render keeps the loaded state. */
export function subscribeForceMerge(
  sessionId: string,
  listener: () => void,
): () => void {
  let set = listeners.get(sessionId);
  if (!set) listeners.set(sessionId, (set = new Set()));
  if (!set.size && !open.has(sessionId) && !loads.has(sessionId))
    load(sessionId);
  set.add(listener);
  return () => {
    set.delete(listener);
    queueMicrotask(() => {
      if (set.size || listeners.get(sessionId) !== set) return;
      listeners.delete(sessionId);
      open.delete(sessionId);
      loads.delete(sessionId);
    });
  };
}

export function forceMergeFor(sessionId: string): OpenForceMerge | null {
  return open.get(sessionId) ?? null;
}

export function applyForceMergeFrame(
  msg: Extract<
    WSServerMessage,
    { type: "force_merge_request" | "force_merge_request_resolved" }
  >,
): void {
  if (!listeners.has(msg.sessionId)) return;
  if (msg.type === "force_merge_request") {
    if (msg.forceMergeRequest) load(msg.sessionId);
    else set(msg.sessionId, null);
  } else if (open.get(msg.sessionId)?.request.id === msg.requestId) {
    loads.set(msg.sessionId, (loads.get(msg.sessionId) ?? 0) + 1);
    set(msg.sessionId, null);
  }
}

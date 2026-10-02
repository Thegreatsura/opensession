/**
 * Bun Worker that owns the session-history search database
 * (session-search-store.ts). The gateway thread never opens it: FTS5 upserts
 * and bm25 searches run here, answered in arrival order. The database path
 * comes from the gateway's `open`, never from this thread's environment.
 */
import {
  isSessionSearchStoreMethod,
  type SessionSearchWorkerRequest,
  type SessionSearchWorkerResponse,
} from "./session-search-protocol";
import { SessionSearchStore } from "./session-search-store";

declare const self: Worker;

let path: string | undefined;
let store: SessionSearchStore | undefined;

function reply(response: SessionSearchWorkerResponse): void {
  self.postMessage(response);
}

self.onmessage = (event: MessageEvent<SessionSearchWorkerRequest>) => {
  const request = event.data;
  if (request.t === "open") {
    if (path !== request.path) {
      store?.close();
      store = undefined;
    }
    path = request.path;
    return;
  }
  if (!isSessionSearchStoreMethod(request.method)) {
    reply({
      t: "error",
      id: request.id,
      message: `Unknown search store method: ${String(request.method)}`,
    });
    return;
  }
  try {
    if (!path) throw new Error("Search store has no database path");
    store ??= new SessionSearchStore(path);
    const method = store[request.method] as (...args: unknown[]) => unknown;
    reply({
      t: "result",
      id: request.id,
      value: method.apply(store, request.args) ?? null,
    });
  } catch (error) {
    reply({
      t: "error",
      id: request.id,
      message: error instanceof Error ? error.message : String(error),
    });
  }
};

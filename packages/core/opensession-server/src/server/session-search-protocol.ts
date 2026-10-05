/**
 * Wire protocol between the gateway's session-history search facade
 * (session-search-client.ts) and the worker that owns the FTS5 database
 * (session-search-worker.ts). Requests carry an increasing id and the worker
 * answers in arrival order, so a search posted after an upsert sees it.
 */
import type { SessionSearchStore } from "./session-search-store";

/** Store methods the facade may invoke by name. Anything else is refused. */
export const SESSION_SEARCH_STORE_METHODS = [
  "upsert",
  "remove",
  "indexState",
  "count",
  "search",
  "transcriptCursor",
  "applyTranscript",
  "removeTranscript",
  "searchTranscripts",
  "transcriptStats",
] as const;

export type SessionSearchStoreMethod =
  (typeof SESSION_SEARCH_STORE_METHODS)[number];

export type SessionSearchStoreArgs<M extends SessionSearchStoreMethod> =
  Parameters<SessionSearchStore[M]>;
export type SessionSearchStoreResult<M extends SessionSearchStoreMethod> =
  ReturnType<SessionSearchStore[M]>;

export type SessionSearchWorkerRequest =
  | { t: "open"; path: string }
  | {
      t: "call";
      id: number;
      method: SessionSearchStoreMethod;
      args: unknown[];
    };

export type SessionSearchWorkerResponse =
  | { t: "result"; id: number; value: unknown }
  | { t: "error"; id: number; message: string };

export function isSessionSearchStoreMethod(
  value: unknown,
): value is SessionSearchStoreMethod {
  return (
    typeof value === "string" &&
    (SESSION_SEARCH_STORE_METHODS as readonly string[]).includes(value)
  );
}

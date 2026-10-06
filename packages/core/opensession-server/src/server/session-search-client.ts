/**
 * Gateway facade for the session-history search index.
 *
 * The FTS5 database runs on a dedicated Bun Worker (session-search-worker.ts)
 * so indexing a finished session or answering a search never blocks HTTP,
 * WebSocket or timer work on the gateway thread. Every call returns a
 * promise; there is no synchronous fallback. Nothing starts at import: the
 * worker starts on the first call, and a changed database path retires the
 * old worker. When the worker dies or a call times out, pending calls reject
 * and the next call starts a fresh worker.
 */
import { workerEntry } from "../runner-host/exe";
import { stateDir } from "./paths";
import type {
  SessionSearchStoreArgs,
  SessionSearchStoreMethod,
  SessionSearchStoreResult,
  SessionSearchWorkerRequest,
  SessionSearchWorkerResponse,
} from "./session-search-protocol";
import type { SessionSearchStore } from "./session-search-store";

const MAX_PENDING = 1024;
const REQUEST_TIMEOUT_MS = 30_000;

export class SessionSearchIndexError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SessionSearchIndexError";
  }
}

type WorkerHandle = Worker & {
  ref(): void;
  unref(): void;
  addEventListener(type: "close", listener: () => void): void;
};

type Pending = {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
};

class SearchWorkerBackend {
  private worker: WorkerHandle | null = null;
  private readonly pending = new Map<number, Pending>();
  private nextId = 1;
  private retired = false;

  constructor(readonly path: string) {}

  call(method: SessionSearchStoreMethod, args: unknown[]): Promise<unknown> {
    if (this.retired)
      return Promise.reject(
        new SessionSearchIndexError("Search index was repointed"),
      );
    if (this.pending.size >= MAX_PENDING)
      return Promise.reject(
        new SessionSearchIndexError(
          `Search index has ${this.pending.size} pending requests`,
        ),
      );
    let worker: WorkerHandle;
    try {
      worker = this.ensureWorker();
    } catch (error) {
      return Promise.reject(error);
    }
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.fail(
          new SessionSearchIndexError(
            `Search index request timed out after ${REQUEST_TIMEOUT_MS}ms`,
          ),
        );
      }, REQUEST_TIMEOUT_MS);
      timer.unref?.();
      this.pending.set(id, { resolve, reject, timer });
      worker.ref();
      worker.postMessage({
        t: "call",
        id,
        method,
        args,
      } satisfies SessionSearchWorkerRequest);
    });
  }

  private ensureWorker(): WorkerHandle {
    if (this.worker) return this.worker;
    const worker = new Worker(
      workerEntry(
        "session-search-worker.js",
        new URL("./session-search-worker.ts", import.meta.url).href,
      ),
      { type: "module" },
    ) as WorkerHandle;
    const mine = () => this.worker === worker;
    worker.addEventListener("message", (event: MessageEvent) => {
      if (mine()) this.settle(event.data as SessionSearchWorkerResponse);
    });
    worker.addEventListener("error", (event) => {
      if (!mine()) return;
      const first = (event.message || "unknown error").split("\n")[0];
      this.fail(new SessionSearchIndexError(`Search worker failed: ${first}`));
    });
    worker.addEventListener("messageerror", () => {
      if (mine())
        this.fail(new SessionSearchIndexError("Search worker sent bad data"));
    });
    worker.addEventListener("close", () => {
      if (mine())
        this.fail(new SessionSearchIndexError("Search worker exited"));
    });
    worker.unref();
    worker.postMessage({
      t: "open",
      path: this.path,
    } satisfies SessionSearchWorkerRequest);
    this.worker = worker;
    return worker;
  }

  private settle(response: SessionSearchWorkerResponse): void {
    const pending = this.pending.get(response.id);
    if (!pending) return;
    this.pending.delete(response.id);
    clearTimeout(pending.timer);
    if (response.t === "error")
      pending.reject(new SessionSearchIndexError(response.message));
    else pending.resolve(response.value);
    if (this.pending.size > 0) return;
    if (this.retired) this.fail(new SessionSearchIndexError("Retired"));
    else this.worker?.unref();
  }

  private fail(error: Error): void {
    const worker = this.worker;
    this.worker = null;
    worker?.terminate();
    const pending = [...this.pending.values()];
    this.pending.clear();
    for (const entry of pending) {
      clearTimeout(entry.timer);
      entry.reject(error);
    }
  }

  retire(): void {
    this.retired = true;
    if (this.pending.size === 0)
      this.fail(new SessionSearchIndexError("Retired"));
  }
}

const g = globalThis as typeof globalThis & {
  __osSessionSearch?: {
    override?: SessionSearchStore;
    worker?: SearchWorkerBackend;
  };
};

function searchDbPath(): string {
  return process.env.OPENSESSION_SEARCH_DB || stateDir("search.db");
}

/** Run one store method on the search worker. */
export function callSearchIndex<M extends SessionSearchStoreMethod>(
  method: M,
  ...args: SessionSearchStoreArgs<M>
): Promise<SessionSearchStoreResult<M>> {
  const state = (g.__osSessionSearch ??= {});
  if (state.override) {
    try {
      const fn = state.override[method] as (
        ...params: SessionSearchStoreArgs<M>
      ) => SessionSearchStoreResult<M>;
      return Promise.resolve(fn.apply(state.override, args));
    } catch (error) {
      return Promise.reject(error);
    }
  }
  const path = searchDbPath();
  if (state.worker && state.worker.path !== path) {
    state.worker.retire();
    state.worker = undefined;
  }
  state.worker ??= new SearchWorkerBackend(path);
  return state.worker.call(method, args) as Promise<
    SessionSearchStoreResult<M>
  >;
}

/** Test seam: serve calls from an in-process store, or undefined to restore
 *  the worker. Returns the previous override. */
export function __setSessionSearchStoreForTest(
  store: SessionSearchStore | undefined,
): SessionSearchStore | undefined {
  const state = (g.__osSessionSearch ??= {});
  const previous = state.override;
  state.override = store;
  return previous;
}

/**
 * "Open this comment thread": the `?thread=<id>` on a session link.
 *
 * The router rewrites `/session/<id>` to its workspace route and drops the
 * query on the way, so the request is captured here first: from the address
 * the page loaded with (read when this module is evaluated, before the app
 * mounts), and from every in-app link a notification opens. The session's
 * comment layer takes it once that thread has loaded.
 */

let pending: string | null = threadParam(
  typeof window === "undefined" ? "" : (window.location?.href ?? ""),
);
const listeners = new Set<() => void>();

function threadParam(url: string): string | null {
  try {
    return new URL(url, "http://local").searchParams.get("thread");
  } catch {
    return null;
  }
}

/** Remember the thread a link points at, if it points at one. */
export function noteThreadLink(url: string): void {
  const id = threadParam(url);
  if (!id) return;
  pending = id;
  for (const listener of listeners) listener();
}

/** The requested thread, if it is one of `available`. Clears the request. */
export function takeThreadFocus(
  available: (id: string) => boolean,
): string | null {
  if (!pending || !available(pending)) return null;
  const id = pending;
  pending = null;
  return id;
}

export function onThreadFocusRequest(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

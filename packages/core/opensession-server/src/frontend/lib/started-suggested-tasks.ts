/**
 * Suggested tasks this browser has already started.
 *
 * Starting a suggestion answers it: the new session carries the work, so the
 * card that proposed it closes. The answer is stored rather than held in the
 * card, because a transcript re-renders the same `suggest_task` call on every
 * reload and a card that came back would invite a second, duplicate session.
 *
 * Keyed by the proposing session and the call's transcript entry id, both of
 * which are durable. The list is capped so it cannot grow without bound.
 */
import { useEffect, useState } from "react";

export const STARTED_SUGGESTED_TASKS_KEY = "opensession-started-suggestions";

/** Same-tab notification; `storage` only fires in other tabs. */
const STARTED_SUGGESTED_TASKS_EVENT = "opensession-started-suggestions-changed";

const LIMIT = 500;

export function suggestedTaskKey(sessionId: string, entryId: string): string {
  return `${sessionId}:${entryId}`;
}

// One key per line: session and entry ids never contain a newline.
function readStarted(): string[] {
  try {
    const raw = globalThis.localStorage?.getItem(STARTED_SUGGESTED_TASKS_KEY);
    return raw ? raw.split("\n").filter(Boolean) : [];
  } catch {
    return [];
  }
}

export function markSuggestedTaskStarted(key: string): void {
  const next = [...readStarted().filter((k) => k !== key), key].slice(-LIMIT);
  try {
    localStorage.setItem(STARTED_SUGGESTED_TASKS_KEY, next.join("\n"));
  } catch {
    // Storage full or unavailable: the card still closes for this page.
  }
  window.dispatchEvent(new Event(STARTED_SUGGESTED_TASKS_EVENT));
}

/** The started keys, following this tab and the others. */
export function useStartedSuggestedTasks(): ReadonlySet<string> {
  const [started, setStarted] = useState<ReadonlySet<string>>(
    () => new Set(readStarted()),
  );
  useEffect(() => {
    const sync = () => setStarted(new Set(readStarted()));
    const syncStorage = (event: StorageEvent) => {
      if (event.key === STARTED_SUGGESTED_TASKS_KEY) sync();
    };
    window.addEventListener(STARTED_SUGGESTED_TASKS_EVENT, sync);
    window.addEventListener("storage", syncStorage);
    return () => {
      window.removeEventListener(STARTED_SUGGESTED_TASKS_EVENT, sync);
      window.removeEventListener("storage", syncStorage);
    };
  }, []);
  return started;
}

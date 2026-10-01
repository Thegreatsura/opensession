// A per-user ordered list of keys (repo band order, Active row order). The
// server-side ui-pref follows the user across devices; user-scoped
// localStorage keeps startup synchronous. A write is held as "dirty" until the
// server confirms it, so a reload or a failed PUT can't drop a drag.

import { z } from "zod";
import { getCurrentUser } from "../components/UserPicker";
import { fetchUiPrefs, saveUiPrefsApi } from "./api";
import { whenCurrentUserReady } from "./auth-ready";

const USER_CHANGE_EVENT = "opensession-user-changed";

const keySchema = z.string();
const eventListenerSchema = z.function();

type JsonValue =
  | string
  | number
  | boolean
  | null
  | readonly JsonValue[]
  | { readonly [key: string]: JsonValue };

/** Trimmed, non-empty, de-duplicated string keys; anything else is dropped. */
export function normalizeOrder(value: JsonValue | undefined): string[] {
  if (!Array.isArray(value)) return [];
  const seen = new Set<string>();
  const order: string[] = [];
  for (const item of value) {
    const parsed = keySchema.safeParse(item);
    if (!parsed.success) continue;
    const key = parsed.data.trim();
    if (!key || seen.has(key)) continue;
    seen.add(key);
    order.push(key);
  }
  return order;
}

export interface OrderPref {
  get: () => string[];
  set: (order: readonly string[]) => void;
  onChanged: (handler: () => void) => () => void;
}

export function orderPref({
  name,
  changeEvent,
  maxChars,
}: {
  /** The ui-pref key; also names the localStorage keys. Must be one of the
   *  server's long-value keys (server/ui-prefs.ts). */
  name: string;
  changeEvent: string;
  /** Keep only as many keys, from the front, as fit this many characters of
   *  JSON: the server drops a ui-pref value longer than its cap. */
  maxChars?: number;
}): OrderPref {
  const localPrefix = `opensession-${name}:`;
  const dirtyPrefix = `opensession-${name}-dirty:`;
  const userKey = (user: string) => user.trim().toLowerCase() || "anonymous";
  const localKey = (user: string) => `${localPrefix}${userKey(user)}`;
  const dirtyKey = (user: string) => `${dirtyPrefix}${userKey(user)}`;
  const normalize = (value: JsonValue | undefined) => {
    const order = normalizeOrder(value);
    if (maxChars === undefined) return order;
    let chars = 2;
    let fit = 0;
    for (const key of order) {
      chars += JSON.stringify(key).length + (fit ? 1 : 0);
      if (chars > maxChars) break;
      fit++;
    }
    return order.slice(0, fit);
  };

  function readLocal(user: string): string[] {
    try {
      return normalize(
        JSON.parse(localStorage.getItem(localKey(user)) || "[]"),
      );
    } catch {
      return [];
    }
  }

  function writeLocal(user: string, order: readonly string[]) {
    localStorage.setItem(localKey(user), JSON.stringify(normalize(order)));
  }

  let writeStamp = 0;
  let saveChain: Promise<unknown> = Promise.resolve();
  const pendingWrites = new Map<string, string>();

  function persist(user: string, value: string, attempt = 0) {
    saveChain = saveChain
      .catch(() => {})
      .then(async () => {
        if (pendingWrites.get(user) !== value) return;
        const stored = await saveUiPrefsApi(user, { [name]: value });
        if (stored[name] !== value) throw new Error(`${name} was not stored`);
        if (pendingWrites.get(user) === value) {
          pendingWrites.delete(user);
          localStorage.removeItem(dirtyKey(user));
        }
      })
      .catch(() => {
        if (
          attempt < 2 &&
          pendingWrites.get(user) === value &&
          JSON.stringify(readLocal(user)) === value
        ) {
          setTimeout(
            () => persist(user, value, attempt + 1),
            1_000 * (attempt + 1),
          );
        }
      });
  }

  function get(): string[] {
    return readLocal(getCurrentUser());
  }

  function set(order: readonly string[]) {
    const user = getCurrentUser();
    const next = normalize(order);
    writeStamp++;
    writeLocal(user, next);
    window.dispatchEvent(new Event(changeEvent));
    const value = JSON.stringify(next);
    localStorage.setItem(dirtyKey(user), value);
    pendingWrites.set(user, value);
    persist(user, value);
  }

  async function hydrate(user: string) {
    const stampAtStart = writeStamp;
    let prefs: Record<string, string>;
    try {
      prefs = await fetchUiPrefs(user);
    } catch {
      return;
    }
    if (writeStamp !== stampAtStart) return;
    if (pendingWrites.has(user)) return;
    const dirtyValue = localStorage.getItem(dirtyKey(user));
    if (dirtyValue) {
      pendingWrites.set(user, dirtyValue);
      persist(user, dirtyValue);
      return;
    }
    const parsedServerValue = keySchema.safeParse(prefs[name]);
    if (!parsedServerValue.success) {
      const localOrder = readLocal(user);
      if (localOrder.length) {
        const value = JSON.stringify(localOrder);
        localStorage.setItem(dirtyKey(user), value);
        pendingWrites.set(user, value);
        persist(user, value);
      }
      return;
    }
    try {
      const serverOrder = normalize(JSON.parse(parsedServerValue.data));
      if (JSON.stringify(serverOrder) !== JSON.stringify(readLocal(user))) {
        writeLocal(user, serverOrder);
        window.dispatchEvent(new Event(changeEvent));
      }
    } catch {}
  }

  function onChanged(handler: () => void): () => void {
    window.addEventListener(changeEvent, handler);
    return () => window.removeEventListener(changeEvent, handler);
  }

  // Capability check, not just `typeof window`: test runners can leave a bare
  // `window` global without DOM methods, which must not break module import.
  if (
    "window" in globalThis &&
    eventListenerSchema.safeParse(window.addEventListener).success
  ) {
    whenCurrentUserReady((user) => void hydrate(user));
    window.addEventListener(USER_CHANGE_EVENT, () => {
      writeStamp++;
      window.dispatchEvent(new Event(changeEvent));
      void hydrate(getCurrentUser());
    });
    window.addEventListener("storage", (event) => {
      if (event.key?.startsWith(localPrefix)) {
        writeStamp++;
        window.dispatchEvent(new Event(changeEvent));
      } else if (
        event.key === "opensession-user" ||
        event.key === "backstage-user"
      ) {
        writeStamp++;
        window.dispatchEvent(new Event(changeEvent));
        void hydrate(getCurrentUser());
      }
    });
  }

  return { get, set, onChanged };
}

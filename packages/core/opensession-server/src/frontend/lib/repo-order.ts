// Per-user order for repository bands. Storage (a server-side ui-pref with a
// synchronous localStorage cache) lives in lib/order-pref.

import { orderPref, normalizeOrder } from "./order-pref";

export const normalizeRepoOrder = normalizeOrder;

export function mergeRepoOrder(
  preferred: readonly string[],
  discovered: readonly string[],
): string[] {
  const available = new Set(discovered);
  const ordered = normalizeRepoOrder(preferred).filter((repo) =>
    available.has(repo),
  );
  const seen = new Set(ordered);
  for (const repo of discovered) {
    if (!seen.has(repo)) {
      seen.add(repo);
      ordered.push(repo);
    }
  }
  return ordered;
}

/** Reorder only visible slots, preserving filtered-out repositories in place. */
export function replaceVisibleRepoOrder(
  fullOrder: readonly string[],
  visibleOrder: readonly string[],
): string[] {
  const visible = new Set(visibleOrder);
  const queue = [...visibleOrder];
  const next = fullOrder.map((repo) =>
    visible.has(repo) ? (queue.shift() ?? repo) : repo,
  );
  const seen = new Set(next);
  for (const repo of visibleOrder) {
    if (!seen.has(repo)) {
      seen.add(repo);
      next.push(repo);
    }
  }
  return next;
}

const repoOrder = orderPref({
  name: "repo-order",
  changeEvent: "opensession-repo-order-changed",
});

export const getRepoOrder = repoOrder.get;
export const setRepoOrder = repoOrder.set;
export const onRepoOrderChanged = repoOrder.onChanged;

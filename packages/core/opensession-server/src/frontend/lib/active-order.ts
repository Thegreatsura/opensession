// The Active section's manual order (Inbox grouping). Rows start in creation
// order, newest first, and stay put; a drag pins the dragged section's rows
// into the order you left them in. Rows the saved order doesn't name yet (new
// work) still arrive on top, so a fresh workspace is never buried.

import { orderPref } from "./order-pref";
import { sortInboxByCreation, type InboxRow } from "./sidebar-inbox";

const activeOrder = orderPref({
  name: "active-order",
  changeEvent: "opensession-active-order-changed",
  // Under the server's 16,384-character cap for long ui-pref values.
  maxChars: 16_000,
});

export const getActiveOrder = activeOrder.get;
export const setActiveOrder = activeOrder.set;
export const onActiveOrderChanged = activeOrder.onChanged;

/** Unplaced rows first (newest first), then placed rows in saved order. */
export function sortActiveRows<T extends InboxRow>(
  rows: readonly T[],
  order: readonly string[],
): T[] {
  const index = new Map(order.map((key, i) => [key, i] as const));
  const unplaced = sortInboxByCreation(rows.filter((r) => !index.has(r.key)));
  const placed = rows
    .filter((r) => index.has(r.key))
    .sort((a, b) => index.get(a.key)! - index.get(b.key)!);
  return [...unplaced, ...placed];
}

/** The saved order after a drop: the dropped section's keys lead, and every
 *  other saved key keeps its relative place behind them. Sections never share
 *  rows, so this cannot move a row in any other section. */
export function placeActiveOrder(
  saved: readonly string[],
  section: readonly string[],
): string[] {
  const moved = new Set(section);
  return [...section, ...saved.filter((key) => !moved.has(key))];
}

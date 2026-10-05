/**
 * Margin layout for inline comment cards, the way a document editor does it:
 * each card wants to sit level with its passage, cards never overlap, and the
 * card you are working in stays exactly level with its words while the others
 * make room above and below it.
 */

export interface CardSlot {
  id: string;
  /** Where the card would like its top edge: level with the passage. */
  want: number;
  height: number;
}

export const CARD_GAP = 8;

/** Final top edge per card id. */
export function stackCards(
  slots: CardSlot[],
  activeId?: string | null,
  gap = CARD_GAP,
): Map<string, number> {
  const sorted = [...slots].sort(
    (a, b) => a.want - b.want || (a.id < b.id ? -1 : 1),
  );
  const tops = new Map<string, number>();
  const pivot = activeId ? sorted.findIndex((s) => s.id === activeId) : -1;
  if (pivot < 0) {
    let floor = -Infinity;
    for (const slot of sorted) {
      const top = Math.max(slot.want, floor);
      tops.set(slot.id, top);
      floor = top + slot.height + gap;
    }
    return tops;
  }
  const active = sorted[pivot]!;
  tops.set(active.id, active.want);
  // Below the active card: push down.
  let floor = active.want + active.height + gap;
  for (const slot of sorted.slice(pivot + 1)) {
    const top = Math.max(slot.want, floor);
    tops.set(slot.id, top);
    floor = top + slot.height + gap;
  }
  // Above it: push up.
  let ceiling = active.want - gap;
  for (const slot of sorted.slice(0, pivot).reverse()) {
    const top = Math.min(slot.want, ceiling - slot.height);
    tops.set(slot.id, top);
    ceiling = top - gap;
  }
  return tops;
}

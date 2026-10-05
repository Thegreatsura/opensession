/**
 * Inline comment anchors: capturing a selection as words, and finding those
 * words again later.
 *
 * An anchor is the selected text plus a little context either side, scoped to
 * one transcript entry (`data-eid`). Positions in the DOM do not survive the
 * transcript re-rendering, lazy-loading or re-highlighting code; the words do.
 * The string half of this module is pure, so the matching rules are tested
 * without a browser; the DOM half only maps text offsets to Ranges and back.
 */

import type { TextAnchor } from "./types";

/** Characters of context kept either side of the passage. */
export const ANCHOR_CONTEXT = 32;

/** Build an anchor from offsets into an entry's text. */
export function anchorFromOffsets(
  text: string,
  start: number,
  end: number,
  entryId: string,
): TextAnchor | null {
  // Trim the selection to its words: a drag often picks up the newline or
  // space at either end, and those make the anchor brittle for no gain.
  while (start < end && /\s/.test(text[start]!)) start++;
  while (end > start && /\s/.test(text[end - 1]!)) end--;
  if (end - start < 2) return null;
  return {
    entryId,
    exact: text.slice(start, end),
    prefix: text.slice(Math.max(0, start - ANCHOR_CONTEXT), start),
    suffix: text.slice(end, end + ANCHOR_CONTEXT),
  };
}

function commonSuffix(a: string, b: string): number {
  let n = 0;
  while (
    n < a.length &&
    n < b.length &&
    a[a.length - 1 - n] === b[b.length - 1 - n]
  )
    n++;
  return n;
}

function commonPrefix(a: string, b: string): number {
  let n = 0;
  while (n < a.length && n < b.length && a[n] === b[n]) n++;
  return n;
}

/**
 * Where the anchor's words sit in `text`, or null when they are gone. When
 * the passage repeats, the occurrence whose surroundings best match the saved
 * prefix and suffix wins, earliest first on a tie.
 */
export function locateAnchor(
  text: string,
  anchor: Pick<TextAnchor, "exact" | "prefix" | "suffix">,
): { start: number; end: number } | null {
  if (!anchor.exact) return null;
  let best: { start: number; score: number } | null = null;
  for (
    let at = text.indexOf(anchor.exact);
    at >= 0;
    at = text.indexOf(anchor.exact, at + 1)
  ) {
    const before = text.slice(Math.max(0, at - anchor.prefix.length), at);
    const after = text.slice(
      at + anchor.exact.length,
      at + anchor.exact.length + anchor.suffix.length,
    );
    const score =
      commonSuffix(before, anchor.prefix) + commonPrefix(after, anchor.suffix);
    if (!best || score > best.score) best = { start: at, score };
  }
  return best
    ? { start: best.start, end: best.start + anchor.exact.length }
    : null;
}

// ── DOM ─────────────────────────────────────────────────────────────────────

function textNodes(root: Node): Text[] {
  const out: Text[] = [];
  const walker = root.ownerDocument!.createTreeWalker(
    root,
    NodeFilter.SHOW_TEXT,
  );
  for (let node = walker.nextNode(); node; node = walker.nextNode())
    if (node instanceof Text) out.push(node);
  return out;
}

/** Offset of a DOM boundary point within `root`'s text. */
function boundaryOffset(root: Node, container: Node, offset: number): number {
  const range = root.ownerDocument!.createRange();
  range.selectNodeContents(root);
  range.setEnd(container, offset);
  return range.toString().length;
}

/** The entry element a node sits in. */
export function entryElementOf(node: Node | null): HTMLElement | null {
  const element =
    node instanceof Element ? node : (node?.parentElement ?? null);
  return element?.closest<HTMLElement>("[data-eid]") ?? null;
}

/**
 * Anchor a selected range, when it lies within one transcript entry. A range
 * that spans two entries returns null: a comment points at one message.
 */
export function anchorFromRange(range: Range): TextAnchor | null {
  const startEntry = entryElementOf(range.startContainer);
  const endEntry = entryElementOf(range.endContainer);
  if (!startEntry || startEntry !== endEntry) return null;
  const entryId = startEntry.dataset.eid;
  if (!entryId) return null;
  const text = startEntry.textContent ?? "";
  return anchorFromOffsets(
    text,
    boundaryOffset(startEntry, range.startContainer, range.startOffset),
    boundaryOffset(startEntry, range.endContainer, range.endOffset),
    entryId,
  );
}

/** A Range over `[start, end)` of `root`'s text. */
export function rangeFromOffsets(
  root: Node,
  start: number,
  end: number,
): Range | null {
  const range = root.ownerDocument!.createRange();
  let seen = 0;
  let started = false;
  for (const node of textNodes(root)) {
    const length = node.data.length;
    if (!started && start <= seen + length) {
      range.setStart(node, start - seen);
      started = true;
    }
    if (started && end <= seen + length) {
      range.setEnd(node, end - seen);
      return range;
    }
    seen += length;
  }
  return null;
}

/** The entry element an anchor points into, when it is rendered. */
export function anchorEntryElement(
  container: ParentNode,
  anchor: TextAnchor,
): HTMLElement | null {
  return container.querySelector<HTMLElement>(
    `[data-eid="${CSS.escape(anchor.entryId)}"]`,
  );
}

/** A live Range for the anchor, or null when its entry is not rendered or
 *  its words are no longer there. */
export function rangeForAnchor(
  container: ParentNode,
  anchor: TextAnchor,
): Range | null {
  const entry = anchorEntryElement(container, anchor);
  if (!entry) return null;
  const found = locateAnchor(entry.textContent ?? "", anchor);
  return found ? rangeFromOffsets(entry, found.start, found.end) : null;
}

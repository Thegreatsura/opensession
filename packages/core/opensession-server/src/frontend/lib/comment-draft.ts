/**
 * The inline comment being written, per session: set by the selection pill,
 * read and cleared by the session's comment layer. A small external store
 * rather than component state, because the pill and the layer are siblings
 * inside a presentation-only region, and because the layer can remount while
 * the transcript loads: a draft someone is typing must survive that.
 */

import { useCallback, useSyncExternalStore } from "react";
import type { TextAnchor } from "./types";

/** A comment being written: the passage it will point at. */
export interface CommentDraft {
  anchor: TextAnchor;
  /** The live selection it came from; re-resolved from `anchor` if the
   *  transcript re-renders under it. */
  range: Range;
}

const drafts = new Map<string, CommentDraft>();
const listeners = new Set<() => void>();

function emit(): void {
  for (const listener of listeners) listener();
}

export function setCommentDraft(
  sessionId: string,
  draft: CommentDraft | null,
): void {
  if (draft) drafts.set(sessionId, draft);
  else if (!drafts.delete(sessionId)) return;
  emit();
}

/** Start a comment on a passage of this session's transcript. */
export function requestCommentDraft(
  sessionId: string,
  draft: CommentDraft,
): void {
  setCommentDraft(sessionId, draft);
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** This session's draft, and the setter that replaces or clears it. */
export function useCommentDraft(
  sessionId: string,
): [CommentDraft | null, (draft: CommentDraft | null) => void] {
  const draft = useSyncExternalStore(
    subscribe,
    () => drafts.get(sessionId) ?? null,
    () => null,
  );
  const set = useCallback(
    (next: CommentDraft | null) => setCommentDraft(sessionId, next),
    [sessionId],
  );
  return [draft, set];
}

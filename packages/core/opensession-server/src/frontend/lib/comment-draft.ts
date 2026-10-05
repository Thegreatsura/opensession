/**
 * "Comment on this passage", from the selection pill to the session's comment
 * layer. A per-session channel rather than shared state, because the pill and
 * the layer are siblings inside a presentation-only region; the layer owns
 * the draft from here on.
 */

import type { TextAnchor } from "./types";

/** A comment being written: the passage it will point at. */
export interface CommentDraft {
  anchor: TextAnchor;
  /** The live selection it came from; re-resolved from `anchor` if the
   *  transcript re-renders under it. */
  range: Range;
}

const listeners = new Map<string, Set<(draft: CommentDraft) => void>>();

export function requestCommentDraft(
  sessionId: string,
  draft: CommentDraft,
): void {
  for (const listener of listeners.get(sessionId) ?? []) listener(draft);
}

export function onCommentDraftRequest(
  sessionId: string,
  listener: (draft: CommentDraft) => void,
): () => void {
  let set = listeners.get(sessionId);
  if (!set) listeners.set(sessionId, (set = new Set()));
  set.add(listener);
  return () => {
    set.delete(listener);
    if (!set.size) listeners.delete(sessionId);
  };
}

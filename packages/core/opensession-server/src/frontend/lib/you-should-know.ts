import { useEffect, type Dispatch, type SetStateAction } from "react";
import type { ComposerPrefill } from "./composer-types";

/**
 * "Ask about this" on a You should know note (server/you-should-know.ts):
 * the note is quoted into the session's composer, the way Claude Code's plugin
 * fills its prompt box. A per-session listener rather than a prop because the
 * note renders deep inside the transcript while the composer belongs to the
 * session viewer; keying on the session id keeps a split view's other pane
 * out of it.
 */

const listeners = new Map<string, Set<(text: string) => void>>();

/** The composer draft for a note: a quote the person can reply under. */
export function youShouldKnowChatText(
  tag: string,
  line: string,
  explanation: string,
): string {
  const quoted = [
    `${tag} · ${line}`,
    ...(explanation.trim() ? ["", explanation.trim()] : []),
  ]
    .join("\n")
    .split("\n")
    .map((row) => (row === "" ? ">" : `> ${row}`))
    .join("\n");
  return `About this note from the side agent:\n\n${quoted}\n\n`;
}

export function requestYouShouldKnowChat(
  sessionId: string,
  text: string,
): void {
  for (const handler of listeners.get(sessionId) ?? []) handler(text);
}

export function onYouShouldKnowChat(
  sessionId: string,
  handler: (text: string) => void,
): () => void {
  let set = listeners.get(sessionId);
  if (!set) listeners.set(sessionId, (set = new Set()));
  set.add(handler);
  return () => {
    set.delete(handler);
    if (!set.size) listeners.delete(sessionId);
  };
}

/** Let this session's notes quote themselves into its composer. Appends to
 *  whatever is already drafted rather than replacing it. */
export function useYouShouldKnowChat(
  sessionId: string,
  setPrefill: Dispatch<SetStateAction<ComposerPrefill | null>>,
): void {
  useEffect(
    () =>
      onYouShouldKnowChat(sessionId, (text) =>
        setPrefill((current) => ({
          seq: (current?.seq ?? 0) + 1,
          text,
          replace: false,
        })),
      ),
    [sessionId, setPrefill],
  );
}

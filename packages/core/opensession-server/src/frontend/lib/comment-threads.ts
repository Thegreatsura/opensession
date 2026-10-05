/**
 * Client-side rules for comment threads (src/server/comment-threads.ts):
 * merging live frames, splitting inline comments from timeline notes, and
 * the text a thread becomes when it is handed to the main session.
 */

import type { CommentThread } from "./types";
import { requestYouShouldKnowChat } from "./you-should-know";

/** Insert or replace by id. An older copy never overwrites a newer one, so a
 *  request's response and its broadcast echo can land in either order. */
export function upsertThread(
  threads: CommentThread[],
  next: CommentThread,
): CommentThread[] {
  const index = threads.findIndex((t) => t.id === next.id);
  if (index < 0) return [...threads, next];
  if ((threads[index]!.updatedAt ?? 0) > (next.updatedAt ?? 0)) return threads;
  const copy = [...threads];
  copy[index] = next;
  return copy;
}

/** A session's threads, and the team notes among them that the timeline
 *  interleaves. */
export interface SessionComments {
  threads: CommentThread[];
  notes: CommentThread[];
}

/** Threads with no passage: the team notes that sit in the timeline. */
export function timelineThreads(threads: CommentThread[]): CommentThread[] {
  return threads.filter((t) => !t.anchor);
}

/** Threads attached to a passage of the transcript. */
export function inlineThreads(threads: CommentThread[]): CommentThread[] {
  return threads.filter((t) => !!t.anchor);
}

/** A side answer that has been "in progress" this long was cut off by a
 *  restart; stop showing it as working. */
const AGENT_PENDING_STALE_MS = 10 * 60_000;

export function agentIsAnswering(
  thread: CommentThread,
  now = Date.now(),
): boolean {
  return (
    !!thread.agentPendingSince &&
    now - thread.agentPendingSince < AGENT_PENDING_STALE_MS
  );
}

/** The agent's name in a thread, as the server wrote it. */
export function threadAgentName(thread: CommentThread): string | undefined {
  return thread.comments.find((c) => c.agent)?.user;
}

function quote(text: string): string {
  return text
    .split("\n")
    .map((line) => (line.trim() ? `> ${line}` : ">"))
    .join("\n");
}

/**
 * The message a thread becomes in the composer when it is sent to the main
 * session: the passage, the conversation, and how to answer back so the
 * result lands in the thread as well as the transcript.
 */
export function sendToSessionText(thread: CommentThread): string {
  const parts: string[] = [];
  if (thread.anchor) parts.push(quote(thread.anchor.exact), "");
  parts.push("From a comment thread on this session:", "");
  for (const comment of thread.comments)
    parts.push(
      `**${comment.user}${comment.agent ? " (you, answering on the side)" : ""}:** ${comment.text}`,
    );
  parts.push(
    "",
    `Please take care of this. When you're done, reply in the thread (opensession-comments reply_to_comment_thread, threadId \`${thread.id}\`) with what you did.`,
  );
  return parts.join("\n");
}

/** One line of the opening comment, for lists and tooltips. */
export function threadPreview(thread: CommentThread, length = 80): string {
  const text = (thread.comments[0]?.text ?? "").replace(/\s+/g, " ").trim();
  return text.length > length ? `${text.slice(0, length - 1)}…` : text;
}

/**
 * Hand a thread to the main session: its text lands in the session's composer
 * (appended to any draft, cursor there), so the person reads it, edits it if
 * they like, and sends it as a normal turn.
 */
export function sendThreadToSession(
  sessionId: string,
  thread: CommentThread,
): void {
  requestYouShouldKnowChat(sessionId, sendToSessionText(thread));
}

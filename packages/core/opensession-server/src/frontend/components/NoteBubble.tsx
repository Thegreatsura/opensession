import React, { useState } from "react";
import { sendThreadToSession } from "../lib/comment-threads";
import { noteSurface } from "../lib/tinted-surface";
import type { CommentThread } from "../lib/types";
import { Button } from "../ui/button";
import { CommentThreadView, commentTime } from "./comments/CommentThreadView";
import { IconCheck } from "./icons";
import { UserAvatar } from "./UserAvatar";

/**
 * A team note in the session transcript: a comment thread with no passage,
 * sitting in the timeline where it was posted. People talk to each other
 * here; the agent's run never sees it (src/server/comment-threads.ts). The
 * deliberate yellow tint keeps it from being mistaken for a prompt or an
 * answer.
 *
 * It takes replies, @-mentions, an assignee and a resolve state like any
 * thread. A resolved note folds to one line so the timeline stays readable.
 */
export function NoteBubble({
  thread,
  sessionId,
}: {
  thread: CommentThread;
  /** Absent in read-only hosts (the sub-agent pane): no actions, no replies. */
  sessionId?: string;
}) {
  const [expanded, setExpanded] = useState(false);
  const root = thread.comments[0]!;
  const folded = thread.status === "resolved" && !expanded;

  return (
    <div
      // A note is a transcript block like any other, so it takes the same
      // centered reading column the turns and cards use (mx-auto +
      // --session-col) and the same mt-2/mb-6 rhythm.
      className="relative mx-auto mb-6 mt-2 w-full max-w-[var(--session-col)] rounded-2xl px-4 py-3.5"
      style={{ background: noteSurface("transparent") }}
      data-note-thread={thread.id}
    >
      {folded ? (
        <div className="flex min-w-0 items-center gap-2 text-supporting text-dim">
          <IconCheck size={16} className="shrink-0 text-faint" />
          <UserAvatar name={root.user} size={18} />
          <span className="min-w-0 truncate">
            <span className="font-semibold text-fg">{root.user}</span>
            {" · "}
            {root.text.replace(/\s+/g, " ")}
          </span>
          <span className="shrink-0 text-meta text-faint">
            {commentTime(root.ts)}
            {thread.comments.length > 1
              ? ` · ${thread.comments.length - 1} ${thread.comments.length === 2 ? "reply" : "replies"}`
              : ""}
          </span>
          <Button
            size="sm"
            variant="ghost"
            onClick={() => setExpanded(true)}
            className="ml-auto shrink-0 phone:min-h-11"
          >
            Show
          </Button>
        </div>
      ) : sessionId ? (
        <CommentThreadView
          thread={thread}
          sessionId={sessionId}
          rootLabel={<NoteTag />}
          onSendToSession={(t) => sendThreadToSession(sessionId, t)}
          onResolved={() => setExpanded(false)}
        />
      ) : (
        <ReadOnlyNote thread={thread} />
      )}
    </div>
  );
}

function NoteTag() {
  return (
    <span
      className="shrink-0 text-meta font-semibold"
      style={{ color: "var(--yellow)" }}
      title="Only the team sees this note"
    >
      Note
    </span>
  );
}

function ReadOnlyNote({ thread }: { thread: CommentThread }) {
  return (
    <div className="flex flex-col gap-3">
      {thread.comments.map((comment, index) => (
        <div key={comment.id} className="flex flex-col gap-1">
          <div className="flex items-center gap-2">
            <UserAvatar name={comment.user} size={20} />
            <span className="text-supporting font-semibold text-fg">
              {comment.user}
            </span>
            {index === 0 && <NoteTag />}
            <span className="text-meta text-faint">
              {commentTime(comment.ts)}
            </span>
          </div>
          <div className="whitespace-pre-wrap break-words pl-7 text-body leading-relaxed text-fg">
            {comment.text}
          </div>
        </div>
      ))}
    </div>
  );
}

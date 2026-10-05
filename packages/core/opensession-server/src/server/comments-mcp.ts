/**
 * opensession-comments: the session's comment threads, for the main agent.
 *
 * People comment on the transcript between themselves (comment-threads.ts),
 * and a thread can be handed to the main session with "Send to session". These
 * tools let the agent read the open threads and post its result back into the
 * thread it was asked about, so the conversation ends where it started.
 * Scoped to the run's own session; interactive runs only.
 */

import { z } from "zod";
import { formatThread, listThreads } from "./comment-threads";
import { addComment, agentName, updateThread } from "./comment-thread-service";
import { createSdkMcpServer, tool } from "./inprocess-mcp";

function text(s: string) {
  return { content: [{ type: "text" as const, text: s }] };
}

export function createCommentsMcpServer(ctx: { sessionId: string }) {
  return createSdkMcpServer({
    name: "opensession-comments",
    version: "1.0.0",
    tools: [
      tool(
        "list_comment_threads",
        "List the comment threads people left on this session's transcript, with the passage each one is attached to and its comments. Open threads only unless `includeResolved` is set.",
        { includeResolved: z.boolean().optional() },
        async (args) => {
          const threads = (await listThreads(ctx.sessionId)).filter(
            (t) => args.includeResolved || t.status === "open",
          );
          if (!threads.length) return text("No comment threads.");
          return text(
            threads
              .map((t) =>
                [
                  `### Thread ${t.id} (${t.status}${t.assignee ? `, assigned to ${t.assignee}` : ""})`,
                  t.anchor
                    ? `On the passage: "${t.anchor.exact.slice(0, 500)}"`
                    : "On the session as a whole.",
                  formatThread(t),
                ].join("\n"),
              )
              .join("\n\n"),
          );
        },
      ),
      tool(
        "reply_to_comment_thread",
        "Post a reply in one of this session's comment threads, as the agent. Use it to report back in a thread that was sent to you: what you found or what you changed. Keep it short; the people in the thread are notified.",
        {
          threadId: z.string(),
          text: z.string().describe("The reply, in Markdown."),
          resolve: z
            .boolean()
            .optional()
            .describe("Also resolve the thread, when the reply settles it."),
        },
        async (args) => {
          const result = await addComment(ctx.sessionId, args.threadId, {
            user: agentName(),
            agent: true,
            text: args.text,
          });
          if (!result.ok)
            return text(`Couldn't reply: ${result.reason.replace("_", " ")}.`);
          if (args.resolve)
            await updateThread(
              ctx.sessionId,
              args.threadId,
              { status: "resolved" },
              agentName(),
            );
          return text(args.resolve ? "Replied and resolved." : "Replied.");
        },
      ),
    ],
  });
}

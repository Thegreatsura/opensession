/**
 * An unanswered run-blocking question escalates to Slack. The escalation must
 * not put up a second card: a session has one card slot, so a second card
 * replaced the run's own card, and dismissing it never released the run.
 * A message sent while the run waits skips the question the same way.
 */
import { afterAll, expect, mock, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const scratch = mkdtempSync(join(tmpdir(), "os-ask-escalation-"));
process.env.OPENSESSION_SESSIONS_DIR = join(scratch, "sessions");

const SESSION = "os-ask-escalation-test";

const realMappings = await import("./shared/user-mappings");
mock.module("./shared/user-mappings", () => ({
  ...realMappings,
  resolveTeammate: (ref?: string | null) =>
    ref?.trim().toLowerCase() === "alex"
      ? { name: "Alex", slackId: "UALEX0001" }
      : null,
}));

const slackPosts: string[] = [];
const realSlack = await import("../agents/slack/slack-api");
mock.module("../agents/slack/slack-api", () => ({
  ...realSlack,
  openDirectMessage: async () => "DALEX",
  postSlackBlocks: async (_channel: string, text: string) => {
    slackPosts.push(text);
    return { ok: true, ts: `100.${slackPosts.length}` };
  },
  sendSlackMessage: async () => ({ ok: true }),
  updateSlackBlocks: async () => ({ ok: true }),
}));

// A web session driven by the person the question escalates to: exactly the
// case where a human ask would otherwise go up as a card first.
const realCache = await import("./session-cache");
mock.module("./session-cache", () => ({
  ...realCache,
  findSession: (id: string) =>
    id === SESSION
      ? { id, source: "opensession", startedBy: "Alex" }
      : undefined,
}));

const {
  makeAskHandler,
  offerAskCard,
  pendingAskAwaitingAnswer,
  pendingAskTimers,
  skipPendingAskForMessage,
} = await import("./asks");
const { deliverAsk, getAsk } = await import("./human-asks");

afterAll(() => {
  for (const timer of pendingAskTimers.values()) clearTimeout(timer.handle);
  pendingAskTimers.clear();
  rmSync(scratch, { recursive: true, force: true });
});

test("dismissing the card after Slack escalation releases the run", async () => {
  const result = makeAskHandler(SESSION)({
    questions: [
      {
        header: "Choice",
        question: "Which option?",
        options: [{ label: "One" }, { label: "Two" }],
      },
    ],
  });
  let original: Awaited<ReturnType<typeof pendingAskAwaitingAnswer>>;
  for (let i = 0; i < 100 && !original; i++) {
    original = await pendingAskAwaitingAnswer(SESSION);
    if (!original) await Bun.sleep(5);
  }
  expect(original).toBeDefined();

  // The kernel fires this after the UI window; call its handler directly.
  const escalate = (
    globalThis as typeof globalThis & {
      __opensessionSessionKernelRuntime?: {
        timerHandlers: Map<string, (timer: unknown) => Promise<void>>;
      };
    }
  ).__opensessionSessionKernelRuntime?.timerHandlers.get("ask_escalation");
  await escalate!({
    sessionId: SESSION,
    payload: { questionId: original!.questionId },
  });
  const askId = `ask-${original!.questionId}`;
  // What the kernel's human_ask_deliver effect runs.
  await deliverAsk(askId);
  await Bun.sleep(10);

  // Escalated straight to Slack, and the run's own card still holds the slot.
  expect(getAsk(askId)).toMatchObject({ state: "delivered" });
  expect(getAsk(askId)?.uiFirst).toBeUndefined();
  expect(slackPosts).toHaveLength(1);
  const pending = await pendingAskAwaitingAnswer(SESSION);
  expect(pending?.questionId).toBe(original!.questionId);

  // The web card's X sends a null answer.
  await pending!.resolve(null);
  expect(await result).toMatchObject({ behavior: "deny" });
  expect(getAsk(askId)?.state).toBe("cancelled");
});

async function waitForCard(sessionId: string) {
  for (let i = 0; i < 100; i++) {
    const pending = await pendingAskAwaitingAnswer(sessionId);
    if (pending) return pending;
    await Bun.sleep(5);
  }
  throw new Error("No question card went up");
}

test("a message sent while the run waits skips its question", async () => {
  const result = makeAskHandler(SESSION)({
    questions: [{ header: "Choice", question: "Which one?" }],
  });
  await waitForCard(SESSION);

  expect(await skipPendingAskForMessage(SESSION, true)).toBe(true);
  const outcome = await result;
  expect(outcome).toMatchObject({ behavior: "deny" });
  expect((outcome as { message: string }).message).toContain(
    "sent a message instead. Their message follows",
  );
  expect(await pendingAskAwaitingAnswer(SESSION)).toBeUndefined();
});

test("a message leaves a teammate's question card alone", async () => {
  const answers: unknown[] = [];
  const card = await offerAskCard(SESSION, [{ question: "Approve?" }], (a) =>
    answers.push(a),
  );
  expect(await skipPendingAskForMessage(SESSION, true)).toBe(false);
  expect(await pendingAskAwaitingAnswer(SESSION)).toBeDefined();
  expect(answers).toEqual([]);
  await card.close();
});

import type { RunEvent, RunState } from "./run-state";

type PromptThrowSettlementEvent = Extract<
  RunEvent,
  "start_failed" | "run_failed"
>;

/**
 * A prompt driver can throw before the engine emits its terminal event. Keep
 * that exceptional exit from abandoning the durable run it already claimed.
 */
export function promptThrowSettlementEvent(
  state: RunState,
): PromptThrowSettlementEvent | undefined {
  if (state === "starting") return "start_failed";
  if (
    state === "running" ||
    state === "ask_blocked" ||
    state === "interrupted" ||
    state === "reattaching"
  )
    return "run_failed";
  return undefined;
}

export async function settlePromptThrowRunState(input: {
  sessionId: string;
  runKey: string;
  state: RunState;
  error: unknown;
  transition: (
    sessionId: string,
    event: PromptThrowSettlementEvent,
    detail: Record<string, unknown>,
  ) => Promise<unknown>;
}): Promise<boolean> {
  const event = promptThrowSettlementEvent(input.state);
  if (!event) return false;
  await input.transition(input.sessionId, event, {
    run_key: input.runKey,
    source: "prompt_throw",
    error: String(input.error),
  });
  return true;
}

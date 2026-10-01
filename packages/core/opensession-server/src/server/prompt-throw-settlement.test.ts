import { describe, expect, test } from "bun:test";
import {
  promptThrowSettlementEvent,
  settlePromptThrowRunState,
} from "./prompt-throw-settlement";

describe("prompt throw settlement", () => {
  test("settles failures both before and after host registration", () => {
    expect(promptThrowSettlementEvent("starting")).toBe("start_failed");
    expect(promptThrowSettlementEvent("running")).toBe("run_failed");
    expect(promptThrowSettlementEvent("ask_blocked")).toBe("run_failed");
    expect(promptThrowSettlementEvent("interrupted")).toBe("run_failed");
    expect(promptThrowSettlementEvent("reattaching")).toBe("run_failed");
  });

  test("does not disturb a run that is already terminal", () => {
    expect(promptThrowSettlementEvent("idle")).toBeUndefined();
    expect(promptThrowSettlementEvent("stopped")).toBeUndefined();
    expect(promptThrowSettlementEvent("failed")).toBeUndefined();
  });

  test("fences the settlement to the failed physical run", async () => {
    const calls: unknown[][] = [];
    expect(
      await settlePromptThrowRunState({
        sessionId: "os-session",
        runKey: "rh-failed-host",
        state: "running",
        error: new Error("host connection failed"),
        transition: async (...args) => {
          calls.push(args);
        },
      }),
    ).toBe(true);
    expect(calls).toEqual([
      [
        "os-session",
        "run_failed",
        {
          run_key: "rh-failed-host",
          source: "prompt_throw",
          error: "Error: host connection failed",
        },
      ],
    ]);
  });
});

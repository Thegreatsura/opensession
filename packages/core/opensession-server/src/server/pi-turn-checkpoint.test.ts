import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm, stat, writeFile } from "fs/promises";
import { tmpdir } from "os";
import { join } from "path";
import {
  createPiTurnCheckpointWriter,
  danglingToolCalls,
  interruptedToolResultText,
  repairInterruptedPiTurn,
  takePiTurnCheckpoint,
  type PiTurnCheckpoint,
} from "./pi-turn-checkpoint";

let dir: string;
let path: string;
beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), "pi-checkpoint-"));
  path = join(dir, "turn-checkpoint.json");
});
afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

const exists = (p: string) =>
  stat(p).then(
    () => true,
    () => false,
  );

const assistantToolUse = (...ids: string[]) => ({
  type: "message",
  message: {
    role: "assistant",
    stopReason: "toolUse",
    content: [
      { type: "text", text: "Running it." },
      ...ids.map((id) => ({
        type: "toolCall",
        id,
        name: id.startsWith("r") ? "read" : "bash",
        arguments: {},
      })),
    ],
  },
});
const toolResult = (id: string) => ({
  type: "message",
  message: { role: "toolResult", toolCallId: id, content: [] },
});

describe("createPiTurnCheckpointWriter", () => {
  test("records the streamed reply and running tools, and forgets ended ones", async () => {
    const writer = createPiTurnCheckpointWriter(path, "pi-1", 60_000);
    writer.observe({ type: "message_start", message: { role: "assistant" } });
    writer.observe({
      type: "message_update",
      assistantMessageEvent: { type: "text_delta", delta: "Half an" },
    });
    writer.observe({
      type: "message_update",
      assistantMessageEvent: { type: "thinking_delta", delta: "hidden" },
    });
    writer.observe({
      type: "message_update",
      assistantMessageEvent: { type: "text_delta", delta: " answer" },
    });
    writer.observe({
      type: "tool_execution_start",
      toolCallId: "b1",
      toolName: "bash",
    });
    writer.observe({
      type: "tool_execution_update",
      toolCallId: "b1",
      partialResult: { content: [{ type: "text", text: "line 1\nline 2" }] },
    });
    writer.observe({
      type: "tool_execution_start",
      toolCallId: "r1",
      toolName: "read",
    });
    writer.observe({ type: "tool_execution_end", toolCallId: "r1" });
    // A codemode script's nested calls are not the model's calls.
    writer.observe({
      type: "tool_execution_start",
      toolCallId: "c1/1",
      parentToolCallId: "c1",
      toolName: "bash",
    });
    await writer.flush();

    const saved = JSON.parse(await readFile(path, "utf8")) as PiTurnCheckpoint;
    expect(saved.piSessionId).toBe("pi-1");
    expect(saved.reply?.text).toBe("Half an answer");
    expect(saved.tools).toEqual({
      b1: { toolName: "bash", output: "line 1\nline 2" },
    });

    writer.observe({ type: "message_end", message: { role: "assistant" } });
    await writer.flush();
    const after = JSON.parse(await readFile(path, "utf8")) as PiTurnCheckpoint;
    expect(after.reply).toBeUndefined();
  });

  test("discard removes the file and stops later writes", async () => {
    const writer = createPiTurnCheckpointWriter(path, "pi-1", 60_000);
    writer.observe({
      type: "tool_execution_start",
      toolCallId: "b1",
      toolName: "bash",
    });
    await writer.flush();
    expect(await exists(path)).toBe(true);
    await writer.discard();
    writer.observe({
      type: "tool_execution_start",
      toolCallId: "b2",
      toolName: "bash",
    });
    await writer.flush();
    expect(await exists(path)).toBe(false);
  });
});

describe("takePiTurnCheckpoint", () => {
  test("returns the matching checkpoint once", async () => {
    const checkpoint: PiTurnCheckpoint = {
      version: 1,
      piSessionId: "pi-1",
      updatedAt: new Date().toISOString(),
      tools: {},
    };
    await writeFile(path, JSON.stringify(checkpoint));
    expect(await takePiTurnCheckpoint(path, "pi-1")).toEqual(checkpoint);
    expect(await takePiTurnCheckpoint(path, "pi-1")).toBeNull();
  });

  test("drops a checkpoint left by another Pi session", async () => {
    await writeFile(
      path,
      JSON.stringify({ version: 1, piSessionId: "old", tools: {} }),
    );
    expect(await takePiTurnCheckpoint(path, "pi-1")).toBeNull();
    expect(await exists(path)).toBe(false);
  });
});

describe("danglingToolCalls", () => {
  test("finds the tail message's calls that have no result", () => {
    expect(
      danglingToolCalls([
        assistantToolUse("b1", "r1", "b2"),
        toolResult("r1"),
        { type: "custom" },
      ]),
    ).toEqual([
      { id: "b1", name: "bash" },
      { id: "b2", name: "bash" },
    ]);
  });

  test("ignores answered, aborted, and superseded calls", () => {
    expect(
      danglingToolCalls([assistantToolUse("b1"), toolResult("b1")]),
    ).toEqual([]);
    const aborted = assistantToolUse("b1");
    aborted.message.stopReason = "aborted";
    expect(danglingToolCalls([aborted])).toEqual([]);
    expect(
      danglingToolCalls([
        assistantToolUse("b1"),
        { type: "message", message: { role: "user", content: "next" } },
      ]),
    ).toEqual([]);
  });
});

describe("repairInterruptedPiTurn", () => {
  test("closes dangling calls in a real Pi session with the output so far", async () => {
    const { SessionManager, buildSessionContext } =
      await import("@earendil-works/pi-coding-agent");
    const log = SessionManager.inMemory(dir);
    log.appendMessage({
      role: "user",
      content: "deploy it",
      timestamp: Date.now(),
    } as any);
    log.appendMessage(assistantToolUse("b1", "r1").message as any);

    const repair = repairInterruptedPiTurn(log, {
      version: 1,
      piSessionId: log.getSessionId(),
      updatedAt: new Date().toISOString(),
      reply: { id: "reply-1", text: "", startedAt: new Date().toISOString() },
      tools: { b1: { toolName: "bash", output: "pushing…" } },
    });

    expect(repair.reply).toBeUndefined();
    expect(repair.toolResults.map((r) => r.toolCallId)).toEqual(["b1", "r1"]);
    const messages = buildSessionContext(log.getEntries()).messages as any[];
    const results = messages.filter((m) => m.role === "toolResult");
    expect(results.map((m) => m.toolCallId)).toEqual(["b1", "r1"]);
    expect(results[0].isError).toBe(true);
    expect(results[0].content[0].text).toContain("pushing…");
    expect(results[0].content[0].text).toContain("Check its effects");
    expect(results[1].content[0].text).toContain("safe to run again");
    expect(danglingToolCalls(log.getBranch())).toEqual([]);
  });

  test("recovers only the reply when Pi never wrote a session file", () => {
    const reply = {
      id: "reply-1",
      text: "The cause is",
      startedAt: new Date().toISOString(),
    };
    expect(
      repairInterruptedPiTurn(null, {
        version: 1,
        piSessionId: "pi-1",
        updatedAt: reply.startedAt,
        reply,
        tools: {},
      }),
    ).toEqual({ toolResults: [], reply });
  });

  test("states plainly when a call produced no output", () => {
    expect(interruptedToolResultText("bash", "")).toContain(
      "produced no output",
    );
  });
});

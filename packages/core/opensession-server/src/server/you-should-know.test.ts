import { afterEach, describe, expect, it } from "bun:test";
import {
  classifyEntry,
  youShouldKnowRecordContent,
} from "@tellahq/opensession-protocol/notices";
import { parseJsonlLines } from "./jsonl-parser";
import { transcriptLineYouShouldKnow } from "./transcript-persistence";
import {
  __resetYouShouldKnowForTest,
  isCheckStep,
  noteYouShouldKnowStep,
  parseYouShouldKnow,
  type YouShouldKnowDeps,
} from "./you-should-know";
import { youShouldKnowObserverPrompt } from "./you-should-know-prompt";

const SUGGESTION = [
  "learn: The main agent put multi-turn /ask behind a feature flag that's off by default, so users won't see it yet.",
  "tag: Heads up",
  "explain:",
  "**Multi-turn /ask is switched off**",
  "",
  "A **feature flag** is a switch that turns the feature on or off.",
].join("\n");

describe("parseYouShouldKnow", () => {
  it("reads learn: none as nothing to say", () => {
    expect(parseYouShouldKnow("learn: none")).toEqual({ kind: "none" });
    expect(parseYouShouldKnow("learn: None.")).toEqual({ kind: "none" });
    expect(parseYouShouldKnow('learn: "none"')).toEqual({ kind: "none" });
  });

  it("parses the line, tag and explanation", () => {
    expect(parseYouShouldKnow(SUGGESTION)).toEqual({
      kind: "line",
      line: "The main agent put multi-turn /ask behind a feature flag that's off by default, so users won't see it yet.",
      tag: "Heads up",
      explanation:
        "**Multi-turn /ask is switched off**\n\nA **feature flag** is a switch that turns the feature on or off.",
    });
  });

  it("defaults the tag and adds the closing period", () => {
    expect(
      parseYouShouldKnow("learn: Trendline never writes transcripts to S3"),
    ).toEqual({
      kind: "line",
      line: "Trendline never writes transcripts to S3.",
      tag: "You should know",
    });
  });

  it("reads a tag written on the learn line itself", () => {
    const parsed = parseYouShouldKnow(
      "learn: Reads now pay a KMS round-trip. tag: Heads up",
    );
    expect(parsed).toMatchObject({
      kind: "line",
      line: "Reads now pay a KMS round-trip.",
      tag: "Heads up",
    });
  });

  it("refuses output without a learn line or with an overlong one", () => {
    expect(parseYouShouldKnow("Nothing to add.")).toEqual({
      kind: "unparsable",
    });
    expect(parseYouShouldKnow(`learn: ${"word ".repeat(80)}`)).toEqual({
      kind: "unparsable",
    });
  });
});

describe("observer prompt", () => {
  it("lists what to skip, or says nothing yet", () => {
    const empty = youShouldKnowObserverPrompt([], []);
    expect(empty).toContain("learn: none");
    expect(empty.match(/\(nothing yet\)/g)?.length).toBe(2);
    const listed = youShouldKnowObserverPrompt(["Shown before."], ["Known."]);
    expect(listed).toContain("- Shown before.");
    expect(listed).toContain("- Known.");
  });
});

describe("noteYouShouldKnowStep", () => {
  afterEach(() => __resetYouShouldKnowForTest());

  function harness(answer: string | null = SUGGESTION) {
    const prompts: string[] = [];
    const appended: string[] = [];
    const deps: YouShouldKnowDeps = {
      oneShot: async (prompt) => {
        prompts.push(prompt);
        return answer;
      },
      transcriptTail: async () => "[1] user: ship multi-turn /ask",
      append: async (_sessionId, content) => {
        appended.push(content);
      },
      isWatched: () => true,
      isEnabledFor: (user) => user === "ada",
    };
    return { deps, prompts, appended };
  }

  const step = (n: number, turnId = "turn-1") => ({
    sessionId: "s1",
    user: "ada",
    step: n,
    turnId,
  });

  it("checks on every sixth step only", async () => {
    expect([0, 1, 5, 6, 7, 12].map(isCheckStep)).toEqual([
      false,
      false,
      false,
      true,
      false,
      true,
    ]);
    const { deps, prompts } = harness("learn: none");
    await noteYouShouldKnowStep(step(5), deps);
    expect(prompts).toHaveLength(0);
    await noteYouShouldKnowStep(step(6), deps);
    expect(prompts).toHaveLength(1);
    expect(prompts[0]).toContain("ship multi-turn /ask");
  });

  it("does nothing for someone who did not opt in, or with nobody watching", async () => {
    const { deps, prompts } = harness();
    await noteYouShouldKnowStep({ ...step(6), user: "bob" }, deps);
    await noteYouShouldKnowStep(step(6), { ...deps, isWatched: () => false });
    expect(prompts).toHaveLength(0);
  });

  it("appends one suggestion per turn and never repeats a line", async () => {
    const { deps, prompts, appended } = harness();
    await noteYouShouldKnowStep(step(6), deps);
    expect(appended).toEqual([
      youShouldKnowRecordContent(
        "Heads up",
        "The main agent put multi-turn /ask behind a feature flag that's off by default, so users won't see it yet.",
        "**Multi-turn /ask is switched off**\n\nA **feature flag** is a switch that turns the feature on or off.",
      ),
    ]);
    // Same turn: no second check at all.
    await noteYouShouldKnowStep(step(12), deps);
    expect(prompts).toHaveLength(1);
    // Next turn: the observer is told what was already shown, and the same
    // line is dropped if it comes back anyway.
    await noteYouShouldKnowStep(step(6, "turn-2"), deps);
    expect(prompts).toHaveLength(2);
    expect(prompts[1]).toContain(
      "- The main agent put multi-turn /ask behind a feature flag",
    );
    expect(appended).toHaveLength(1);
  });

  it("keeps one check in flight per session", async () => {
    const { deps, prompts } = harness("learn: none");
    const first = noteYouShouldKnowStep(step(6), deps);
    await noteYouShouldKnowStep(step(12), deps);
    await first;
    expect(prompts).toHaveLength(1);
  });
});

describe("you-should-know transcript record", () => {
  it("round-trips into a notice with the explanation behind the toggle", () => {
    const content = youShouldKnowRecordContent(
      "Heads up",
      "Multi-turn /ask is off by default.",
      "**Multi-turn /ask is switched off**\n\nIt ships dark.",
    );
    const [entry] = parseJsonlLines([
      JSON.stringify(transcriptLineYouShouldKnow(content, "e1")),
    ]);
    expect(entry).toMatchObject({
      type: "system",
      noticeKind: "you-should-know",
      content,
    });
    const classified = classifyEntry(entry!);
    expect(classified.notice).toEqual({
      kind: "you-should-know",
      title: "Heads up · Multi-turn /ask is off by default.",
      tone: "info",
      body: "collapsed",
    });
    expect(classified.content).toBe(
      "**Multi-turn /ask is switched off**\n\nIt ships dark.",
    );
  });
});

import { describe, expect, test } from "bun:test";
import {
  decodeSlackMentions,
  encodeSlackMentions,
  slackMessageLength,
} from "./slack-mentions";

const users = [
  { id: "U01ALEX", name: "Alex" },
  { id: "U02ALEXK", name: "Alex Kim" },
];

describe("Slack mentions", () => {
  test("encodes picked names as Slack tokens", () => {
    const mentions = new Map([
      ["Alex", "U01ALEX"],
      ["Alex Kim", "U02ALEXK"],
    ]);
    expect(encodeSlackMentions("@Alex Kim and @Alex, see this", mentions)).toBe(
      "<@U02ALEXK> and <@U01ALEX>, see this",
    );
  });

  test("leaves partial words and emails alone", () => {
    const mentions = new Map([["Alex", "U01ALEX"]]);
    expect(encodeSlackMentions("@Alexandra a@Alex", mentions)).toBe(
      "@Alexandra a@Alex",
    );
  });

  test("decodes known tokens and keeps unknown ones", () => {
    const decoded = decodeSlackMentions(
      "Thanks <@U01ALEX> and <@U09NOBODY>",
      users,
    );
    expect(decoded.text).toBe("Thanks @Alex and <@U09NOBODY>");
    expect(decoded.mentions.get("Alex")).toBe("U01ALEX");
  });

  test("round-trips through decode and encode", () => {
    const text = "<@U02ALEXK> shipped it";
    const decoded = decodeSlackMentions(text, users);
    expect(encodeSlackMentions(decoded.text, decoded.mentions)).toBe(text);
  });

  test("counts a token as a short mention", () => {
    expect(slackMessageLength("hi <@U02ALEXK>")).toBe(5);
  });
});

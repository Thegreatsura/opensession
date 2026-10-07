import { describe, expect, test } from "bun:test";
import { slackMentionUserFromMember } from "./user-directory";

describe("Slack user directory", () => {
  test("prefers the display name and keeps the real name as a hint", () => {
    expect(
      slackMentionUserFromMember({
        id: "U01ALEX",
        name: "alex",
        profile: {
          display_name: "Alex",
          real_name: "Alex Kim",
          image_48: "https://example.test/a.png",
        },
      }),
    ).toEqual({
      id: "U01ALEX",
      name: "Alex",
      realName: "Alex Kim",
      image: "https://example.test/a.png",
    });
  });

  test("falls back to the real name", () => {
    expect(
      slackMentionUserFromMember({
        id: "U02SAM",
        profile: { display_name: "", real_name: "Sam Patel" },
      }),
    ).toEqual({ id: "U02SAM", name: "Sam Patel" });
  });

  test("skips bots, deactivated people, and Slackbot", () => {
    for (const member of [
      { id: "U03BOT", is_bot: true, profile: { real_name: "Deploy" } },
      { id: "U04GONE", deleted: true, profile: { real_name: "Former" } },
      { id: "USLACKBOT", profile: { real_name: "Slackbot" } },
    ])
      expect(slackMentionUserFromMember(member)).toBeUndefined();
  });
});

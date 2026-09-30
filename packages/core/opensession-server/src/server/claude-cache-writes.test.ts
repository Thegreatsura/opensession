import { describe, expect, test } from "bun:test";
import {
  cacheCreationUsage,
  claudeCacheWriteSplit,
} from "./claude-cache-writes";

describe("claudeCacheWriteSplit", () => {
  test("uses the reported split", () => {
    expect(
      claudeCacheWriteSplit({
        cache_creation_input_tokens: 300,
        cache_creation: {
          ephemeral_1h_input_tokens: 100,
          ephemeral_5m_input_tokens: 200,
        },
      }),
    ).toEqual({ oneHour: 100, fiveMinute: 200 });
  });

  test("counts writes with no split as 1-hour writes", () => {
    expect(claudeCacheWriteSplit({ cache_creation_input_tokens: 300 })).toEqual(
      { oneHour: 300, fiveMinute: 0 },
    );
    expect(claudeCacheWriteSplit(undefined)).toEqual({
      oneHour: 0,
      fiveMinute: 0,
    });
  });

  test("never reports more 5-minute writes than the total", () => {
    expect(
      claudeCacheWriteSplit({
        cache_creation_input_tokens: 100,
        cache_creation: { ephemeral_5m_input_tokens: 400 },
      }),
    ).toEqual({ oneHour: 0, fiveMinute: 100 });
  });

  test("renders the resolved split in the API usage shape", () => {
    expect(cacheCreationUsage({ cache_creation_input_tokens: 42 })).toEqual({
      ephemeral_1h_input_tokens: 42,
      ephemeral_5m_input_tokens: 0,
    });
  });
});

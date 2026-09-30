/**
 * Anthropic prices a prompt-cache write by its TTL: a 5-minute write costs
 * 1.25x base input (a model's `cacheWrite` rate) and a 1-hour write costs 2x
 * base input. API usage reports the split per request under
 * `usage.cache_creation.{ephemeral_1h_input_tokens, ephemeral_5m_input_tokens}`,
 * and the Agent SDK passes it through on `assistant` messages, `message_start`
 * stream events and the turn-wide `result` usage. `message_delta` usage carries
 * only the `cache_creation_input_tokens` total.
 *
 * Only tokens reported as 5-minute writes price at the 5-minute rate; every
 * other write, including usage with no split, counts as a 1-hour write. Claude
 * Code sends subscription traffic with the 1-hour TTL, so an unsplit write is
 * almost certainly a 1-hour one.
 */
export const CLAUDE_1H_CACHE_WRITE_INPUT_MULTIPLIER = 2;

/** Flat key the per-step usage map uses for the reported 5-minute writes. */
export const CACHE_WRITE_5M_FIELD = "cache_creation_5m_input_tokens";

export interface ClaudeCacheWriteSplit {
  oneHour: number;
  fiveMinute: number;
}

function tokens(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0
    ? value
    : 0;
}

/** Reported 5-minute writes from raw API usage or the flat step-usage key;
 * undefined when the usage reports no split. */
export function reportedFiveMinuteWrites(
  usage: Readonly<Record<string, unknown>>,
): number | undefined {
  const nested = usage.cache_creation as Record<string, unknown> | undefined;
  const value =
    nested && typeof nested === "object"
      ? nested.ephemeral_5m_input_tokens
      : usage[CACHE_WRITE_5M_FIELD];
  return typeof value === "number" ? tokens(value) : undefined;
}

/** Splits `cache_creation_input_tokens` into 1-hour and 5-minute writes. */
export function claudeCacheWriteSplit(
  usage: Readonly<Record<string, unknown>> | null | undefined,
): ClaudeCacheWriteSplit {
  const u = usage || {};
  const total = tokens(u.cache_creation_input_tokens);
  const fiveMinute = Math.min(reportedFiveMinuteWrites(u) ?? 0, total);
  return { oneHour: total - fiveMinute, fiveMinute };
}

/** The resolved split in Anthropic's `usage.cache_creation` shape. */
export function cacheCreationUsage(
  usage: Readonly<Record<string, unknown>> | null | undefined,
): { ephemeral_1h_input_tokens: number; ephemeral_5m_input_tokens: number } {
  const split = claudeCacheWriteSplit(usage);
  return {
    ephemeral_1h_input_tokens: split.oneHour,
    ephemeral_5m_input_tokens: split.fiveMinute,
  };
}

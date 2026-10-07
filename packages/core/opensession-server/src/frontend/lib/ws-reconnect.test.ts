import { describe, expect, test } from "bun:test";
import {
  HANDOFF_WS_RECONNECT_MS,
  MAX_WS_RECONNECT_MS,
  NORMAL_WS_RECONNECT_MS,
  webSocketReconnectDelay,
} from "./ws-reconnect";

describe("webSocketReconnectDelay", () => {
  test("reconnects quickly after an announced handoff", () => {
    expect(webSocketReconnectDelay(1001, true)).toBe(HANDOFF_WS_RECONNECT_MS);
  });

  test("recognizes the standard Service Restart close code", () => {
    expect(webSocketReconnectDelay(1012, false)).toBe(HANDOFF_WS_RECONNECT_MS);
  });

  test("keeps the ordinary outage backoff", () => {
    expect(webSocketReconnectDelay(1006, false)).toBe(NORMAL_WS_RECONNECT_MS);
  });

  test("a single rapid close keeps the base delay", () => {
    expect(webSocketReconnectDelay(1012, false, 1)).toBe(
      HANDOFF_WS_RECONNECT_MS,
    );
  });

  test("repeated rapid closes back off up to the cap", () => {
    expect(webSocketReconnectDelay(1012, false, 2)).toBe(500);
    expect(webSocketReconnectDelay(1012, false, 4)).toBe(2_000);
    expect(webSocketReconnectDelay(1006, false, 3)).toBe(8_000);
    expect(webSocketReconnectDelay(1012, false, 20)).toBe(MAX_WS_RECONNECT_MS);
  });
});

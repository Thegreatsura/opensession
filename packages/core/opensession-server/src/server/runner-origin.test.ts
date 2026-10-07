import { describe, expect, test } from "bun:test";
import {
  GATEWAY_TAILNET_ORIGIN,
  isRunnerTailnetOrigin,
  runnerTailnetOrigin,
} from "./runner-origin";

function request(forwardedFor?: string): Request {
  return new Request("http://example.test/runner-ws", {
    headers: forwardedFor ? { "x-forwarded-for": forwardedFor } : {},
  });
}

function peer(address: string) {
  return { requestIP: () => ({ address }) };
}

const BEHIND_GATEWAY = { OPENSESSION_GATEWAY_BACKEND_PORT: "41000" };

describe("Runner tailnet origin", () => {
  test("a direct peer passes only from the tailnet range", () => {
    const options = { trustForwardedFor: false, env: {} };
    expect(runnerTailnetOrigin(request(), peer("100.64.0.1"), options)).toBe(
      "100.64.0.1",
    );
    expect(
      runnerTailnetOrigin(request(), peer("::ffff:100.127.255.254"), options),
    ).toBe("100.127.255.254");
    for (const address of ["100.63.255.255", "100.128.0.1", "10.0.0.1", ""])
      expect(
        runnerTailnetOrigin(request(), peer(address), options),
      ).toBeUndefined();
    expect(runnerTailnetOrigin(request(), undefined, options)).toBeUndefined();
  });

  test("a direct non-loopback peer ignores X-Forwarded-For", () => {
    expect(
      runnerTailnetOrigin(request("100.64.0.1"), peer("203.0.113.9"), {
        trustForwardedFor: true,
        env: {},
      }),
    ).toBeUndefined();
  });

  test("loopback is not tailnet, through a tunnel or the gateway proxy", () => {
    for (const address of ["127.0.0.1", "::1", "::ffff:127.0.0.1"])
      for (const env of [{}, BEHIND_GATEWAY])
        expect(
          runnerTailnetOrigin(request(), peer(address), {
            trustForwardedFor: false,
            env,
          }),
        ).toBeUndefined();
  });

  test("X-Forwarded-For is ignored unless a trusted proxy is configured", () => {
    expect(
      runnerTailnetOrigin(request("100.64.0.1"), peer("127.0.0.1"), {
        trustForwardedFor: false,
        env: BEHIND_GATEWAY,
      }),
    ).toBeUndefined();
  });

  test("a trusted proxy's last hop decides", () => {
    const options = { trustForwardedFor: true, env: BEHIND_GATEWAY };
    expect(
      runnerTailnetOrigin(
        request("203.0.113.9, 100.70.1.2"),
        peer("127.0.0.1"),
        options,
      ),
    ).toBe("100.70.1.2");
    expect(
      runnerTailnetOrigin(
        request("100.70.1.2, 203.0.113.9"),
        peer("127.0.0.1"),
        options,
      ),
    ).toBeUndefined();
    expect(
      runnerTailnetOrigin(request(), peer("127.0.0.1"), options),
    ).toBeUndefined();
  });

  test("a tailnet-bound gateway proxy vouches for its relayed clients", () => {
    const origin = (env: Record<string, string>) =>
      runnerTailnetOrigin(request("100.64.0.1"), peer("127.0.0.1"), {
        trustForwardedFor: false,
        env,
      });
    expect(
      origin({
        ...BEHIND_GATEWAY,
        OPENSESSION_GATEWAY_PUBLIC_HOST: "100.90.0.1",
      }),
    ).toBe(GATEWAY_TAILNET_ORIGIN);
    for (const host of ["127.0.0.1", "0.0.0.0", "192.168.1.10", ""])
      expect(
        origin({ ...BEHIND_GATEWAY, OPENSESSION_GATEWAY_PUBLIC_HOST: host }),
      ).toBeUndefined();
    // Without a supervisor in front, the variable means nothing.
    expect(
      origin({ OPENSESSION_GATEWAY_PUBLIC_HOST: "100.90.0.1" }),
    ).toBeUndefined();
  });

  test("registration accepts exactly the origins the resolver returns", () => {
    expect(isRunnerTailnetOrigin("100.64.0.1")).toBe(true);
    expect(isRunnerTailnetOrigin(GATEWAY_TAILNET_ORIGIN)).toBe(true);
    for (const address of ["127.0.0.1", "::1", "10.0.0.1", ""])
      expect(isRunnerTailnetOrigin(address)).toBe(false);
  });
});

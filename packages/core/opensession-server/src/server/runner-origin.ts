/**
 * Where a Runner request came from, for the tailnet gate on
 * `/api/runners/register`, `/api/runners/heartbeat` and `/runner-ws`.
 *
 * Loopback is never tailnet evidence on its own: a private tunnel, an SSH
 * forward, or the gateway TCP proxy all reach the server from 127.0.0.1 while
 * the real client may be anywhere. A loopback peer passes only when the
 * operator has declared what sits in front of it:
 *
 * - `server.trustForwardedFor` (or `OPENSESSION_TRUST_FORWARDED_FOR=1`): a
 *   reverse proxy that overwrites `X-Forwarded-For` fronts every path to the
 *   server, so its last hop is the client.
 * - The gateway supervisor's own TCP proxy listens on a tailnet address
 *   (`OPENSESSION_GATEWAY_PUBLIC_HOST`, set only by the supervisor), so every
 *   client it relays connected to the tailnet.
 */
import { configuredServer } from "./config";
import { isTailnetIpv4, normalizeAddress } from "./shared/network-address";

/** Recorded for a Runner admitted through a tailnet-bound gateway proxy,
 * which relays raw bytes and so cannot name the client's own address. */
export const GATEWAY_TAILNET_ORIGIN = "tailnet (gateway)";

export function isRunnerTailnetOrigin(address: string): boolean {
  return address === GATEWAY_TAILNET_ORIGIN || isTailnetIpv4(address);
}

export type PeerServer = {
  requestIP?(req: Request): { address: string } | null;
};

export type RunnerOriginOptions = {
  trustForwardedFor?: boolean;
  env?: Record<string, string | undefined>;
};

function isLoopback(address: string): boolean {
  return address === "::1" || address.startsWith("127.");
}

/** The tailnet origin of a Runner request, or undefined when the request
 * cannot be shown to come from the tailnet. */
export function runnerTailnetOrigin(
  req: Request,
  server: PeerServer | undefined,
  options: RunnerOriginOptions = {},
): string | undefined {
  const peer = normalizeAddress(server?.requestIP?.(req)?.address ?? "");
  if (!peer) return undefined;
  if (!isLoopback(peer)) return isTailnetIpv4(peer) ? peer : undefined;

  const trustForwardedFor =
    options.trustForwardedFor ?? configuredServer().trustForwardedFor;
  if (trustForwardedFor) {
    const last = req.headers
      .get("x-forwarded-for")
      ?.split(",")
      .map((hop) => hop.trim())
      .filter(Boolean)
      .at(-1);
    const client = normalizeAddress(last ?? "");
    return isTailnetIpv4(client) ? client : undefined;
  }

  const env = options.env ?? process.env;
  if (
    env.OPENSESSION_GATEWAY_BACKEND_PORT &&
    isTailnetIpv4(env.OPENSESSION_GATEWAY_PUBLIC_HOST ?? "")
  )
    return GATEWAY_TAILNET_ORIGIN;
  return undefined;
}

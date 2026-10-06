export const NORMAL_WS_RECONNECT_MS = 2_000;
export const HANDOFF_WS_RECONNECT_MS = 250;
export const MAX_WS_RECONNECT_MS = 15_000;
/** A socket that closes sooner than this after opening counts as a rapid
 * close. Repeated rapid closes mean reconnecting does not help, so each one
 * doubles the wait instead of reloading the session several times a second. */
export const RAPID_WS_CLOSE_MS = 5_000;

/** A graceful server handoff should reconnect promptly without turning an
 * ordinary outage into a tight retry loop. Close code 1012 is the standard
 * Service Restart signal; the explicit frame covers older servers.
 * `rapidCloses` counts consecutive sockets that opened and then closed within
 * RAPID_WS_CLOSE_MS. */
export function webSocketReconnectDelay(
  closeCode: number,
  handoffAnnounced: boolean,
  rapidCloses = 0,
): number {
  const base =
    closeCode === 1012 || handoffAnnounced
      ? HANDOFF_WS_RECONNECT_MS
      : NORMAL_WS_RECONNECT_MS;
  if (rapidCloses <= 1) return base;
  return Math.min(MAX_WS_RECONNECT_MS, base * 2 ** (rapidCloses - 1));
}

/**
 * Which WebSocket clients may receive compressed (permessage-deflate) frames.
 *
 * Bun finishes a compressed message whose deflate output is under about 4 KB
 * with a BFINAL block instead of the usual sync flush. RFC 7692 allows that,
 * but Apple's networking stack does not: CFNetwork delivers the message, then
 * fails the connection with "Protocol error" and drops TCP without a close
 * frame. Safari, Home Screen web apps, every iOS browser (all WebKit), and the
 * native apps all use that stack, so a short transcript frame put them in a
 * "Connection lost" loop: open, watch, receive a small compressed frame, die.
 *
 * Such clients get uncompressed frames. Chromium (desktop Chrome, Electron)
 * handles both endings and keeps compression.
 */
export function clientAcceptsCompressedFrames(
  userAgent: string | null | undefined,
): boolean {
  if (!userAgent) return true;
  if (/\bCFNetwork\//.test(userAgent)) return false;
  return !(
    /\bAppleWebKit\//.test(userAgent) &&
    !/\b(?:Chrome|Chromium)\//.test(userAgent)
  );
}

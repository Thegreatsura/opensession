import { z } from "zod";

/**
 * Where a framed page says it is. A Browser or Portal page is cross-origin,
 * so this window cannot read its location; the page can tell us instead:
 *
 *   parent.postMessage({ type: "opensession:location", href: location.href }, "*")
 *
 * after each load and client-side navigation. A page may only report its
 * own origin, so a report can never make the address bar show another site.
 */
export const FRAME_LOCATION_MESSAGE = "opensession:location";

const reportSchema = z.object({
  type: z.literal(FRAME_LOCATION_MESSAGE),
  href: z.string().url(),
});

export function frameLocationReport(
  event: Pick<MessageEvent, "data" | "origin" | "source">,
  frame: Window | null | undefined,
): string | null {
  if (!frame || event.source !== frame) return null;
  const report = reportSchema.safeParse(event.data);
  if (!report.success) return null;
  const url = new URL(report.data.href);
  return url.origin === event.origin &&
    (url.protocol === "http:" || url.protocol === "https:")
    ? url.href
    : null;
}

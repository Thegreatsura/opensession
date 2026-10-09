import { z } from "zod";
import {
  MAX_DRAFT_CHARS,
  autocompleteAvailable,
  completeComposerDraft,
  takeAutocompleteSlot,
} from "../composer-autocomplete";
import { findSessionAsync } from "../session-cache";
import type { RouteContext } from "./context";

const bodySchema = z.object({
  draft: z
    .string()
    .max(MAX_DRAFT_CHARS * 4)
    .refine((draft) => draft.trim().length >= 2),
});

/**
 * Composer autocomplete (composer-autocomplete.ts).
 *
 * GET  /api/composer-autocomplete              → { available }
 * POST /api/sessions/:id/composer-complete     → { completion } | { available: false }
 *
 * The call is billed to the instance key, so it is rate limited per person.
 * When web sign-in is off every request is already the one local operator.
 */
export async function handleComposerAutocompleteRoutes(
  ctx: RouteContext,
): Promise<Response | undefined> {
  if (ctx.path === "/api/composer-autocomplete" && ctx.req.method === "GET")
    return Response.json(
      { available: await autocompleteAvailable() },
      { headers: { "Cache-Control": "no-store" } },
    );
  const match = ctx.path.match(/^\/api\/sessions\/([^/]+)\/composer-complete$/);
  if (!match || ctx.req.method !== "POST") return undefined;
  const parsed = bodySchema.safeParse(await ctx.req.json().catch(() => null));
  if (!parsed.success)
    return Response.json({ error: "Invalid draft." }, { status: 400 });
  let sessionId: string;
  try {
    sessionId = decodeURIComponent(match[1]!);
  } catch {
    return Response.json({ error: "Invalid session." }, { status: 400 });
  }
  const session = await findSessionAsync(sessionId);
  if (!session)
    return Response.json({ error: "Session not found." }, { status: 404 });
  if (
    (session.source !== "opensession" && session.source !== "slack") ||
    session.archived
  )
    return Response.json({ completion: null });
  if (!takeAutocompleteSlot(ctx.authUser?.login ?? "local"))
    return Response.json({ error: "Slow down." }, { status: 429 });
  const result = await completeComposerDraft({
    sessionId,
    draft: parsed.data.draft,
    signal: ctx.req.signal,
  });
  if (result.status === "unavailable")
    return Response.json({ available: false });
  if (result.status === "error")
    return Response.json({ completion: null }, { status: 502 });
  return Response.json(
    { completion: result.completion },
    { headers: { "Cache-Control": "no-store" } },
  );
}

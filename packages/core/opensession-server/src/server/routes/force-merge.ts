/**
 * The driver's side of a force_merge_pull_request card (force-merge.ts):
 *
 *   GET  /api/force-merge?sessionId=         -> { request | null, canConfirm }
 *   POST /api/force-merge/:id/confirm        { sessionId }
 *   POST /api/force-merge/:id/cancel         { sessionId }
 *
 * Both answers need a verified GitHub sign-in; machine auth and the no-auth
 * name picker cannot answer, so nothing running in a session can confirm its
 * own card. Only the driver can confirm, and the merge runs with their own
 * GitHub token. Any signed-in viewer may cancel.
 */
import type { RouteContext } from "./context";
import { readRequestTextWithinLimit } from "../shared/bounded-body";
import { githubCredentialForLogin } from "../github-auth";
import {
  ForceMergeError,
  cancelForceMerge,
  confirmForceMerge,
  pendingForceMerge,
} from "../force-merge";

const reply = (data: object, status = 200) =>
  Response.json(data, { status, headers: { "Cache-Control": "no-store" } });

export async function handleForceMergeRoutes(
  ctx: RouteContext,
): Promise<Response | undefined> {
  const { path, req } = ctx;
  if (path !== "/api/force-merge" && !path.startsWith("/api/force-merge/"))
    return undefined;
  // The verified GitHub login, or "" for machine auth or a claimed name.
  const identity = ctx.authUser as
    | { login?: string; automation?: boolean }
    | null
    | undefined;
  const login =
    identity?.login && identity.automation !== true ? identity.login : "";

  if (path === "/api/force-merge" && req.method === "GET") {
    const open = pendingForceMerge(ctx.url.searchParams.get("sessionId") || "");
    return reply({
      request: open?.request ?? null,
      canConfirm: !!open && !!login && login.toLowerCase() === open.login,
    });
  }

  const match = path.match(
    /^\/api\/force-merge\/([a-f0-9-]{36})\/(confirm|cancel)$/,
  );
  if (!match || req.method !== "POST")
    return reply({ error: "Not found" }, 404);
  if (!login)
    return reply({ error: "Sign in with GitHub to answer a force merge" }, 401);
  // Cross-site POSTs are refused before routing (web-auth.ts
  // crossSiteViolation).
  let body: { sessionId?: unknown };
  try {
    body = JSON.parse(await readRequestTextWithinLimit(req, 4 * 1024));
  } catch {
    return reply({ error: "Invalid request" }, 400);
  }
  const sessionId = typeof body.sessionId === "string" ? body.sessionId : "";
  try {
    if (match[2] === "cancel") {
      cancelForceMerge(sessionId, match[1]!, login);
      return reply({ ok: true });
    }
    const result = await confirmForceMerge(
      sessionId,
      match[1]!,
      login,
      githubCredentialForLogin(login),
    );
    return reply({ ok: result.status === "merged", result });
  } catch (error) {
    if (error instanceof ForceMergeError)
      return reply({ error: error.message }, error.status);
    console.error("[force-merge] Answer failed:", error);
    return reply({ error: "Couldn't answer the force merge" }, 500);
  }
}

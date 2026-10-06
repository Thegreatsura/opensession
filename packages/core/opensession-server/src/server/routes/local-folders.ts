/**
 * Session viewers' side of local folders (local-folders.ts).
 *
 *   GET  /api/local-folders?sessionId=   -> { folders }
 *   POST /api/local-folders/disconnect   { sessionId, key } -> { ok }
 *
 * Connecting happens on the device that holds the folder, over its bridge
 * socket. Disconnecting works from any device, but only for the person who
 * connected the folder.
 */
import type { RouteContext } from "./context";
import { requestUser } from "./context";
import { readRequestTextWithinLimit } from "../shared/bounded-body";
import { detachLocalFolder, sessionLocalFolders } from "../local-folders";

const reply = (data: object, status = 200) =>
  Response.json(data, { status, headers: { "Cache-Control": "no-store" } });

export async function handleLocalFolderRoutes(
  ctx: RouteContext,
): Promise<Response | undefined> {
  const { path, req } = ctx;
  if (path === "/api/local-folders" && req.method === "GET")
    return reply({
      folders: sessionLocalFolders(ctx.url.searchParams.get("sessionId") || ""),
    });
  if (path !== "/api/local-folders/disconnect") return undefined;
  if (req.method !== "POST") return reply({ error: "Not found" }, 404);
  let body: { sessionId?: unknown; key?: unknown; user?: unknown };
  try {
    body = JSON.parse(await readRequestTextWithinLimit(req, 16 * 1024));
  } catch {
    return reply({ error: "Invalid request" }, 400);
  }
  const user = requestUser(ctx, body.user);
  const sessionId = typeof body.sessionId === "string" ? body.sessionId : "";
  const key = typeof body.key === "string" ? body.key : "";
  if (!user || !sessionId || !key)
    return reply({ error: "Invalid request" }, 400);
  const ok = detachLocalFolder(sessionId, key, user);
  return ok
    ? reply({ ok })
    : reply(
        { error: "Only the person who connected it can disconnect it" },
        403,
      );
}

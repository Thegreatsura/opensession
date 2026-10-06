/**
 * Session-history search route — the same index the opensession-search MCP
 * tools query (src/server/session-index.ts). Read-only.
 */

import type { RouteContext } from "./context";
import { searchIndexCount, searchSessionHistory } from "../session-index";

export async function handleSearchRoutes(
  ctx: RouteContext,
): Promise<Response | undefined> {
  const { req, url, path } = ctx;

  if (path === "/api/search/history" && req.method === "GET") {
    const q = url.searchParams.get("q")?.trim();
    if (!q) return Response.json({ error: "missing ?q=" }, { status: 400 });
    const repo = url.searchParams.get("repo") || undefined;
    const days = parseInt(url.searchParams.get("days") || "", 10) || undefined;
    const limit =
      parseInt(url.searchParams.get("limit") || "", 10) || undefined;
    const [hits, total] = await Promise.all([
      searchSessionHistory(q, { repo, days, limit }),
      searchIndexCount(),
    ]);
    return Response.json({ hits, total });
  }

  return undefined;
}

/**
 * /api/memory in repo mode: the memory-v2 endpoint shapes on top of the
 * memory repositories, plus history, revert, file view and remotes.
 *
 * Every Settings write is a commit authored as the signed-in person. Reads
 * go to the derived index after a freshness check. All work runs on the
 * memory worker; nothing here touches git or SQLite directly.
 */

import type { RouteContext } from "./context";
import {
  AMBIENT_MEMORY_BUDGET_BYTES,
  MEMORY_KINDS,
  MEMORY_STATES,
  RETRIEVED_MEMORY_BUDGET_BYTES,
  type MemoryFilters,
  type MemoryKind,
  type MemoryRecord,
  type MemoryState,
} from "../memory-v2";
import { describeScope, invalidateMemorySnapshot } from "../session-memory";
import { REPOS } from "../worktree";
import { memoryRepo } from "../memory-repo/client";
import { isoDay } from "../memory-repo/format";
import { isValidRepoName, locateScope, TEAM_REPO } from "../memory-repo/layout";
import { MemoryRepoError, type Author } from "../memory-repo/service";
import { ENTRY_POINT_BUDGET_BYTES } from "../memory-repo/session";
import { dreamingLabel } from "../memory-repo/dreaming";

export type ScopeAccess = (ctx: RouteContext, scopeKey: string) => boolean;

function repoScopeKey(repo: string): string {
  return repo === TEAM_REPO ? "workspace" : repo;
}

function author(ctx: RouteContext): Author | undefined {
  const user = ctx.authUser;
  if (!user) return undefined;
  return {
    name: user.name || user.login,
    email: user.login ? `${user.login}@users.noreply.github.com` : undefined,
  };
}

function actor(ctx: RouteContext): string | undefined {
  return ctx.authUser?.login || ctx.authUser?.name || undefined;
}

function summaryRecord(record: MemoryRecord) {
  return {
    id: record.id,
    scopeKey: record.scopeKey,
    summary: record.summary,
    hasDetails: !!record.details,
    kind: record.kind,
    tier: record.tier,
    state: record.state,
    source: record.source,
    createdAt: record.createdAt,
    updatedAt: record.updatedAt,
    lastConfirmedAt: record.lastConfirmedAt,
    expiresAt: record.expiresAt,
    supersedes: record.supersedes,
    supersededBy: record.supersededBy,
    tags: record.tags,
    retrievalCount: record.retrievalCount,
    lastRetrievedAt: record.lastRetrievedAt,
    path: record.path,
    repo: locateScope(record.scopeKey)?.repo,
  };
}

function errorResponse(error: unknown): Response {
  if (error instanceof MemoryRepoError)
    return Response.json({ error: error.message }, { status: error.status });
  return Response.json(
    { error: error instanceof Error ? error.message : String(error) },
    { status: 400 },
  );
}

function validKind(value: unknown): value is MemoryKind {
  return (
    typeof value === "string" && MEMORY_KINDS.includes(value as MemoryKind)
  );
}

function validState(value: unknown): value is MemoryState {
  return (
    typeof value === "string" && MEMORY_STATES.includes(value as MemoryState)
  );
}

function today(): string {
  return isoDay(new Date());
}

function tagsFrom(value: unknown): string[] | undefined {
  return Array.isArray(value)
    ? value.map(String).filter(Boolean).slice(0, 12)
    : undefined;
}

export async function handleRepoMemoryRoutes(
  ctx: RouteContext,
  canAccess: ScopeAccess,
): Promise<Response | undefined> {
  const { req, url, path } = ctx;
  const canAccessRepo = (repo: string) =>
    isValidRepoName(repo) && canAccess(ctx, repoScopeKey(repo));
  try {
    await memoryRepo.service("freshAll");

    // ── Repositories, history, files, remotes ─────────────────────────
    if (path === "/api/memory/repos" && req.method === "GET") {
      const names = (await memoryRepo.service("listRepos")).filter(
        canAccessRepo,
      );
      const repos = [];
      for (const name of names) {
        repos.push({
          name,
          label: dreamingLabel(name),
          head: await memoryRepo.service("head", name),
          remote: await memoryRepo.service("remoteStatus", name),
        });
      }
      return Response.json({ repos });
    }

    if (path === "/api/memory/history" && req.method === "GET") {
      const repo = url.searchParams.get("repo") || TEAM_REPO;
      if (!canAccessRepo(repo))
        return Response.json(
          { error: "repository not found" },
          { status: 404 },
        );
      const entry = url.searchParams.get("entry") || undefined;
      const commits = await memoryRepo.service("history", repo, {
        limit: Number(url.searchParams.get("limit")) || 30,
        grep: entry,
      });
      return Response.json({ repo, commits });
    }

    if (path === "/api/memory/commit" && req.method === "GET") {
      const repo = url.searchParams.get("repo") || TEAM_REPO;
      const sha = url.searchParams.get("sha") || "";
      if (!canAccessRepo(repo))
        return Response.json(
          { error: "repository not found" },
          { status: 404 },
        );
      return Response.json({
        repo,
        sha,
        diff: await memoryRepo.service("diff", repo, sha),
      });
    }

    if (path === "/api/memory/revert" && req.method === "POST") {
      const body = await req.json().catch(() => null);
      const repo = String(body?.repo || "");
      if (!canAccessRepo(repo))
        return Response.json(
          { error: "repository not found" },
          { status: 404 },
        );
      const head = await memoryRepo.service(
        "revert",
        repo,
        String(body?.sha || ""),
        author(ctx),
      );
      invalidateMemorySnapshot();
      return Response.json({ ok: true, head });
    }

    if (path === "/api/memory/file" && req.method === "GET") {
      const repo = url.searchParams.get("repo") || TEAM_REPO;
      const file = url.searchParams.get("path") || "MEMORY.md";
      if (!canAccessRepo(repo))
        return Response.json(
          { error: "repository not found" },
          { status: 404 },
        );
      const content = await memoryRepo.service("readFile", repo, file);
      if (content === null)
        return Response.json({ error: "file not found" }, { status: 404 });
      return Response.json({ repo, path: file, content });
    }

    if (path === "/api/memory/files" && req.method === "GET") {
      const repo = url.searchParams.get("repo") || TEAM_REPO;
      if (!canAccessRepo(repo))
        return Response.json(
          { error: "repository not found" },
          { status: 404 },
        );
      return Response.json({
        repo,
        files: await memoryRepo.service("listFiles", repo),
      });
    }

    if (path === "/api/memory/remote" && req.method === "PUT") {
      const body = await req.json().catch(() => null);
      const repo = String(body?.repo || "");
      if (!canAccessRepo(repo))
        return Response.json(
          { error: "repository not found" },
          { status: 404 },
        );
      const remoteUrl =
        typeof body?.url === "string" && body.url.trim()
          ? body.url.trim()
          : null;
      const status = await memoryRepo.service("setRemote", repo, remoteUrl);
      return Response.json({ repo, remote: status });
    }

    if (path === "/api/memory/remote/sync" && req.method === "POST") {
      const body = await req.json().catch(() => null);
      const repo = String(body?.repo || "");
      if (!canAccessRepo(repo))
        return Response.json(
          { error: "repository not found" },
          { status: 404 },
        );
      return Response.json({
        repo,
        remote: await memoryRepo.service("syncRemote", repo),
      });
    }

    // ── memory-v2 shapes ──────────────────────────────────────────────
    if (path === "/api/memory/scopes" && req.method === "GET") {
      const stats = await memoryRepo.index("stats");
      const visibleStats = stats.scopes.filter((scope) =>
        canAccess(ctx, scope.scopeKey),
      );
      const byKey = new Map(
        visibleStats.map((scope) => [scope.scopeKey, scope]),
      );
      const keys = new Set([
        "workspace",
        ...Object.keys(REPOS).map((repo) => `repo-${repo}`),
        ...visibleStats.map((scope) => scope.scopeKey),
      ]);
      const scopes = [...keys]
        .filter((key) => canAccess(ctx, key))
        .map((key) => ({ scope: describeScope(key), stats: byKey.get(key) }))
        .filter(
          (
            item,
          ): item is typeof item & { scope: NonNullable<typeof item.scope> } =>
            !!item.scope,
        )
        .map(({ scope, stats: scopeStats }) => ({
          scope,
          count: scopeStats?.total ?? 0,
          pinnedCount: scopeStats?.pinned ?? 0,
          reviewCount: scopeStats?.review ?? 0,
          ambientChars: scopeStats?.ambientSummaryChars ?? 0,
          repo: locateScope(scope.key)?.repo,
        }));
      return Response.json({
        scopes,
        stats: {
          mode: "repo",
          ambientBudgetBytes: ENTRY_POINT_BUDGET_BYTES,
          retrievalBudgetBytes: RETRIEVED_MEMORY_BUDGET_BYTES,
          ambientUsedBytes: Math.min(
            ENTRY_POINT_BUDGET_BYTES,
            visibleStats.reduce(
              (sum, scope) => sum + scope.ambientSummaryChars,
              0,
            ),
          ),
          reviewCount: visibleStats.reduce(
            (sum, scope) => sum + scope.review,
            0,
          ),
          legacyAmbientBudgetBytes: AMBIENT_MEMORY_BUDGET_BYTES,
        },
      });
    }

    if (path === "/api/memory" && req.method === "GET") {
      const scopeKey = url.searchParams.get("scopeKey") || undefined;
      if (scopeKey && !describeScope(scopeKey))
        return Response.json({ error: "invalid scopeKey" }, { status: 400 });
      if (scopeKey && !canAccess(ctx, scopeKey))
        return Response.json({ error: "entry not found" }, { status: 404 });
      const kindParam = url.searchParams.get("kind") || undefined;
      const stateParam = url.searchParams.get("state") || undefined;
      if (kindParam && !validKind(kindParam))
        return Response.json({ error: "invalid kind" }, { status: 400 });
      if (stateParam && !validState(stateParam))
        return Response.json({ error: "invalid state" }, { status: 400 });
      const review = url.searchParams.get("review");
      const visibleKeys = (await memoryRepo.index("stats")).scopes
        .filter((scope) => canAccess(ctx, scope.scopeKey))
        .map((scope) => scope.scopeKey);
      if (!scopeKey && !visibleKeys.length) return Response.json({ items: [] });
      const filters: MemoryFilters = {
        scopeKeys: scopeKey ? [scopeKey] : visibleKeys,
        kinds: kindParam ? [kindParam as MemoryKind] : undefined,
        states: stateParam ? [stateParam as MemoryState] : undefined,
        confirmed:
          review === "needs_review"
            ? false
            : review === "confirmed"
              ? true
              : undefined,
      };
      const page = {
        cursor: url.searchParams.get("cursor") || undefined,
        limit: Number(url.searchParams.get("limit")) || 20,
      };
      const query = url.searchParams.get("q")?.trim();
      const result = query
        ? await memoryRepo.index("search", query, {
            ...filters,
            ...page,
            includeDetails: false,
          })
        : await memoryRepo.index("list", filters, page);
      return Response.json({
        items: result.items.map(summaryRecord),
        nextCursor: result.nextCursor,
      });
    }

    if (path === "/api/memory" && req.method === "POST") {
      const body = await req.json().catch(() => null);
      const scopeKey = String(body?.scopeKey || "");
      if (!describeScope(scopeKey) || !locateScope(scopeKey))
        throw new MemoryRepoError("Invalid scopeKey.");
      if (!canAccess(ctx, scopeKey))
        return Response.json({ error: "entry not found" }, { status: 404 });
      const kind = body?.kind === undefined ? "reference" : body.kind;
      if (!validKind(kind)) throw new MemoryRepoError("Invalid memory kind.");
      if (kind === "status" && !body?.expiresAt)
        throw new MemoryRepoError("Status memories require expiresAt.");
      const entry = await memoryRepo.service(
        "addEntry",
        {
          scopeKey,
          text: String(body?.summary || body?.text || ""),
          details: typeof body?.details === "string" ? body.details : undefined,
          kind,
          via: "settings",
          by: actor(ctx),
          confirmed: today(),
          expires:
            typeof body?.expiresAt === "string" ? body.expiresAt : undefined,
          tags: tagsFrom(body?.tags),
        },
        author(ctx),
      );
      invalidateMemorySnapshot();
      return Response.json({ entry: summaryRecord(entry) });
    }

    // Native app: PUT/DELETE /api/memory with { scopeKey, id, text }.
    if (
      path === "/api/memory" &&
      (req.method === "PUT" || req.method === "DELETE")
    ) {
      const body = await req.json().catch(() => null);
      const id = String(body?.id || "");
      const record = id ? await memoryRepo.index("get", id) : null;
      if (!record || !canAccess(ctx, record.scopeKey))
        return Response.json({ error: "entry not found" }, { status: 404 });
      if (req.method === "PUT") {
        const entry = await memoryRepo.service(
          "updateEntry",
          id,
          { text: String(body?.text || "") || undefined },
          author(ctx),
        );
        invalidateMemorySnapshot();
        return Response.json({ entry: summaryRecord(entry) });
      }
      await memoryRepo.service("removeEntries", [id], author(ctx), "Forget");
      invalidateMemorySnapshot();
      return Response.json({ ok: true });
    }

    if (path === "/api/memory/merge" && req.method === "POST") {
      const body = await req.json().catch(() => null);
      const ids: string[] = Array.isArray(body?.ids)
        ? [...new Set<string>(body.ids.map(String))]
        : [];
      const scopeKey = String(body?.scopeKey || "");
      if (!describeScope(scopeKey) || ids.length < 2 || ids.length > 50)
        throw new MemoryRepoError(
          "scopeKey and two to fifty ids are required.",
        );
      if (!canAccess(ctx, scopeKey))
        return Response.json({ error: "entry not found" }, { status: 404 });
      if (!validKind(body?.kind))
        throw new MemoryRepoError("Invalid memory kind.");
      const entry = await memoryRepo.service(
        "mergeEntries",
        ids,
        {
          scopeKey,
          text: String(body?.summary || ""),
          kind: body.kind,
          via: "settings",
          by: actor(ctx),
          confirmed: today(),
          expires:
            typeof body?.expiresAt === "string" ? body.expiresAt : undefined,
        },
        author(ctx),
      );
      invalidateMemorySnapshot();
      return Response.json({ entry: summaryRecord(entry) });
    }

    const recordMatch = path.match(/^\/api\/memory\/([^/]+)$/);
    if (recordMatch) {
      const id = decodeURIComponent(recordMatch[1]);
      const record = await memoryRepo.index("get", id);
      if (!record || !canAccess(ctx, record.scopeKey))
        return Response.json({ error: "entry not found" }, { status: 404 });
      const queryScope = url.searchParams.get("scopeKey");
      if (queryScope && record.scopeKey !== queryScope)
        return Response.json({ error: "entry not found" }, { status: 404 });

      if (req.method === "GET")
        return Response.json({
          entry: { ...record, repo: locateScope(record.scopeKey)?.repo },
        });
      if (req.method === "PATCH") {
        const body = await req.json().catch(() => null);
        if (body?.scopeKey && body.scopeKey !== record.scopeKey)
          return Response.json({ error: "entry not found" }, { status: 404 });
        let entry: MemoryRecord;
        const who = author(ctx);
        switch (body?.action) {
          case "pin":
            entry = await memoryRepo.service(
              "updateEntry",
              id,
              { pinned: true, confirmed: today() },
              who,
              "Pin memory",
            );
            break;
          case "unpin":
            entry = await memoryRepo.service(
              "updateEntry",
              id,
              { pinned: false },
              who,
              "Unpin memory",
            );
            break;
          case "confirm":
            entry = await memoryRepo.service(
              "updateEntry",
              id,
              { confirmed: today() },
              who,
              "Confirm memory",
            );
            break;
          case "archive":
            await memoryRepo.service("removeEntries", [id], who, "Archive");
            entry = (await memoryRepo.index("get", id)) ?? record;
            break;
          case "restore":
            entry = await memoryRepo.service("restoreEntry", id, who);
            break;
          default: {
            const nextKind = body?.kind === undefined ? record.kind : body.kind;
            if (!validKind(nextKind))
              throw new MemoryRepoError("Invalid memory kind.");
            const expires =
              body?.expiresAt === undefined
                ? undefined
                : body.expiresAt || null;
            if (nextKind === "status" && !(expires ?? record.expiresAt))
              throw new MemoryRepoError("Status memories require expiresAt.");
            entry = await memoryRepo.service(
              "updateEntry",
              id,
              {
                text:
                  typeof body?.summary === "string" ? body.summary : undefined,
                kind: body?.kind,
                expires,
                tags: tagsFrom(body?.tags),
              },
              who,
            );
          }
        }
        invalidateMemorySnapshot();
        return Response.json({ entry: summaryRecord(entry) });
      }
      if (req.method === "DELETE") {
        if (url.searchParams.get("confirm") !== "true")
          throw new MemoryRepoError(
            "confirm=true is required for permanent deletion.",
          );
        if (record.state === "active")
          throw new MemoryRepoError(
            "Archive this memory before deleting it permanently.",
          );
        // The entry already left the repository when it was archived; this
        // drops it from the index. Git history still holds it.
        await memoryRepo.index("delete", id);
        return Response.json({ ok: true });
      }
    }
  } catch (error) {
    return errorResponse(error);
  }
  return undefined;
}

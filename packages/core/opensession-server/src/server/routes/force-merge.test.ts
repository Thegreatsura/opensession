import { describe, expect, test } from "bun:test";
import { handleForceMergeRoutes } from "./force-merge";
import {
  pendingForceMerge,
  requestForceMerge,
  type ForceMergeDeps,
} from "../force-merge";
import { assessPrMergeReadiness } from "../pr-merge-readiness";

const HEAD = "d".repeat(40);
let merges = 0;
const deps: ForceMergeDeps = {
  audit: () => {},
  github: {
    verdict: async () =>
      assessPrMergeReadiness({
        repoId: "app",
        ghRepo: "tellahq/app",
        number: 9,
        title: "Ship it",
        url: "https://github.com/tellahq/app/pull/9",
        author: "ada",
        state: "OPEN",
        isDraft: false,
        baseRefName: "main",
        headRefName: "ship",
        headRefOid: HEAD,
        mergeable: "MERGEABLE",
        mergeStateStatus: "BLOCKED",
        reviewDecision: "REVIEW_REQUIRED",
        checks: [],
        latestReviews: [],
        reviewRequests: [],
        rules: null,
      }),
    mergeMethods: async () => ["squash"],
    head: async () => ({ sha: HEAD, open: true }),
    merge: async () => {
      merges++;
      return { ok: true };
    },
    comment: async () => {},
  },
};

function post(
  path: string,
  sessionId: string,
  authUser: { login: string; name: string; automation?: boolean } | null,
) {
  const url = new URL(`http://localhost${path}`);
  return handleForceMergeRoutes({
    req: new Request(url, {
      method: "POST",
      body: JSON.stringify({ sessionId }),
    }),
    url,
    path,
    publicPrefix: "",
    authUser,
  });
}

describe("force merge routes", () => {
  test("machine auth and signed-out callers cannot confirm", async () => {
    const outcome = requestForceMerge(
      "s-route",
      {
        target: { repoId: "app", ghRepo: "tellahq/app", number: 9 },
        reason: "review bot is down",
        driver: { name: "Ada", login: "ada" },
      },
      undefined,
      deps,
    );
    for (let i = 0; i < 20 && !pendingForceMerge("s-route"); i++)
      await Promise.resolve();
    const id = pendingForceMerge("s-route")!.request.id;
    const confirm = `/api/force-merge/${id}/confirm`;

    const machine = await post(confirm, "s-route", {
      login: "ada",
      name: "Ada",
      automation: true,
    });
    expect(machine!.status).toBe(401);
    expect((await post(confirm, "s-route", null))!.status).toBe(401);
    const other = await post(confirm, "s-route", {
      login: "bob",
      name: "Bob",
    });
    expect(other!.status).toBe(403);
    expect(merges).toBe(0);
    expect(pendingForceMerge("s-route")).not.toBeNull();

    // A signed-in viewer can cancel; nothing merges.
    const cancel = await post(`/api/force-merge/${id}/cancel`, "s-route", {
      login: "bob",
      name: "Bob",
    });
    expect(cancel!.status).toBe(200);
    expect((await outcome).result).toEqual({ status: "cancelled", by: "bob" });
    expect(merges).toBe(0);
  });

  test("GET says who may confirm", async () => {
    const url = new URL("http://localhost/api/force-merge?sessionId=none");
    const res = await handleForceMergeRoutes({
      req: new Request(url),
      url,
      path: "/api/force-merge",
      publicPrefix: "",
      authUser: null,
    });
    expect(await res!.json()).toEqual({ request: null, canConfirm: false });
  });
});

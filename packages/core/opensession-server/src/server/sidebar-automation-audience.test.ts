import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { catalogDocuments } from "./catalog-documents";
import { getConfigAsync } from "./config";
import { __setSessionKernelStoreForTest } from "./session-kernel/kernel";
import { SessionKernelStore } from "./session-kernel/store";
import {
  __resetAutomationAudienceForTest,
  loadSidebarSessionScopeContext,
  type SidebarSessionScope,
} from "./sidebar-session-scope";

let root: string;
let store: SessionKernelStore;
let previousStore: SessionKernelStore | undefined;
let previousRoot: string | undefined;
beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), "sidebar-automation-audience-"));
  previousRoot = process.env.OPENSESSION_STATE_DIR;
  process.env.OPENSESSION_STATE_DIR = root;
  store = new SessionKernelStore(join(root, "kernel.sqlite"));
  previousStore = __setSessionKernelStoreForTest(store);
  __resetAutomationAudienceForTest();
  await getConfigAsync();
});
afterEach(async () => {
  __resetAutomationAudienceForTest();
  __setSessionKernelStoreForTest(previousStore);
  store.close();
  if (previousRoot === undefined) delete process.env.OPENSESSION_STATE_DIR;
  else process.env.OPENSESSION_STATE_DIR = previousRoot;
  await rm(root, { recursive: true, force: true });
});

const scope: SidebarSessionScope = {
  user: "Ada",
  person: "me",
  repo: "all",
  autoCreated: "hide",
};

test("an automation write in this process refreshes the cached audience", async () => {
  const automations = catalogDocuments("automations");
  await automations.set("nightly", {
    id: "nightly",
    name: "Nightly",
    owner: "Ada",
  });
  const first = await loadSidebarSessionScopeContext(scope, []);
  expect(first.automations.get("nightly")?.owner).toBe("Ada");

  await automations.set("nightly", {
    id: "nightly",
    name: "Nightly",
    owner: "Grace",
  });
  const second = await loadSidebarSessionScopeContext(scope, []);
  expect(second.automations.get("nightly")?.owner).toBe("Grace");
  expect(second.automations.get("Nightly")?.owner).toBe("Grace");
});

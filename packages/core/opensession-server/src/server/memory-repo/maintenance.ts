/**
 * Memory repository upkeep, started from boot (never at import):
 *
 *   - repo mode: import memory-v2 once (sealed), reinstall the receive hooks
 *     so they run this release's validator, create Dreaming automations;
 *   - repo-mirror mode: mirror memory-v2 into the repositories every ten
 *     minutes and record the parity report;
 *   - both: sync repositories that have a remote every fifteen minutes.
 *
 * Every step runs on the memory worker and only logs on failure: memory
 * upkeep must never block or crash the gateway.
 */

import { auditAsync } from "../audit";
import { memoryDatabasePath, memoryRolloutMode } from "../memory-v2/runtime";
import { memoryRepo } from "./client";

const g = globalThis as typeof globalThis & {
  __osMemoryRepoTimers?: ReturnType<typeof setInterval>[];
};

async function step(name: string, fn: () => Promise<unknown>): Promise<void> {
  try {
    await fn();
  } catch (error) {
    console.warn(`[memory-repo] ${name} failed:`, error);
  }
}

async function migrate(mode: "import" | "mirror"): Promise<void> {
  const result = await memoryRepo.service(
    "migrateFromV2",
    memoryDatabasePath(),
    mode,
  );
  if (!result) return;
  const { parity } = result;
  auditAsync({
    kind: mode === "import" ? "memory_repo_migration" : "memory_repo_mirror",
    repos: result.repos,
    written: result.written,
    retired: result.retired,
    v2_active: parity.v2Active,
    repo_active: parity.repoActive,
    missing: parity.missing.length,
    extra: parity.extra.length,
    tier_mismatches: parity.tierMismatches.length,
    parity_ok: parity.ok,
  });
  console.log(
    `[memory-repo] ${mode}: ${result.written} written, ${result.retired} retired, parity ${parity.ok ? "ok" : "MISMATCH"} (${parity.v2Active} v2 active, ${parity.repoActive} repo active, ${parity.missing.length} missing, ${parity.tierMismatches.length} tier mismatches)`,
  );
}

export function startMemoryRepoMaintenance(): void {
  const mode = memoryRolloutMode();
  if (mode !== "repo" && mode !== "repo-mirror") return;
  for (const timer of g.__osMemoryRepoTimers ?? []) clearInterval(timer);
  const timers: ReturnType<typeof setInterval>[] = [];
  g.__osMemoryRepoTimers = timers;

  void (async () => {
    if (mode === "repo") {
      await step("migration", () => migrate("import"));
      await step("hook install", () => memoryRepo.service("reinstallHooks"));
      await step("reindex", () => memoryRepo.service("freshAll"));
      await step("dreaming automations", async () => {
        const { ensureDreamingAutomations } = await import("./dreaming");
        await ensureDreamingAutomations();
      });
    } else {
      await step("hook install", () => memoryRepo.service("reinstallHooks"));
      await step("mirror", () => migrate("mirror"));
    }
  })();

  const every = (ms: number, name: string, fn: () => Promise<unknown>) => {
    const timer = setInterval(() => void step(name, fn), ms);
    timer.unref?.();
    timers.push(timer);
  };
  every(15 * 60_000, "remote sync", () => memoryRepo.service("syncAllRemotes"));
  if (mode === "repo") {
    every(60 * 60_000, "dreaming automations", async () => {
      const { ensureDreamingAutomations } = await import("./dreaming");
      await ensureDreamingAutomations();
    });
  } else {
    every(10 * 60_000, "mirror", () => migrate("mirror"));
  }
}

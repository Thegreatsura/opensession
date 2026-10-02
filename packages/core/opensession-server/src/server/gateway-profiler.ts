/**
 * On-demand CPU profile of the gateway thread.
 *
 * /api/health reports event-loop lag (system-stats.ts) but not what caused
 * it, and a stripped Bun binary leaves `perf` with bare addresses. JSC's
 * sampling profiler records every JavaScript stack on this thread while it
 * runs, including work unrelated to the profiled callback, so a timed window
 * attributes the stalls that requests queue behind.
 *
 * `kill -USR1 <gateway pid>` samples for PROFILE_WINDOW_MS and writes a text
 * report under the state directory. Only busy samples are recorded, so a run
 * of samples without a gap is one stretch where the loop could not serve
 * anything; the report lists the longest of those with their hottest frames.
 * Registered from boot via startGatewayProfilerSignal, never at import.
 */

import { mkdir, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { statePath } from "./paths";

const PROFILE_WINDOW_MS = 30_000;
const SAMPLE_INTERVAL_US = 1_000;
/** Samples further apart than this belong to different busy stretches. */
const STALL_GAP_MS = 10;
const STALL_REPORT_MIN_MS = 50;
const TOP_FRAMES = 40;
const TOP_STALLS = 25;

export interface ProfileFrame {
  name: string;
  sourceURL?: string;
  line?: number;
}

export interface ProfileTrace {
  /** Seconds, monotonic. */
  timestamp: number;
  /** Leaf first. */
  frames: ProfileFrame[];
}

const profilerGlobal = globalThis as typeof globalThis & {
  __osGatewayProfiler?: { registered: boolean; running: boolean };
};

function frameLabel(frame: ProfileFrame): string {
  const name = frame.name || "(anonymous)";
  if (!frame.sourceURL) return `${name} [native]`;
  const file = frame.sourceURL.replace(/^.*\/packages\//, "packages/");
  return `${name} ${file}:${frame.line ?? "?"}`;
}

function top(counts: Map<string, number>, limit: number): [string, number][] {
  return [...counts].sort((a, b) => b[1] - a[1]).slice(0, limit);
}

/** Pure: turn sampled stacks into the plain-text report. Exported for tests. */
export function summarizeGatewayProfile(
  traces: readonly ProfileTrace[],
  windowMs: number,
): string {
  const self = new Map<string, number>();
  const inclusive = new Map<string, number>();
  const stalls: { startMs: number; ms: number; samples: ProfileTrace[] }[] =
    [];
  let current: (typeof stalls)[number] | undefined;
  let previousMs = -Infinity;
  for (const trace of traces) {
    const atMs = trace.timestamp * 1000;
    if (!current || atMs - previousMs > STALL_GAP_MS) {
      current = { startMs: atMs, ms: 0, samples: [] };
      stalls.push(current);
    }
    current.samples.push(trace);
    current.ms = atMs - current.startMs;
    previousMs = atMs;

    const leaf = trace.frames[0];
    if (leaf) {
      const label = frameLabel(leaf);
      self.set(label, (self.get(label) ?? 0) + 1);
    }
    for (const label of new Set(trace.frames.map(frameLabel)))
      inclusive.set(label, (inclusive.get(label) ?? 0) + 1);
  }

  const total = traces.length;
  const pct = (n: number) => `${((100 * n) / Math.max(1, total)).toFixed(1)}%`;
  const lines = [
    `Gateway CPU profile: ${(windowMs / 1000).toFixed(0)} s window, ${total} busy samples (~${SAMPLE_INTERVAL_US / 1000} ms each).`,
    "",
    `Longest busy stretches (≥ ${STALL_REPORT_MIN_MS} ms):`,
  ];
  const firstMs = traces[0] ? traces[0].timestamp * 1000 : 0;
  const longest = stalls
    .filter((stall) => stall.ms >= STALL_REPORT_MIN_MS)
    .sort((a, b) => b.ms - a.ms)
    .slice(0, TOP_STALLS);
  if (longest.length === 0) lines.push("  none");
  for (const stall of longest) {
    const frames = new Map<string, number>();
    for (const sample of stall.samples)
      for (const label of new Set(
        sample.frames
          .filter((frame) => frame.sourceURL?.includes("/packages/"))
          .map(frameLabel),
      ))
        frames.set(label, (frames.get(label) ?? 0) + 1);
    const leaves = new Map<string, number>();
    for (const sample of stall.samples) {
      const leaf = sample.frames[0];
      if (leaf)
        leaves.set(frameLabel(leaf), (leaves.get(frameLabel(leaf)) ?? 0) + 1);
    }
    lines.push(
      `  ${stall.ms.toFixed(0)} ms at +${((stall.startMs - firstMs) / 1000).toFixed(1)} s (${stall.samples.length} samples)`,
    );
    for (const [label, count] of top(frames, 8))
      lines.push(`      ${count}\t${label}`);
    for (const [label, count] of top(leaves, 3))
      lines.push(`      leaf ${count}\t${label}`);
  }
  lines.push("", "Self time (leaf frame):");
  for (const [label, count] of top(self, TOP_FRAMES))
    lines.push(`  ${pct(count)}\t${count}\t${label}`);
  lines.push("", "Inclusive time (frame anywhere on the stack):");
  for (const [label, count] of top(inclusive, TOP_FRAMES))
    lines.push(`  ${pct(count)}\t${count}\t${label}`);
  return `${lines.join("\n")}\n`;
}

async function captureGatewayProfile(): Promise<string> {
  const { profile } = await import("bun:jsc");
  const startedAt = new Date();
  const result = (await profile(
    () => new Promise((resolve) => setTimeout(resolve, PROFILE_WINDOW_MS)),
    SAMPLE_INTERVAL_US,
  )) as unknown as { stackTraces?: { traces?: ProfileTrace[] } };
  const report = summarizeGatewayProfile(
    result.stackTraces?.traces ?? [],
    PROFILE_WINDOW_MS,
  );
  const path = statePath(
    `diagnostics/gateway-profile-${startedAt.toISOString().replace(/[:.]/g, "-")}.txt`,
  );
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, report, { mode: 0o600 });
  return path;
}

/** Idempotent; called once from opensession.ts boot. */
export function startGatewayProfilerSignal(): void {
  const state = (profilerGlobal.__osGatewayProfiler ??= {
    registered: false,
    running: false,
  });
  if (state.registered) return;
  state.registered = true;
  process.on("SIGUSR1", () => {
    if (state.running) return;
    state.running = true;
    console.log(
      `[profiler] sampling the gateway thread for ${PROFILE_WINDOW_MS / 1000} s`,
    );
    captureGatewayProfile()
      .then((path) => console.log(`[profiler] wrote ${path}`))
      .catch((error) => console.warn("[profiler] profile failed:", error))
      .finally(() => {
        state.running = false;
      });
  });
}

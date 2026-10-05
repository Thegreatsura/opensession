/**
 * Offline operator job: fill the conversation search index from every
 * session actor database.
 *
 * The running service only indexes sessions as their turns end, and must
 * never walk every actor database itself. Run this once after upgrading, or
 * after deleting the search database, to cover existing history. It is safe
 * to run while the service is up: actor files are opened read-only, each
 * session is applied in short cursor-checked transactions, and a session the
 * live indexer already advanced is left to it. Rerunning skips sessions that
 * are already current, so an interrupted run resumes where it stopped.
 *
 *   nice -n 19 bun scripts/backfill-transcript-index.ts [--limit N]
 */

import { readdirSync } from "node:fs";
import { join } from "node:path";
import {
  stateDir,
  sessionsDir,
} from "../packages/core/opensession-server/src/server/paths";
import { SessionSearchStore } from "../packages/core/opensession-server/src/server/session-search-store";
import { backfillActorDatabase } from "../packages/core/opensession-server/src/server/transcript-index-backfill";

const limitFlag = process.argv.indexOf("--limit");
const limit =
  limitFlag >= 0
    ? Number(process.argv[limitFlag + 1])
    : Number.POSITIVE_INFINITY;

const root = join(sessionsDir(), "session-kernel-sessions");
const files: string[] = [];
for (const shard of readdirSync(root, { withFileTypes: true })) {
  if (!shard.isDirectory()) continue;
  for (const file of readdirSync(join(root, shard.name)))
    if (file.endsWith(".sqlite")) files.push(join(root, shard.name, file));
}

const path = process.env.OPENSESSION_SEARCH_DB || stateDir("search.db");
const store = new SessionSearchStore(path);
const index = { apply: store.applyTranscript.bind(store) };
const cursors = store.transcriptCursors();

const startedAt = Date.now();
const totals = { files: 0, sessions: 0, skipped: 0, rows: 0, failed: 0 };
for (const file of files.slice(0, limit)) {
  totals.files++;
  try {
    const outcome = backfillActorDatabase(file, index, cursors);
    totals.sessions += outcome.sessions;
    totals.skipped += outcome.skipped;
    totals.rows += outcome.rows;
  } catch (error) {
    totals.failed++;
    console.warn(
      `${file}: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
  if (totals.files % 500 === 0) {
    console.log(
      `${totals.files}/${files.length} files, ${totals.sessions} indexed, ${totals.skipped} current, ${totals.rows} rows, ${Math.round((Date.now() - startedAt) / 1000)}s`,
    );
    // Let other processes take the search database's write lock.
    await Bun.sleep(0);
  }
}
console.log(
  `Done: ${totals.files} files, ${totals.sessions} sessions indexed, ${totals.skipped} already current, ${totals.rows} rows, ${totals.failed} failed, in ${Math.round((Date.now() - startedAt) / 1000)}s`,
);
console.log(store.transcriptStats());
store.close();

/**
 * Offline backfill of the conversation index from one session actor
 * database. The live indexer only sees sessions whose turns end after it
 * shipped; this fills in everything before. It is driven by the operator
 * script scripts/backfill-transcript-index.ts, never by the running service.
 *
 * Reads the actor file read-only and applies the same cursor-checked batches
 * as the live indexer, so the two can run at once: whichever writes second
 * either continues from the other's cursor or skips.
 */

import { Database } from "bun:sqlite";
import {
  transcriptIndexRows,
  type TranscriptIndexBatch,
  type TranscriptIndexCursor,
} from "./transcript-text-index";
import type { TranscriptEntry } from "./types";

const PAGE = 2_000;

export interface BackfillOutcome {
  sessions: number;
  skipped: number;
  rows: number;
}

function columns(db: Database, table: string): Set<string> {
  return new Set(
    (
      db
        .query(`SELECT name FROM pragma_table_info('${table}')`)
        .all() as Array<{
        name: string;
      }>
    ).map((column) => column.name),
  );
}

/** Index every transcript one actor database holds that the index lacks. */
export function backfillActorDatabase(
  path: string,
  index: { apply(batch: TranscriptIndexBatch): boolean },
  cursors: ReadonlyMap<string, TranscriptIndexCursor>,
): BackfillOutcome {
  const outcome: BackfillOutcome = { sessions: 0, skipped: 0, rows: 0 };
  const db = new Database(path, { readonly: true });
  try {
    const sessionColumns = columns(db, "transcript_sessions");
    if (!columns(db, "transcript_events").has("change_seq")) return outcome;
    if (
      !sessionColumns.has("next_change_seq") ||
      !sessionColumns.has("reset_change_seq")
    )
      return outcome;
    const sessions = db
      .query(
        `SELECT session_id, next_change_seq, reset_change_seq, last_ts
         FROM transcript_sessions`,
      )
      .all() as Array<{
      session_id: string;
      next_change_seq: number;
      reset_change_seq: number;
      last_ts: number | null;
    }>;
    for (const session of sessions) {
      const epoch = session.reset_change_seq;
      const last = session.next_change_seq - 1;
      const stored = cursors.get(session.session_id);
      if (stored?.epoch === epoch && stored.changeSeq === last) {
        outcome.skipped++;
        continue;
      }
      let cursor =
        stored?.epoch === epoch && stored.changeSeq < last
          ? stored.changeSeq
          : 0;
      outcome.sessions++;
      while (true) {
        const page = db
          .query(
            `SELECT seq, change_seq, data FROM transcript_events
             WHERE session_id = ? AND change_seq > ?
             ORDER BY change_seq ASC LIMIT ?`,
          )
          .all(session.session_id, cursor, PAGE) as Array<{
          seq: number;
          change_seq: number;
          data: string;
        }>;
        const entries: Array<TranscriptEntry & { seq: number }> = [];
        for (const row of page) {
          try {
            entries.push({
              ...(JSON.parse(row.data) as TranscriptEntry),
              seq: row.seq,
            });
          } catch {}
        }
        const through = page.at(-1)?.change_seq ?? cursor;
        const rows = transcriptIndexRows(entries);
        const applied = index.apply({
          sessionId: session.session_id,
          epoch,
          fromChangeSeq: cursor,
          // The last page closes on the transcript's own high-water mark, so
          // a later backfill recognizes the session as current.
          throughChangeSeq:
            page.length < PAGE ? Math.max(through, last) : through,
          activityTs: session.last_ts ?? 0,
          rows,
        });
        // The live indexer moved first; it owns this session from here.
        if (!applied) break;
        outcome.rows += rows.filter((row) => row.text).length;
        cursor = through;
        if (page.length < PAGE) break;
      }
    }
  } finally {
    db.close();
  }
  return outcome;
}

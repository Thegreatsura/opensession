/**
 * Full-text index of what was said in every session: the ⌘K palette's
 * "search in conversations".
 *
 * Authoritative transcripts live in one actor database per session, so a
 * search used to open those files one by one, newest first, under a time and
 * row budget, and anything past the newest few hundred sessions was never
 * searched. This index is a derived FTS5 copy of the searchable text, kept in
 * the session-history search database and owned by its worker thread.
 *
 * Freshness is pushed per session: the history timer that fires when a turn
 * ends reads that one session's changes since its cursor and applies them
 * here. Existing history arrives through an explicit offline backfill
 * (scripts/backfill-transcript-index.ts). Nothing here walks sessions.
 *
 * The cursor is the transcript's reset epoch plus the last change sequence
 * applied. Every apply is a compare-and-set on that cursor, so the live
 * indexer and a concurrent backfill can never interleave stale rows.
 *
 * Only text a person would recall is indexed: their messages, replies,
 * summaries and short tool inputs. Tool output and injected context are
 * most of every transcript's bytes and would drown the matches.
 *
 * Dependency-light on purpose: importable from the worker, tests and the
 * offline backfill without pulling in the server graph.
 */

import type { Database } from "bun:sqlite";
import { isContextInjection } from "@tellahq/opensession-protocol/notices";
import { textMatchSnippet } from "./transcript-search";
import type { TranscriptEntry } from "./types";

/** Longest message text indexed per entry. */
const MESSAGE_CHARS = 4_000;
/** Longest tool input indexed per tool call. */
const TOOL_INPUT_CHARS = 300;
/** Candidate rows ranked per search, before folding into sessions. */
const CANDIDATE_ROWS = 4_000;
/**
 * Matching rows past which a query is too common to rank. bm25 scores every
 * match before ordering, which for a word like "the" is millions of rows and
 * seconds of work; such a query narrows nothing, so it takes the newest
 * matching rows instead.
 */
const RANKED_MATCH_LIMIT = 20_000;
/** Recency half-life applied to a session's best match, in days. */
const HALF_LIFE_DAYS = 45;

export interface TranscriptIndexCursor {
  /** The transcript's reset epoch (its last reset change sequence). */
  epoch: number;
  /** Last change sequence applied. */
  changeSeq: number;
}

export interface TranscriptIndexRow {
  seq: number;
  ts: number;
  /** Null drops a previously indexed row at this seq. */
  text: string | null;
}

export interface TranscriptIndexBatch {
  sessionId: string;
  epoch: number;
  /** The cursor this batch continues from; 0 starts the session over. */
  fromChangeSeq: number;
  throughChangeSeq: number;
  /** The session's latest activity, for recency ranking. */
  activityTs: number;
  rows: TranscriptIndexRow[];
}

export interface TranscriptIndexMatch {
  id: string;
  snippet: string;
}

function clip(text: string, length: number): string {
  return text.length > length ? text.slice(0, length) : text;
}

/** The text of one transcript entry worth searching, or null. */
export function searchableEntryText(entry: TranscriptEntry): string | null {
  if (isContextInjection(entry)) return null;
  if (
    entry.type === "user" ||
    entry.type === "assistant" ||
    entry.type === "system"
  ) {
    const text = (entry.content || "").trim();
    return text ? clip(text, MESSAGE_CHARS) : null;
  }
  if (entry.type === "tool_use") {
    let input = "";
    try {
      input = entry.toolInput ? (JSON.stringify(entry.toolInput) ?? "") : "";
    } catch {}
    const text = [entry.toolName, entry.content, clip(input, TOOL_INPUT_CHARS)]
      .filter(Boolean)
      .join(" ")
      .trim();
    return text || null;
  }
  return null;
}

/** Index rows for transcript entries, in the order given. */
export function transcriptIndexRows(
  entries: ReadonlyArray<TranscriptEntry & { seq?: number }>,
): TranscriptIndexRow[] {
  const rows: TranscriptIndexRow[] = [];
  for (const entry of entries) {
    if (typeof entry.seq !== "number") continue;
    const ts = Date.parse(entry.timestamp || "");
    rows.push({
      seq: entry.seq,
      ts: Number.isNaN(ts) ? 0 : ts,
      text: searchableEntryText(entry),
    });
  }
  return rows;
}

const WORD = /[\p{L}\p{N}]+/gu;

/**
 * FTS5 MATCH expression for a palette query. Each whitespace term must
 * appear; a term written with punctuation inside ("pi-durable") is a phrase
 * of adjacent words, matching "Pi Durable" and "pi_durable" alike. The last
 * term matches as a prefix once it is long enough, since the palette searches
 * while the person is still typing. Words are always quoted, so no query
 * text reaches FTS5's own syntax.
 */
export function transcriptMatchQuery(query: string): string {
  const terms = query
    .trim()
    .split(/\s+/)
    .map((term) => term.toLowerCase().match(WORD) ?? [])
    .filter((words) => words.length > 0)
    .slice(0, 12);
  return terms
    .map((words, i) => {
      const phrase = `"${words.join(" ")}"`;
      const last = i === terms.length - 1;
      return last && words[words.length - 1]!.length >= 3
        ? `${phrase}*`
        : phrase;
    })
    .join(" AND ");
}

/** Table names are fixed; callers share the history store's handle. */
export function createTranscriptIndexSchema(db: Database): void {
  db.exec(`
    CREATE TABLE IF NOT EXISTS transcript_index_rows (
      id INTEGER PRIMARY KEY,
      session_id TEXT NOT NULL,
      seq INTEGER NOT NULL,
      UNIQUE (session_id, seq)
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS transcript_index_text USING fts5(
      text,
      tokenize = 'unicode61 remove_diacritics 2',
      prefix = '3'
    );
    CREATE TABLE IF NOT EXISTS transcript_index_sessions (
      session_id TEXT PRIMARY KEY,
      epoch INTEGER NOT NULL,
      change_seq INTEGER NOT NULL,
      activity_ts INTEGER NOT NULL
    );
  `);
}

export class TranscriptTextIndex {
  private readonly applyTx: (batch: TranscriptIndexBatch) => boolean;
  private readonly removeTx: (sessionId: string) => void;

  constructor(private readonly db: Database) {
    createTranscriptIndexSchema(db);
    this.applyTx = db.transaction((batch: TranscriptIndexBatch) =>
      this.applyInTx(batch),
    ) as unknown as (batch: TranscriptIndexBatch) => boolean;
    this.removeTx = db.transaction((sessionId: string) =>
      this.removeInTx(sessionId),
    ) as unknown as (sessionId: string) => void;
  }

  cursor(sessionId: string): TranscriptIndexCursor | null {
    const row = this.db
      .query(
        `SELECT epoch, change_seq FROM transcript_index_sessions
         WHERE session_id = ?`,
      )
      .get(sessionId) as { epoch: number; change_seq: number } | null;
    return row ? { epoch: row.epoch, changeSeq: row.change_seq } : null;
  }

  /** Every cursor, for the offline backfill's skip check. */
  cursors(): Map<string, TranscriptIndexCursor> {
    const rows = this.db
      .query(
        "SELECT session_id, epoch, change_seq FROM transcript_index_sessions",
      )
      .all() as Array<{
      session_id: string;
      epoch: number;
      change_seq: number;
    }>;
    return new Map(
      rows.map((row) => [
        row.session_id,
        { epoch: row.epoch, changeSeq: row.change_seq },
      ]),
    );
  }

  /**
   * Apply one batch if it continues the stored cursor. False means another
   * writer moved the cursor first; re-read it and continue from there.
   */
  apply(batch: TranscriptIndexBatch): boolean {
    return this.applyTx(batch);
  }

  remove(sessionId: string): void {
    this.removeTx(sessionId);
  }

  private applyInTx(batch: TranscriptIndexBatch): boolean {
    if (batch.fromChangeSeq === 0) {
      // A batch from the start replaces whatever the session held: a new
      // epoch, or a transcript recreated under the same id.
      this.removeInTx(batch.sessionId);
    } else {
      const current = this.cursor(batch.sessionId);
      if (
        current?.epoch !== batch.epoch ||
        current.changeSeq !== batch.fromChangeSeq
      )
        return false;
    }
    const existing = this.db.query(
      "SELECT id FROM transcript_index_rows WHERE session_id = ? AND seq = ?",
    );
    for (const row of batch.rows) {
      const found = existing.get(batch.sessionId, row.seq) as {
        id: number;
      } | null;
      if (found) {
        this.db.run("DELETE FROM transcript_index_text WHERE rowid = ?", [
          found.id,
        ]);
        this.db.run("DELETE FROM transcript_index_rows WHERE id = ?", [
          found.id,
        ]);
      }
      if (!row.text) continue;
      const inserted = this.db.run(
        "INSERT INTO transcript_index_rows (session_id, seq) VALUES (?, ?)",
        [batch.sessionId, row.seq],
      );
      this.db.run(
        "INSERT INTO transcript_index_text (rowid, text) VALUES (?, ?)",
        [Number(inserted.lastInsertRowid), row.text],
      );
    }
    this.db.run(
      `INSERT INTO transcript_index_sessions
         (session_id, epoch, change_seq, activity_ts)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(session_id) DO UPDATE SET
         epoch = excluded.epoch,
         change_seq = excluded.change_seq,
         activity_ts = max(activity_ts, excluded.activity_ts)`,
      [batch.sessionId, batch.epoch, batch.throughChangeSeq, batch.activityTs],
    );
    return true;
  }

  private removeInTx(sessionId: string): void {
    this.db.run(
      `DELETE FROM transcript_index_text WHERE rowid IN
         (SELECT id FROM transcript_index_rows WHERE session_id = ?)`,
      [sessionId],
    );
    this.db.run("DELETE FROM transcript_index_rows WHERE session_id = ?", [
      sessionId,
    ]);
    this.db.run("DELETE FROM transcript_index_sessions WHERE session_id = ?", [
      sessionId,
    ]);
  }

  /**
   * Sessions whose conversation matches `query`, best first: each session
   * scores its best-ranked row, decayed by how long ago it was active, so a
   * strong old match still beats a passing mention while recent work wins
   * ties. One snippet per session, around the match.
   */
  search(
    query: string,
    opts: { limit?: number; now?: number; rankedMatchLimit?: number } = {},
  ): TranscriptIndexMatch[] {
    const match = transcriptMatchQuery(query);
    const rankedLimit = opts.rankedMatchLimit ?? RANKED_MATCH_LIMIT;
    if (!match) return [];
    const limit = Math.min(Math.max(opts.limit ?? 50, 1), 200);
    const now = opts.now ?? Date.now();
    let rows: Array<{
      session_id: string;
      text: string;
      rank: number;
      activity_ts: number | null;
    }>;
    try {
      const { n } = this.db
        .query(
          `SELECT count(*) AS n FROM (
             SELECT rowid FROM transcript_index_text
             WHERE transcript_index_text MATCH ? LIMIT ?
           )`,
        )
        .get(match, rankedLimit + 1) as { n: number };
      const order = n > rankedLimit ? "rowid DESC" : "rank";
      rows = this.db
        .query(
          `SELECT r.session_id, t.text, t.rank, s.activity_ts
           FROM (
             SELECT rowid, text, rank FROM transcript_index_text
             WHERE transcript_index_text MATCH ?
             ORDER BY ${order} LIMIT ?
           ) t
           JOIN transcript_index_rows r ON r.id = t.rowid
           LEFT JOIN transcript_index_sessions s ON s.session_id = r.session_id`,
        )
        .all(match, CANDIDATE_ROWS) as typeof rows;
    } catch {
      // A query FTS5 still rejects finds nothing; it never fails the route.
      return [];
    }
    const best = new Map<string, { score: number; text: string }>();
    for (const row of rows) {
      const relevance = Math.max(-row.rank, 0.001);
      const ageDays = Math.max(now - Number(row.activity_ts ?? 0), 0) / 86.4e6;
      const score = relevance * Math.pow(0.5, ageDays / HALF_LIFE_DAYS);
      const seen = best.get(row.session_id);
      if (!seen || score > seen.score)
        best.set(row.session_id, { score, text: row.text });
    }
    return [...best.entries()]
      .sort((a, b) => b[1].score - a[1].score)
      .slice(0, limit)
      .map(([id, { text }]) => ({
        id,
        snippet: textMatchSnippet(text, query),
      }));
  }

  /** Sessions and rows held, for status and tests. */
  stats(): { sessions: number; rows: number } {
    const sessions = this.db
      .query("SELECT count(*) AS n FROM transcript_index_sessions")
      .get() as { n: number };
    const rows = this.db
      .query("SELECT count(*) AS n FROM transcript_index_rows")
      .get() as { n: number };
    return { sessions: sessions.n, rows: rows.n };
  }
}

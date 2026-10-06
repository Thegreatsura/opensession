/**
 * Typo-tolerant matching for the small search surfaces: the composer's "@"
 * palette, the command menu, and the sidebar filter. Shared by the server and
 * the web client so a query ranks the same wherever it is typed.
 *
 * Scores are 0 (no match) to 100 (exact). Every whitespace-separated term
 * must match somewhere in the text: as a substring, as a word within a small
 * edit distance (transpositions count as one edit), or as a subsequence of a
 * single word. Accents and case are ignored.
 */

const WORD_SPLIT = /[^a-z0-9]+/;

function normalize(value: string): string {
  return value
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "");
}

/** Edits a term may absorb: none for short ones, so "cat" never finds "cut". */
function editBudget(term: string): number {
  if (term.length < 4) return 0;
  if (term.length < 8) return 1;
  return 2;
}

/** Optimal string alignment distance, capped at `max + 1`. */
function editDistance(a: string, b: string, max: number): number {
  if (Math.abs(a.length - b.length) > max) return max + 1;
  let prev2: number[] = [];
  let prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const row = [i];
    let rowMin = i;
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      let d = Math.min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + cost);
      if (
        i > 1 &&
        j > 1 &&
        a[i - 1] === b[j - 2] &&
        a[i - 2] === b[j - 1] &&
        prev2[j - 2] + 1 < d
      ) {
        d = prev2[j - 2] + 1;
      }
      row.push(d);
      if (d < rowMin) rowMin = d;
    }
    if (rowMin > max) return max + 1;
    prev2 = prev;
    prev = row;
  }
  return prev[b.length];
}

function isSubsequence(term: string, word: string): boolean {
  let i = 0;
  for (const ch of word) {
    if (ch === term[i]) i++;
    if (i === term.length) return true;
  }
  return i === term.length;
}

/** Text normalized and split once, so a list scored on every keystroke pays
 *  for accent folding and word splitting when it changes, not per query. */
export interface FuzzyText {
  text: string;
  /** Distinct words, in first-seen order. */
  words: string[];
}

export function prepareFuzzyText(value: string): FuzzyText {
  const text = normalize(value);
  return {
    text,
    words: Array.from(new Set(text.split(WORD_SPLIT).filter(Boolean))),
  };
}

/** One query term. A term written with punctuation inside ("pi-durable",
 *  "audit/billing") is a phrase: its parts must appear as consecutive words,
 *  joined by anything or nothing, so it finds "Pi Durable" without letting
 *  "s-desk" match any title that merely has an "s" and a "desk" in it. */
interface QueryTerm {
  text: string;
  phrase: RegExp | null;
}

/** A query normalized once. It also remembers how each term fares against
 *  each word it has met: the same words recur across a long list, so the
 *  typo and abbreviation checks run once per distinct word, not per item. */
export interface FuzzyQuery {
  q: string;
  terms: QueryTerm[];
  words: Map<string, number>[];
}

function queryTerm(raw: string): QueryTerm | null {
  const parts = raw.split(WORD_SPLIT).filter(Boolean);
  if (parts.length === 0) return null;
  // Edge punctuation, like a "#" or the hyphen just typed, is not a phrase.
  if (parts.length === 1) return { text: parts[0], phrase: null };
  return {
    text: raw,
    phrase: new RegExp(`(?:^|[^a-z0-9])${parts.join("[^a-z0-9]*")}`),
  };
}

export function prepareFuzzyQuery(query: string): FuzzyQuery {
  const q = normalize(query).trim();
  const terms = q
    .split(/\s+/)
    .map(queryTerm)
    .filter((term): term is QueryTerm => term !== null);
  return { q, terms, words: terms.map(() => new Map()) };
}

/** Edit distance (capped at budget + 1) times two, plus one when the term is
 *  an abbreviation of the word. */
function wordFit(
  term: string,
  word: string,
  budget: number,
  cache: Map<string, number>,
): number {
  let fit = cache.get(word);
  if (fit === undefined) {
    const d =
      budget > 0 && word.length >= term.length - budget
        ? // Compare against the whole word and its prefix of the term's
          // length, so "wrokspace" and "relase" both land on their word.
          Math.min(
            editDistance(term, word, budget),
            editDistance(term, word.slice(0, term.length), budget),
          )
        : budget + 1;
    const abbreviation = term.length >= 3 && isSubsequence(term, word);
    fit = d * 2 + (abbreviation ? 1 : 0);
    cache.set(word, fit);
  }
  return fit;
}

function termScore(
  { text: term, phrase }: QueryTerm,
  text: string,
  words: string[],
  cache: Map<string, number>,
): number {
  if (text.includes(term)) return 60;
  if (phrase) return phrase.test(text) ? 60 : 0;
  const budget = editBudget(term);
  let best = budget + 1;
  let abbreviation = false;
  for (const word of words) {
    const fit = wordFit(term, word, budget, cache);
    const d = fit >> 1;
    if (d < best) best = d;
    if (fit & 1) abbreviation = true;
    if (best === 0) break;
  }
  if (best <= budget) return 50 - best * 10;
  // "wksp" for "workspace": abbreviations skip letters but keep their order.
  return abbreviation ? 20 : 0;
}

/** `fuzzyScore` for a query and text prepared ahead of time. */
export function fuzzyScorePrepared(query: FuzzyQuery, text: FuzzyText): number {
  const { q, terms } = query;
  if (!q) return 1;
  const t = text.text;
  if (!t) return 0;
  if (t === q) return 100;
  if (t.startsWith(q)) return 90;
  if (text.words.some((word) => word.startsWith(q))) return 80;
  if (t.includes(q)) return 70;
  if (terms.length === 0) return 0;
  let total = 0;
  for (let i = 0; i < terms.length; i++) {
    const score = termScore(terms[i], t, text.words, query.words[i]);
    if (score === 0) return 0;
    total += score;
  }
  return Math.round(total / terms.length);
}

/**
 * Score `text` against `query`. 0 means no match; higher is a better match.
 * An empty query matches everything at 1.
 */
export function fuzzyScore(query: string, text: string): number {
  return fuzzyScorePrepared(prepareFuzzyQuery(query), prepareFuzzyText(text));
}

/** The best score across several prepared fields of one item. */
export function fuzzyMatchPrepared(
  query: FuzzyQuery,
  values: ReadonlyArray<FuzzyText>,
): number {
  let best = 0;
  for (const value of values) {
    const score = fuzzyScorePrepared(query, value);
    if (score > best) best = score;
    if (best === 100) break;
  }
  return best;
}

/** The best score across several fields of one item. 0 means no match. */
export function fuzzyMatch(
  query: string,
  values: ReadonlyArray<string | null | undefined>,
): number {
  return fuzzyMatchPrepared(
    prepareFuzzyQuery(query),
    values.filter((value): value is string => !!value).map(prepareFuzzyText),
  );
}

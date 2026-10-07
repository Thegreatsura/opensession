/**
 * Slack user mentions in composer text.
 *
 * Slack only notifies someone for a `<@U123>` token; a typed "@Name" is
 * plain text. The composer shows readable "@Name" while the person edits and
 * keeps a name → id map of the people they picked. The stored and sent text
 * carries the Slack tokens, so a reopened draft decodes back to names.
 */

export interface SlackMentionUser {
  id: string;
  /** What Slack shows after the "@": the display name, else the real name. */
  name: string;
  realName?: string;
  image?: string;
}

const MENTION_TOKEN = /<@([UW][A-Z0-9]{2,})(?:\|[^>]*)?>/g;

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Readable text for the textarea, plus the names it now holds. Tokens for
 *  people outside `users` stay as they are. */
export function decodeSlackMentions(
  text: string,
  users: ReadonlyArray<SlackMentionUser>,
): { text: string; mentions: Map<string, string> } {
  const byId = new Map(users.map((user) => [user.id, user]));
  const mentions = new Map<string, string>();
  const decoded = text.replace(MENTION_TOKEN, (token, id: string) => {
    const user = byId.get(id);
    if (!user) return token;
    mentions.set(user.name, id);
    return `@${user.name}`;
  });
  return { text: decoded, mentions };
}

/** Swap every "@Name" the person picked for its Slack token. A name only
 *  matches as a whole word, and longer names win over their prefixes. */
export function encodeSlackMentions(
  text: string,
  mentions: ReadonlyMap<string, string>,
): string {
  const names = [...mentions.keys()]
    .filter(Boolean)
    .sort((a, b) => b.length - a.length);
  if (!names.length) return text;
  const pattern = new RegExp(
    `(^|[^\\w@])@(${names.map(escapeRegExp).join("|")})(?![\\w])`,
    "g",
  );
  return text.replace(
    pattern,
    (_match, lead: string, name: string) => `${lead}<@${mentions.get(name)}>`,
  );
}

/** Length as the person sees it: a mention token counts as a short "@x", so
 *  the server's limit matches the textarea's. */
export function slackMessageLength(text: string): number {
  return text.replace(MENTION_TOKEN, "@x").length;
}

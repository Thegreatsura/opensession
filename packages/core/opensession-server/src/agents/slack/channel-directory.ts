/**
 * The channels a person can post to from the Slack composer.
 *
 * `integrations.slack.channelNames` is a short, operator-curated list; it is
 * the suggestion set, not the universe. The composer posts as the signed-in
 * person with their own grant, so the channels they can reach are every
 * public channel in the workspace (`conversations.list`) plus the private
 * channels they are a member of (`users.conversations`). Slack refuses a
 * user-token post to a channel the person has not joined, so posting to a
 * public channel they are not in joins it first (`joinSlackChannelIfNeeded`).
 * The list is fetched with their token, cached briefly per caller, and merged
 * after the configured channels so the curated ones stay at the top of the
 * picker.
 */
import { slackApiCall, slackApiGet } from "./slack-api";

export interface SlackChannelOption {
  id: string;
  name: string;
  /** False for a public channel the caller has not joined. Absent means a
   *  member (or unknown, for configured channels). */
  member?: boolean;
}

const DIRECTORY_TTL_MS = 5 * 60 * 1000;
/** Both list methods page at up to 1000; ten pages covers the public channels
 *  of any realistic workspace without an unbounded walk. */
const MAX_PAGES = 10;

interface DirectoryEntry {
  token: string;
  at: number;
  channels: SlackChannelOption[];
  pending?: Promise<SlackChannelOption[]>;
}

const g = globalThis as {
  __slackChannelDirectory?: Map<string, DirectoryEntry>;
};
const directory: Map<string, DirectoryEntry> = (g.__slackChannelDirectory ??=
  new Map());

export function isSlackChannelId(value: string): boolean {
  return /^[CG][A-Z0-9]{6,}$/.test(value);
}

export function normalizeSlackChannelName(value: string): string {
  return value.trim().replace(/^#/, "").toLowerCase();
}

async function pageChannels(
  method: "users.conversations" | "conversations.list",
  types: string,
  token: string,
): Promise<SlackChannelOption[] | undefined> {
  const channels: SlackChannelOption[] = [];
  let cursor = "";
  for (let page = 0; page < MAX_PAGES; page += 1) {
    const data = await slackApiGet(
      method,
      {
        types,
        exclude_archived: true,
        limit: 1000,
        cursor: cursor || undefined,
      },
      token,
    );
    if (!data?.ok) {
      // A grant issued before channels:read was requested, or a revoked
      // token: the configured list still works, so this is not an error.
      if (page === 0) return undefined;
      break;
    }
    for (const channel of data.channels || []) {
      if (typeof channel?.id !== "string" || typeof channel?.name !== "string")
        continue;
      if (!channel.name) continue;
      channels.push({
        id: channel.id,
        name: channel.name,
        ...(method === "conversations.list" && channel.is_member === false
          ? { member: false }
          : {}),
      });
    }
    cursor = data.response_metadata?.next_cursor || "";
    if (!cursor) break;
  }
  return channels;
}

async function fetchUserChannels(token: string): Promise<SlackChannelOption[]> {
  const [mine, publicChannels] = await Promise.all([
    pageChannels(
      "users.conversations",
      "public_channel,private_channel",
      token,
    ),
    pageChannels("conversations.list", "public_channel", token),
  ]);
  const byId = new Map<string, SlackChannelOption>();
  for (const channel of publicChannels || []) byId.set(channel.id, channel);
  // Membership from users.conversations wins over a stale is_member.
  for (const channel of mine || []) byId.set(channel.id, channel);
  return [...byId.values()].sort((a, b) => a.name.localeCompare(b.name));
}

/**
 * Every channel `caller` can post to, as seen by their own grant. Cached
 * for a few minutes per caller and coalesced, so a composer that mounts twice
 * (or a send right after a load) does not page Slack twice.
 */
export function slackChannelsForUser(
  caller: string,
  token: string,
): Promise<SlackChannelOption[]> {
  const entry = directory.get(caller);
  const now = Date.now();
  if (entry && entry.token === token) {
    if (entry.pending) return entry.pending;
    if (now - entry.at < DIRECTORY_TTL_MS)
      return Promise.resolve(entry.channels);
  }
  const next: DirectoryEntry = {
    token,
    at: now,
    channels: entry?.token === token ? entry.channels : [],
  };
  next.pending = fetchUserChannels(token)
    .then((channels) => {
      next.channels = channels;
      next.at = Date.now();
      return channels;
    })
    .catch(() => next.channels)
    .finally(() => {
      next.pending = undefined;
    });
  directory.set(caller, next);
  return next.pending;
}

/** The caller's directory now shows them in `channelId`. */
function markJoined(caller: string, channelId: string): void {
  const entry = directory.get(caller);
  const channel = entry?.channels.find((c) => c.id === channelId);
  if (channel) delete channel.member;
}

/**
 * Join a public channel the caller is not in yet, so a post with their token
 * lands instead of failing with `not_in_channel`. A no-op for channels they
 * are already in and for private channels. Membership comes from the caller's
 * directory, so a configured channel they never joined is covered too.
 */
export async function joinSlackChannelIfNeeded(
  channel: SlackChannelOption,
  auth: { caller: string; token: string },
): Promise<void> {
  const listed = (await slackChannelsForUser(auth.caller, auth.token)).find(
    (candidate) => candidate.id === channel.id,
  );
  if (listed?.member !== false) return;
  const joined = await slackApiCall(
    "conversations.join",
    { channel: channel.id },
    auth.token,
  ).catch(() => null);
  if (joined?.ok) {
    markJoined(auth.caller, channel.id);
    return;
  }
  if (joined?.error === "missing_scope")
    throw new Error(
      `Reconnect Slack in Settings → Account to post in channels you haven't joined, or join #${channel.name} in Slack first`,
    );
  throw new Error(`Join #${channel.name} in Slack first, then send again`);
}

export function forgetSlackChannelsForUser(caller?: string): void {
  if (caller) directory.delete(caller);
  else directory.clear();
}

/**
 * Configured channels first, in their configured order, then the rest of the
 * person's channels alphabetically. An id that appears in both keeps the
 * configured name and takes the directory's membership.
 */
export function mergeSlackChannels(
  configured: SlackChannelOption[],
  directoryChannels: SlackChannelOption[],
): SlackChannelOption[] {
  const seen = new Set(configured.map((channel) => channel.id));
  const merged = configured.map((channel) => {
    const listed = directoryChannels.find((c) => c.id === channel.id);
    return listed?.member === false ? { ...channel, member: false } : channel;
  });
  for (const channel of directoryChannels) {
    if (seen.has(channel.id)) continue;
    seen.add(channel.id);
    merged.push(channel);
  }
  return merged;
}

export function findSlackChannel(
  channels: SlackChannelOption[],
  wanted: string,
): SlackChannelOption | undefined {
  const name = normalizeSlackChannelName(wanted);
  return channels.find(
    (channel) =>
      channel.id === wanted.trim() || channel.name.toLowerCase() === name,
  );
}

/**
 * Turn what the composer sent (an id, or a `#name`) into a channel the
 * person can post to. Configured channels resolve without a grant; anything
 * else has to be in the caller's directory, or be an id `conversations.info`
 * confirms with their token.
 */
export async function resolveSlackChannel(
  wanted: unknown,
  configured: SlackChannelOption[],
  auth?: { caller: string; token: string },
): Promise<SlackChannelOption | undefined> {
  if (typeof wanted !== "string" || !wanted.trim()) return undefined;
  const fromConfig = findSlackChannel(configured, wanted);
  if (fromConfig) return fromConfig;
  if (!auth) return undefined;
  const fromDirectory = findSlackChannel(
    await slackChannelsForUser(auth.caller, auth.token),
    wanted,
  );
  if (fromDirectory) return fromDirectory;
  const id = wanted.trim();
  if (!isSlackChannelId(id)) return undefined;
  const info = await slackApiGet(
    "conversations.info",
    { channel: id },
    auth.token,
  ).catch(() => null);
  const name = info?.ok ? info.channel?.name : undefined;
  return typeof name === "string" && name ? { id, name } : undefined;
}

/**
 * The workspace's people, for "@" mentions in the Slack composer. Read with
 * the bot token (`users:read`), cached for a while and coalesced, since the
 * roster changes rarely and every composer that opens asks for it.
 */
import type { SlackMentionUser } from "../../shared/slack-mentions";
import { slackApiGet } from "./slack-api";

const DIRECTORY_TTL_MS = 15 * 60 * 1000;
/** users.list pages at up to 1000 members; cap the walk. */
const MAX_PAGES = 10;

interface DirectoryEntry {
  at: number;
  users: SlackMentionUser[];
  pending?: Promise<SlackMentionUser[]>;
}

const g = globalThis as { __slackUserDirectory?: DirectoryEntry };

export function slackMentionUserFromMember(
  member: any,
): SlackMentionUser | undefined {
  if (!member || typeof member.id !== "string") return undefined;
  if (member.deleted || member.is_bot || member.id === "USLACKBOT")
    return undefined;
  const realName =
    member.profile?.real_name || member.real_name || member.name || "";
  const name = (member.profile?.display_name || realName).trim();
  if (!name) return undefined;
  const image = member.profile?.image_48 || member.profile?.image_72;
  return {
    id: member.id,
    name,
    ...(realName && realName !== name ? { realName } : {}),
    ...(typeof image === "string" && image ? { image } : {}),
  };
}

async function fetchUsers(): Promise<SlackMentionUser[]> {
  const users: SlackMentionUser[] = [];
  let cursor = "";
  for (let page = 0; page < MAX_PAGES; page += 1) {
    const data = await slackApiGet("users.list", {
      limit: 1000,
      cursor: cursor || undefined,
    });
    if (!data?.ok) {
      if (page === 0) throw new Error(data?.error || "users.list failed");
      break;
    }
    for (const member of data.members || []) {
      const user = slackMentionUserFromMember(member);
      if (user) users.push(user);
    }
    cursor = data.response_metadata?.next_cursor || "";
    if (!cursor) break;
  }
  return users.sort((a, b) => a.name.localeCompare(b.name));
}

export function slackMentionUsers(): Promise<SlackMentionUser[]> {
  const entry = g.__slackUserDirectory;
  if (entry?.pending) return entry.pending;
  if (entry && Date.now() - entry.at < DIRECTORY_TTL_MS)
    return Promise.resolve(entry.users);
  const next: DirectoryEntry = { at: 0, users: entry?.users || [] };
  next.pending = fetchUsers()
    .then((users) => {
      next.users = users;
      next.at = Date.now();
      return users;
    })
    // Keep serving the last roster; a failed first read is an empty one.
    .catch(() => next.users)
    .finally(() => {
      next.pending = undefined;
    });
  g.__slackUserDirectory = next;
  return next.pending;
}

/** The isolated demo instance has no Slack, so a short roster stands in. */
export function demoSlackMentionUsers(): SlackMentionUser[] {
  return ["Alex Kim", "Jamie Rivera", "Morgan Lee", "Sam Patel"].map(
    (name, index) => ({
      id: `UDEMO${String(index + 1).padStart(4, "0")}`,
      name,
    }),
  );
}

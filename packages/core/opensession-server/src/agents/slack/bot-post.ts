import {
  postSlackFiles,
  sendSlackMessage,
  slackApiCall,
  slackPermalink,
  slackUploadTs,
  type SlackUploadOptions,
} from "./slack-api";
import type { SlackChannelOption } from "./channel-directory";

const NOT_IN_CHANNEL = /not_in_channel|channel_not_found/;

async function post(
  channel: SlackChannelOption,
  message: string,
  images: string[],
  upload: SlackUploadOptions,
): Promise<string | undefined> {
  if (images.length > 0) {
    const completed = await postSlackFiles(
      channel.id,
      images,
      message,
      upload,
    ).catch((error) => {
      throw error?.message === "SLACK_RECONNECT_REQUIRED"
        ? new Error("The Slack bot needs the files:write scope to post images")
        : error;
    });
    return slackUploadTs(completed, channel.id);
  }
  const posted = await sendSlackMessage(channel.id, message);
  if (!posted?.ok)
    throw new Error(
      `Slack message failed: ${posted?.error || "invalid response"}`,
    );
  return typeof posted.ts === "string" ? posted.ts : undefined;
}

/**
 * Post a reviewed draft as the Slack bot, never as the person who pressed
 * Send. The bot joins a public channel it isn't in yet; a private channel
 * needs it invited first.
 */
export async function postAsSlackBot(
  channel: SlackChannelOption,
  message: string,
  images: string[],
  upload: SlackUploadOptions,
): Promise<{ ts?: string; permalink?: string }> {
  if (!process.env.SLACK_BOT_TOKEN)
    throw new Error("Slack isn't set up on this server yet");
  let ts: string | undefined;
  try {
    ts = await post(channel, message, images, upload);
  } catch (error: any) {
    if (!NOT_IN_CHANNEL.test(error?.message || "")) throw error;
    const joined = await slackApiCall("conversations.join", {
      channel: channel.id,
    }).catch(() => null);
    if (!joined?.ok)
      throw new Error(
        `Invite the bot to #${channel.name} in Slack, then send again`,
      );
    ts = await post(channel, message, images, upload);
  }
  const permalink = ts ? await slackPermalink(channel.id, ts) : undefined;
  return { ts, permalink };
}

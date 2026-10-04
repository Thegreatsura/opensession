import { useState } from "react";
import { parseYouShouldKnowTitle } from "@tellahq/opensession-protocol/notices";
import { addYouShouldKnowTopic, saveYouShouldKnow } from "../lib/api";
import { errorMessage } from "../lib/error-message";
import { msgBody, msgSystemRow } from "../lib/msg-classes";
import type { TranscriptEntry } from "../lib/types";
import {
  requestYouShouldKnowChat,
  youShouldKnowChatText,
} from "../lib/you-should-know";
import { Button } from "../ui/button";
import { cn } from "../ui/cn";
import { toast } from "../ui/toast";
import { ClampedBody } from "./MessageBubble";
import { getCurrentUser } from "./UserPicker";

/**
 * A You should know note (server/you-should-know.ts) with the plugin's
 * answers: Learn more opens the explanation, Knew this already tells later
 * checks to skip the topic, Chat in main session quotes the note into the
 * composer, and Turn off (pressed twice, as in the plugin) switches the side
 * agent off for this person. The note itself is durable; what a button did is
 * remembered on the server, not on the card.
 */
export function YouShouldKnowNotice({
  entry,
  sessionId,
}: {
  entry: TranscriptEntry;
  sessionId?: string;
}) {
  const notice = entry.notice!;
  const { tag, line } = parseYouShouldKnowTitle(notice.title);
  const explanation = notice.body ? entry.content : "";
  const [open, setOpen] = useState(false);
  const [known, setKnown] = useState(false);
  const [offArmed, setOffArmed] = useState(false);
  const [off, setOff] = useState(false);

  async function knew() {
    setKnown(true);
    try {
      await addYouShouldKnowTopic(getCurrentUser(), line);
    } catch (error) {
      setKnown(false);
      toast(errorMessage(error, "Failed to save"), { variant: "error" });
    }
  }

  async function turnOff() {
    if (!offArmed) {
      setOffArmed(true);
      return;
    }
    try {
      await saveYouShouldKnow(getCurrentUser(), false);
      setOff(true);
      toast("You should know is off. Turn it back on in Settings.");
    } catch (error) {
      setOffArmed(false);
      toast(errorMessage(error, "Failed to turn off You should know"), {
        variant: "error",
      });
    }
  }

  return (
    <div className={msgSystemRow} data-eid={entry.id}>
      <div
        className="mx-auto w-full max-w-[560px] rounded-lg bg-panel px-4 py-3 text-left"
        role="group"
        aria-label={tag}
      >
        <div className="text-meta font-medium text-faint">{tag}</div>
        <p className="mt-0.5 text-sm text-fg">{line}</p>
        {open && explanation && (
          <ClampedBody
            className={cn(msgBody, "markdown mt-2")}
            content={explanation}
            entry={entry}
            sessionId={sessionId}
          />
        )}
        <div className="mt-2.5 flex flex-wrap items-center gap-1.5">
          {explanation && (
            <Button
              size="sm"
              variant="soft"
              aria-expanded={open}
              onClick={() => setOpen((value) => !value)}
            >
              {open ? "Hide" : "Learn more"}
            </Button>
          )}
          <Button size="sm" variant="ghost" disabled={known} onClick={knew}>
            {known ? "Won't suggest again" : "Knew this already"}
          </Button>
          {sessionId && (
            <Button
              size="sm"
              variant="ghost"
              onClick={() =>
                requestYouShouldKnowChat(
                  sessionId,
                  youShouldKnowChatText(tag, line, explanation),
                )
              }
            >
              Chat in main session
            </Button>
          )}
          {!off && (
            <Button
              size="sm"
              variant="ghost"
              className="phone:ms-0 ms-auto text-faint"
              onClick={turnOff}
              onBlur={() => setOffArmed(false)}
            >
              {offArmed ? "Press again to turn off" : "Turn off"}
            </Button>
          )}
        </div>
      </div>
    </div>
  );
}

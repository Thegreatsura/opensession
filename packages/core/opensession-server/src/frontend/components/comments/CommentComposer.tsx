import React, { useEffect, useRef, useState } from "react";
import type { FileMention } from "../../lib/api";
import { AGENT_NAME } from "../../lib/brand";
import { noAutofill } from "../../lib/composer-autofill";
import { isTouchPrimary } from "../../lib/platform";
import { Button } from "../../ui/button";
import { cn } from "../../ui/cn";
import { useFileMentions } from "../useFileMentions";

/** The agent as an "@" row: tagging it asks for an answer in the thread. */
const agentRow: FileMention = {
  display: AGENT_NAME,
  insert: "agent",
  kind: "person",
  sub: "Answers in this thread",
};

function agentRows(query: string): Promise<FileMention[]> {
  const q = query.trim().toLowerCase();
  const matches =
    !q || "agent".startsWith(q) || AGENT_NAME.toLowerCase().startsWith(q);
  return Promise.resolve(matches ? [agentRow] : []);
}

const noFiles = () => Promise.resolve<FileMention[]>([]);

/**
 * The text box under a thread, and the one that starts a thread. "@" opens
 * the same people picker the session composer uses, with the agent first.
 * Enter sends on a desktop keyboard (Shift+Enter for a new line); a touch
 * keyboard has no Shift+Enter habit, so there the button sends.
 */
export function CommentComposer({
  placeholder,
  submitLabel,
  autoFocus,
  onSubmit,
  onCancel,
  compact,
  className,
}: {
  placeholder: string;
  submitLabel: string;
  autoFocus?: boolean;
  /** Resolve true to clear the box; false keeps the text for a retry. */
  onSubmit: (text: string) => Promise<boolean>;
  onCancel?: () => void;
  /** Collapsed to one line until focused or filled (the reply box). */
  compact?: boolean;
  className?: string;
}) {
  const [value, setValue] = useState("");
  const [busy, setBusy] = useState(false);
  const [focused, setFocused] = useState(false);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const {
    setInputWrap,
    popup: mentionPopup,
    inputProps: mentionInputProps,
    sync: syncMentions,
    handleKeyDown: handleMentionKeyDown,
    close: closeMentions,
  } = useFileMentions({
    value,
    onChange: (next) => setValue(next),
    textareaRef,
    mentionFetch: noFiles,
    paletteFetch: agentRows,
  });

  useEffect(() => {
    if (autoFocus) textareaRef.current?.focus({ preventScroll: true });
  }, [autoFocus]);

  // Grow with the text, up to the cap in the class list.
  useEffect(() => {
    const el = textareaRef.current;
    if (!el) return;
    el.style.height = "";
    el.style.height = `${el.scrollHeight}px`;
    // Scroll only once the text outgrows the cap (max-h-48).
    el.style.overflowY = el.scrollHeight > 192 ? "auto" : "hidden";
  }, [value]);

  async function submit() {
    const text = value.trim();
    if (!text || busy) return;
    setBusy(true);
    const ok = await onSubmit(text).finally(() => setBusy(false));
    if (ok) setValue("");
  }

  const expanded = !compact || focused || value.length > 0;

  return (
    <div className={cn("flex flex-col gap-2", className)}>
      <div ref={setInputWrap} className="relative">
        <textarea
          ref={textareaRef}
          value={value}
          rows={1}
          disabled={busy}
          placeholder={placeholder}
          aria-label={placeholder}
          {...noAutofill}
          {...mentionInputProps}
          onChange={(e) => setValue(e.target.value)}
          onFocus={() => setFocused(true)}
          onBlur={() => {
            setFocused(false);
            closeMentions();
          }}
          onKeyUp={syncMentions}
          onClick={syncMentions}
          onKeyDown={(e) => {
            if (handleMentionKeyDown(e)) return;
            if (e.key === "Escape" && onCancel) {
              e.preventDefault();
              e.stopPropagation();
              onCancel();
              return;
            }
            if (
              e.key === "Enter" &&
              !e.shiftKey &&
              !e.nativeEvent.isComposing &&
              (e.metaKey || e.ctrlKey || !isTouchPrimary)
            ) {
              e.preventDefault();
              void submit();
            }
          }}
          className="block max-h-48 min-h-9 w-full resize-none overflow-hidden rounded-control border border-line bg-surface px-2.5 py-2 text-body leading-snug text-fg outline-none placeholder:text-faint focus-visible:border-accent phone:min-h-11 phone:text-input-phone"
        />
        {mentionPopup}
      </div>
      {expanded && (
        <div className="flex items-center justify-end gap-2">
          {onCancel && (
            <Button
              size="sm"
              variant="ghost"
              onClick={onCancel}
              disabled={busy}
              className="phone:min-h-11"
            >
              Cancel
            </Button>
          )}
          <Button
            size="sm"
            variant="primary"
            // Keep focus in the box: a press that blurs it would collapse a
            // compact reply box before the click lands.
            onMouseDown={(e) => e.preventDefault()}
            onClick={() => void submit()}
            disabled={busy || !value.trim()}
            className="phone:min-h-11"
          >
            {submitLabel}
          </Button>
        </div>
      )}
    </div>
  );
}

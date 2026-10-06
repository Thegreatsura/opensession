import { useEffect, type RefObject } from "react";
import { blockingOverlayOpen } from "../lib/blocking-overlay";
import { matchesShortcut } from "../lib/shortcuts";

/**
 * The team-note chord (⌘⇧N by default) toggles the session composer between a
 * prompt and a team note, even when the composer is not focused, then puts the
 * caret in the composer so the note can be typed straight away.
 */
export function useComposerNoteShortcut(
  focused: boolean,
  setNoteMode: (update: (on: boolean) => boolean) => void,
  composerRef: RefObject<HTMLTextAreaElement | null>,
) {
  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      if (
        !focused ||
        e.defaultPrevented ||
        e.repeat ||
        !matchesShortcut(e, "composer-note") ||
        blockingOverlayOpen()
      )
        return;
      e.preventDefault();
      setNoteMode((on) => !on);
      queueMicrotask(() => composerRef.current?.focus());
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [focused, setNoteMode, composerRef]);
}

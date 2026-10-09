// Predicted next message for the empty composer (server/composer-prediction.ts).
// It arrives over the session socket as `composer_prediction`, shows as the
// composer's placeholder, and Tab in the empty composer takes it as a draft.
// The switch lives in lib/composer-prediction-pref.ts.

/**
 * Tab takes the prediction only from an empty composer, and only as a bare
 * Tab: Shift+Tab and modified Tabs keep their focus-moving meaning.
 */
export function takesPrediction(
  e: Pick<KeyboardEvent, "key" | "shiftKey" | "metaKey" | "ctrlKey" | "altKey">,
  draft: string,
  prediction: string | null | undefined,
): prediction is string {
  return (
    !!prediction &&
    e.key === "Tab" &&
    !e.shiftKey &&
    !e.metaKey &&
    !e.ctrlKey &&
    !e.altKey &&
    draft.trim() === ""
  );
}

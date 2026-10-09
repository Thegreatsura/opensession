// Composer autocomplete (server/composer-autocomplete.ts). Availability is
// asked once per page: the server answers false when no OpenAI key is set or
// the kill switch is on, and a completion call that finds it unavailable
// flips the cached answer so the composer stops asking.

import { request } from "./request";

let available: Promise<boolean> | null = null;

export function composerAutocompleteAvailable(): Promise<boolean> {
  available ??= request<{ available?: boolean }>("/composer-autocomplete", {
    label: "Autocomplete",
  })
    .then((r) => r?.available === true)
    .catch(() => {
      available = null;
      return false;
    });
  return available;
}

/** The suggested rest of the draft, or null. Throws only on abort. */
export async function composerCompleteApi(
  sessionId: string,
  draft: string,
  signal: AbortSignal,
): Promise<string | null> {
  try {
    const r = await request<{
      completion?: string | null;
      available?: boolean;
    }>(`/sessions/${encodeURIComponent(sessionId)}/composer-complete`, {
      method: "POST",
      body: { draft },
      signal,
      label: "Autocomplete",
    });
    if (r?.available === false) available = Promise.resolve(false);
    return r?.completion || null;
  } catch (e) {
    // A 429 or a provider error is a missed suggestion, never an error
    // to show: the person is typing and the draft is unaffected.
    if (signal.aborted) throw e;
    return null;
  }
}

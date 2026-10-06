import type { PortalTarget } from "./portals";

const PIN_EVENT = "opensession:pin-portal";

/** Ask the session that owns `target` to pin it in its side panel. */
export function requestPortalPin(target: PortalTarget): void {
  window.dispatchEvent(new CustomEvent(PIN_EVENT, { detail: target }));
}

export function onPortalPinRequest(
  listener: (target: PortalTarget) => void,
): () => void {
  const handle = (event: Event) => {
    if (!(event instanceof CustomEvent)) return;
    // SAFETY: only requestPortalPin dispatches this event, with a PortalTarget.
    listener(event.detail as PortalTarget);
  };
  window.addEventListener(PIN_EVENT, handle);
  return () => window.removeEventListener(PIN_EVENT, handle);
}

import { type RefObject, useEffect, useEffectEvent } from "react";
import { frameLocationReport } from "../lib/frame-location";

/** Calls `onLocation` whenever the framed page reports where it navigated. */
export function useFrameLocation(
  frame: RefObject<HTMLIFrameElement | null>,
  onLocation: (href: string) => void,
) {
  const report = useEffectEvent(onLocation);
  useEffect(() => {
    const listener = (event: MessageEvent) => {
      const href = frameLocationReport(event, frame.current?.contentWindow);
      if (href) report(href);
    };
    window.addEventListener("message", listener);
    return () => window.removeEventListener("message", listener);
  }, [frame]);
}

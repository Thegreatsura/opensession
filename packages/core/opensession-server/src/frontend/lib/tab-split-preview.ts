import type { CSSProperties } from "react";
import type { SplitSide } from "../components/SessionSplit";
import type { ResolvedSplit } from "./split-tabs";

type TabSplitPreviewStyle = CSSProperties & {
  "--split-preview-share": string;
};

/** Where a dragged tab lands: a split column, or the side panel (Portals). */
export type TabDropTarget = SplitSide | "panel";

export function tabSplitPreviewStyle(
  side: TabDropTarget | null,
  split: ResolvedSplit | null,
): TabSplitPreviewStyle | undefined {
  if (side === "panel") return { "--split-preview-share": "36%" };
  if (!side || !split) return undefined;
  const share = side === "left" ? split.ratio : 1 - split.ratio;
  return { "--split-preview-share": `${share * 100}%` };
}

import { useSyncExternalStore } from "react";
import {
  forceMergeFor,
  subscribeForceMerge,
  type OpenForceMerge,
} from "../lib/force-merge-store";

/** The session's open force_merge_pull_request card, if any. */
export function useForceMerge(sessionId: string): OpenForceMerge | null {
  const snapshot = () => forceMergeFor(sessionId);
  return useSyncExternalStore(
    (listener) => subscribeForceMerge(sessionId, listener),
    snapshot,
    snapshot,
  );
}

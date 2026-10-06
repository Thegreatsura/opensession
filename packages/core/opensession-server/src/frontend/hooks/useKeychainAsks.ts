import { useSyncExternalStore } from "react";
import {
  keychainAsksFor,
  subscribeKeychainAsks,
  type SessionKeychainAsk,
} from "../lib/keychain-ask-store";

/** This session's pending keychain asks that the viewer owns. */
export function useKeychainAsks(sessionId: string): SessionKeychainAsk[] {
  const snapshot = () => keychainAsksFor(sessionId);
  return useSyncExternalStore(
    (listener) => subscribeKeychainAsks(sessionId, listener),
    snapshot,
    snapshot,
  );
}

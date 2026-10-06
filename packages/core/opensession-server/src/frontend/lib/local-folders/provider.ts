import type { FolderAccess } from "./ops";

/** A folder this device was granted, and the sessions it is connected to. */
export interface FolderGrant {
  id: string;
  name: string;
  /** Home-relative path for people to recognize, when the device knows it. */
  displayPath?: string;
  readOnly: boolean;
  sessionIds: string[];
  /** False when the browser needs a click before it may read again. */
  usable: boolean;
}

export interface GrantPatch {
  sessionIds?: string[];
  readOnly?: boolean;
}

export interface LocalDevice {
  /** Stable per install. */
  id: string;
  /** What people recognize, such as "Acme MacBook Pro" or "Chrome on Mac". */
  label: string;
}

/** Where granted folders live on this device: the Mac app or the browser. */
export interface LocalFolderProvider {
  kind: "mac-app" | "browser";
  device(): Promise<LocalDevice>;
  grants(): Promise<FolderGrant[]>;
  /** Show the system folder picker. Null when the person cancels. */
  pick(): Promise<FolderGrant | null>;
  update(id: string, patch: GrantPatch): Promise<void>;
  remove(id: string): Promise<void>;
  access(id: string): FolderAccess;
  /** Ask the browser for access again. Must run inside a click. */
  reauthorize?(id: string): Promise<boolean>;
  /** Grants changed in another window or tab of this device. */
  onChange(callback: () => void): () => void;
}

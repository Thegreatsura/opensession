/**
 * Local folders through the Mac app's native bridge (packages/clients/mac,
 * local-folders.js). The shell keeps the grants, scoped to this server's
 * origin, resolves every path against the real folder (symlinks included),
 * and moves deleted files to the Trash. Grants survive restarts without
 * asking again.
 */
import type { OS1ShellBridge } from "../os1-shell";
import {
  FolderOpError,
  type FolderAccess,
  type FolderChunk,
  type FolderEntry,
  type FolderStat,
} from "./ops";
import type {
  FolderGrant,
  GrantPatch,
  LocalDevice,
  LocalFolderProvider,
} from "./provider";

/** Each native operation's arguments and result, as preload.js passes them. */
export interface NativeFolderOps {
  list: { args: { path: string }; result: FolderEntry[] };
  stat: { args: { path: string }; result: FolderStat };
  read: {
    args: { path: string; offset: number; length: number };
    result: FolderChunk;
  };
  write: {
    args: { path: string; data: Uint8Array; append: boolean };
    result: null;
  };
  mkdir: { args: { path: string }; result: null };
  move: { args: { from: string; to: string }; result: null };
  trash: { args: { path: string }; result: null };
}

export type NativeGrant = Omit<FolderGrant, "usable">;

export interface NativeLocalFolders {
  device(): Promise<LocalDevice>;
  list(): Promise<NativeGrant[]>;
  pick(): Promise<NativeGrant | null>;
  update(id: string, patch: GrantPatch): Promise<void>;
  remove(id: string): Promise<void>;
  op<K extends keyof NativeFolderOps>(
    id: string,
    op: K,
    args: NativeFolderOps[K]["args"],
  ): Promise<NativeFolderOps[K]["result"]>;
  onChange(callback: () => void): () => void;
}

export function nativeLocalFolders(
  shell: OS1ShellBridge | undefined,
): NativeLocalFolders | undefined {
  return shell?.localFolders;
}

/** Electron prefixes errors from ipcMain handlers; keep the useful part. */
function rethrow<Rejected>(error: Rejected): never {
  const message = error instanceof Error ? error.message : "Folder error";
  throw new FolderOpError(
    message.replace(/^Error invoking remote method '[^']+': (Error: )?/, ""),
  );
}

export function createElectronFolderProvider(
  native: NativeLocalFolders,
): LocalFolderProvider {
  const access = (id: string): FolderAccess => ({
    list: (path) => native.op(id, "list", { path }).catch(rethrow),
    stat: (path) => native.op(id, "stat", { path }).catch(rethrow),
    read: (path, offset, length) =>
      native.op(id, "read", { path, offset, length }).catch(rethrow),
    write: async (path, data, append) => {
      await native.op(id, "write", { path, data, append }).catch(rethrow);
    },
    mkdir: async (path) => {
      await native.op(id, "mkdir", { path }).catch(rethrow);
    },
    move: async (from, to) => {
      await native.op(id, "move", { from, to }).catch(rethrow);
    },
    trash: async (path) => {
      await native.op(id, "trash", { path }).catch(rethrow);
    },
  });
  return {
    kind: "mac-app",
    device: () => native.device(),
    grants: async () =>
      (await native.list()).map((grant) => ({ ...grant, usable: true })),
    pick: async () => {
      const grant = await native.pick().catch(rethrow);
      return grant ? { ...grant, usable: true } : null;
    },
    update: (id, patch) => native.update(id, patch).catch(rethrow),
    remove: (id) => native.remove(id).catch(rethrow),
    access,
    onChange: (callback) => native.onChange(callback),
  };
}

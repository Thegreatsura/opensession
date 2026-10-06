/**
 * Local folders through the File System Access API (Chrome and Edge). The
 * Mac app uses its native bridge instead (electron-provider.ts). The browser
 * only lets this page touch the directory the person picked, and it asks
 * again for permission after a restart, which needs a click.
 *
 * Grants live in IndexedDB, which is per origin, so each server sees only its
 * own. Deleting is not offered: the API removes files permanently.
 */
import { FolderOpError, type FolderAccess, type FolderEntry } from "./ops";
import type { FolderGrant, GrantPatch, LocalFolderProvider } from "./provider";

type Mode = { mode: "read" | "readwrite" };

/** Chromium's permission methods, missing from TypeScript's DOM types. */
interface PermissionMethods {
  queryPermission?(mode: Mode): Promise<PermissionState>;
  requestPermission?(mode: Mode): Promise<PermissionState>;
}

/** Chromium's in-place move, also missing from the DOM types. */
interface MoveMethod {
  move?(parent: FileSystemDirectoryHandle, name: string): Promise<void>;
}

interface PickerWindow {
  showDirectoryPicker?(
    options: Mode & { id?: string },
  ): Promise<FileSystemDirectoryHandle>;
}

interface StoredGrant {
  id: string;
  name: string;
  handle: FileSystemDirectoryHandle;
  readOnly: boolean;
  sessionIds: string[];
  addedAt: number;
}

const DB = "opensession-local-folders";
const STORE = "grants";
const DEVICE_KEY = "opensession-local-folders-device";
const CHANNEL = "opensession-local-folders";

function permissions(handle: FileSystemHandle): PermissionMethods {
  // SAFETY: Chromium implements these on every FileSystemHandle; callers use
  // optional calls, so a browser without them reads as "granted".
  return handle as FileSystemHandle & PermissionMethods;
}

export function browserFoldersSupported(): boolean {
  return (
    typeof window !== "undefined" &&
    "showDirectoryPicker" in window &&
    typeof indexedDB !== "undefined"
  );
}

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB, 1);
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains(STORE))
        request.result.createObjectStore(STORE, { keyPath: "id" });
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function withStore<T>(
  mode: IDBTransactionMode,
  run: (store: IDBObjectStore) => IDBRequest<T>,
): Promise<T> {
  const db = await openDb();
  try {
    return await new Promise<T>((resolve, reject) => {
      const request = run(db.transaction(STORE, mode).objectStore(STORE));
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
  } finally {
    db.close();
  }
}

const allGrants = () =>
  withStore("readonly", (store) => {
    // SAFETY: this store only ever holds StoredGrant records, written by
    // putGrant below.
    return store.getAll() as IDBRequest<StoredGrant[]>;
  });
const putGrant = (grant: StoredGrant) =>
  withStore("readwrite", (store) => store.put(grant));
const deleteGrant = (id: string) =>
  withStore("readwrite", (store) => store.delete(id));

async function permitted(grant: StoredGrant): Promise<boolean> {
  const state = await permissions(grant.handle).queryPermission?.({
    mode: grant.readOnly ? "read" : "readwrite",
  });
  return state === undefined || state === "granted";
}

function browserLabel(): string {
  const ua = navigator.userAgent;
  const browser = /Edg\//.test(ua)
    ? "Edge"
    : /OPR\//.test(ua)
      ? "Opera"
      : /Chrome\//.test(ua)
        ? "Chrome"
        : "Browser";
  const os = /Mac OS X/.test(ua)
    ? "Mac"
    : /Windows/.test(ua)
      ? "Windows"
      : /CrOS/.test(ua)
        ? "ChromeOS"
        : /Linux/.test(ua)
          ? "Linux"
          : "";
  return os ? `${browser} on ${os}` : browser;
}

function notFound(path: string): never {
  throw new FolderOpError(`${path || "."} does not exist`);
}

async function dirAt(
  root: FileSystemDirectoryHandle,
  path: string,
  create = false,
): Promise<FileSystemDirectoryHandle> {
  let dir = root;
  if (!path) return dir;
  for (const part of path.split("/")) {
    try {
      dir = await dir.getDirectoryHandle(part, { create });
    } catch (error) {
      if (error instanceof DOMException && error.name === "TypeMismatchError")
        throw new FolderOpError(`${path} is not a folder`);
      notFound(path);
    }
  }
  return dir;
}

function split(path: string): { parent: string; name: string } {
  const index = path.lastIndexOf("/");
  return index < 0
    ? { parent: "", name: path }
    : { parent: path.slice(0, index), name: path.slice(index + 1) };
}

type Located =
  | { kind: "file"; handle: FileSystemFileHandle }
  | { kind: "dir"; handle: FileSystemDirectoryHandle };

async function locate(
  root: FileSystemDirectoryHandle,
  path: string,
): Promise<Located> {
  if (!path) return { kind: "dir", handle: root };
  const { parent, name } = split(path);
  const dir = await dirAt(root, parent);
  try {
    return { kind: "file", handle: await dir.getFileHandle(name) };
  } catch {
    try {
      return { kind: "dir", handle: await dir.getDirectoryHandle(name) };
    } catch {
      notFound(path);
    }
  }
}

async function fileAt(
  root: FileSystemDirectoryHandle,
  path: string,
): Promise<FileSystemFileHandle> {
  const found = await locate(root, path);
  if (found.kind !== "file") throw new FolderOpError(`${path} is not a file`);
  return found.handle;
}

function access(root: FileSystemDirectoryHandle): FolderAccess {
  return {
    async list(path) {
      const dir = await dirAt(root, path);
      const out: FolderEntry[] = [];
      for await (const handle of dir.values()) {
        if (handle instanceof FileSystemFileHandle) {
          const entry: FolderEntry = { name: handle.name, kind: "file" };
          const file = await handle.getFile().catch(() => null);
          if (file) {
            entry.size = file.size;
            entry.mtimeMs = file.lastModified;
          }
          out.push(entry);
        } else out.push({ name: handle.name, kind: "dir" });
      }
      return out;
    },
    async stat(path) {
      const found = await locate(root, path);
      if (found.kind === "dir") return { kind: "dir", size: 0, mtimeMs: 0 };
      const file = await found.handle.getFile();
      return { kind: "file", size: file.size, mtimeMs: file.lastModified };
    },
    async read(path, offset, length) {
      const file = await (await fileAt(root, path)).getFile();
      const data = new Uint8Array(
        await file.slice(offset, offset + length).arrayBuffer(),
      );
      return { data, size: file.size, mtimeMs: file.lastModified };
    },
    async write(path, data, append) {
      const { parent, name } = split(path);
      const dir = await dirAt(root, parent, true);
      const handle = await dir.getFileHandle(name, { create: true });
      const writable = await handle.createWritable({
        keepExistingData: append,
      });
      try {
        if (append) await writable.seek((await handle.getFile()).size);
        await writable.write(new Blob([new Uint8Array(data)]));
        await writable.close();
      } catch (error) {
        await writable.abort().catch(() => {});
        throw error;
      }
    },
    async mkdir(path) {
      await dirAt(root, path, true);
    },
    async move(from, to) {
      const source = await locate(root, from);
      const exists = await locate(root, to).then(
        () => true,
        () => false,
      );
      if (exists) throw new FolderOpError(`${to} already exists`);
      if (source.kind !== "file")
        throw new FolderOpError(
          "Moving folders needs the Open Session Mac app",
        );
      const target = split(to);
      const targetDir = await dirAt(root, target.parent, true);
      // SAFETY: `move` is optional and feature-checked before the call.
      const movable = source.handle as FileSystemFileHandle & MoveMethod;
      if (movable.move) {
        await movable.move(targetDir, target.name);
        return;
      }
      const copy = await targetDir.getFileHandle(target.name, {
        create: true,
      });
      const writable = await copy.createWritable();
      await writable.write(await source.handle.getFile());
      await writable.close();
      const origin = split(from);
      await (await dirAt(root, origin.parent)).removeEntry(origin.name);
    },
  };
}

export function createBrowserFolderProvider(): LocalFolderProvider {
  const channel =
    typeof BroadcastChannel !== "undefined"
      ? new BroadcastChannel(CHANNEL)
      : null;
  const listeners = new Set<() => void>();
  channel?.addEventListener("message", () => {
    for (const listener of listeners) listener();
  });
  const changed = () => {
    channel?.postMessage("changed");
    for (const listener of listeners) listener();
  };
  const roots = new Map<string, FileSystemDirectoryHandle>();

  async function find(id: string): Promise<StoredGrant> {
    const grant = (await allGrants()).find((g) => g.id === id);
    if (!grant) throw new FolderOpError("This folder is no longer connected");
    return grant;
  }

  const view = async (grant: StoredGrant): Promise<FolderGrant> => ({
    id: grant.id,
    name: grant.name,
    readOnly: grant.readOnly,
    sessionIds: grant.sessionIds,
    usable: await permitted(grant).catch(() => false),
  });

  return {
    kind: "browser",
    async device() {
      let id = localStorage.getItem(DEVICE_KEY);
      if (!id) {
        id = `browser-${crypto.randomUUID()}`;
        localStorage.setItem(DEVICE_KEY, id);
      }
      return { id, label: browserLabel() };
    },
    async grants() {
      const grants = await allGrants();
      for (const grant of grants) roots.set(grant.id, grant.handle);
      return Promise.all(grants.map(view));
    },
    async pick() {
      let handle: FileSystemDirectoryHandle;
      try {
        // SAFETY: the picker method is optional in PickerWindow and checked
        // right below.
        const picker = window as Window & PickerWindow;
        if (!picker.showDirectoryPicker)
          throw new FolderOpError("This browser cannot open folders");
        handle = await picker.showDirectoryPicker({
          mode: "readwrite",
          id: "opensession-folder",
        });
      } catch (error) {
        if (error instanceof DOMException && error.name === "AbortError")
          return null;
        throw error;
      }
      const writable =
        (await permissions(handle).queryPermission?.({
          mode: "readwrite",
        })) !== "denied";
      for (const grant of await allGrants())
        if (await grant.handle.isSameEntry(handle).catch(() => false))
          return view(grant);
      const grant: StoredGrant = {
        id: crypto.randomUUID(),
        name: handle.name,
        handle,
        readOnly: !writable,
        sessionIds: [],
        addedAt: Date.now(),
      };
      await putGrant(grant);
      roots.set(grant.id, handle);
      changed();
      return view(grant);
    },
    async update(id: string, patch: GrantPatch) {
      const grant = await find(id);
      if (patch.readOnly === false && grant.readOnly) {
        const state = await permissions(grant.handle).requestPermission?.({
          mode: "readwrite",
        });
        if (state && state !== "granted")
          throw new FolderOpError("The browser did not allow edits");
      }
      const next: StoredGrant = { ...grant };
      if (patch.sessionIds) next.sessionIds = patch.sessionIds;
      if (patch.readOnly !== undefined) next.readOnly = patch.readOnly;
      await putGrant(next);
      changed();
    },
    async remove(id) {
      await deleteGrant(id);
      roots.delete(id);
      changed();
    },
    access(id) {
      const root = roots.get(id);
      if (!root) throw new FolderOpError("This folder is no longer connected");
      return access(root);
    },
    async reauthorize(id) {
      const grant = await find(id);
      const state = await permissions(grant.handle).requestPermission?.({
        mode: grant.readOnly ? "read" : "readwrite",
      });
      changed();
      return state === undefined || state === "granted";
    },
    onChange(callback) {
      listeners.add(callback);
      return () => listeners.delete(callback);
    },
  };
}

// Local folders: the native side of a session reaching a folder on this Mac
// (the server's local-folders.ts, the web app's lib/local-folders).
//
// The web app never sees an absolute path or a file descriptor. It names a
// grant by id and a path relative to that folder; this module keeps the
// grants, scoped to the server origin that asked for them, and resolves every
// path against the real folder, symlinks included, refusing anything that
// lands outside it. Deleting moves to the Trash. There is no command
// execution here.
const path = require("node:path");
const fsp = require("node:fs/promises");
const os = require("node:os");
const crypto = require("node:crypto");

const MAX_READ = 4 * 1024 * 1024;
const MAX_WRITE = 8 * 1024 * 1024;
const MAX_GRANTS = 64;

// Picking one of these would hand a session far more than a project folder.
const REFUSED_ROOTS = [
  "/",
  "/System",
  "/Library",
  "/Applications",
  "/usr",
  "/bin",
  "/sbin",
  "/etc",
  "/private",
  "/var",
  "/Volumes",
  "/Users",
];

class FolderError extends Error {}

function normalizeRelative(raw) {
  if (raw === undefined || raw === null) return [];
  if (typeof raw !== "string") throw new FolderError("Invalid path");
  const value = raw.replace(/\\/g, "/").trim();
  if (value.startsWith("/") || value.startsWith("~"))
    throw new FolderError("Paths must be relative to the folder");
  const parts = [];
  for (const part of value.split("/")) {
    if (!part || part === ".") continue;
    if (part === ".." || part.includes("\0"))
      throw new FolderError("Paths cannot leave the folder");
    parts.push(part);
  }
  return parts;
}

function inside(root, candidate) {
  return candidate === root || candidate.startsWith(root + path.sep);
}

function deviceLabel(hostname = os.hostname()) {
  const name = hostname
    .replace(/\.local$/i, "")
    .replace(/-/g, " ")
    .trim();
  return name || "Mac app";
}

class LocalFolders {
  constructor({
    file,
    fs = fsp,
    home = os.homedir(),
    hostname = os.hostname(),
    pickDirectory,
    trashItem,
  }) {
    this.file = file;
    this.fs = fs;
    this.home = home;
    this.hostname = hostname;
    this.pickDirectory = pickDirectory;
    this.trashItem = trashItem;
    this.state = null;
    this.saving = Promise.resolve();
  }

  async load() {
    if (this.state) return this.state;
    let parsed = null;
    try {
      parsed = JSON.parse(await this.fs.readFile(this.file(), "utf8"));
    } catch {}
    this.state = {
      deviceId:
        typeof parsed?.deviceId === "string" && parsed.deviceId
          ? parsed.deviceId
          : `mac-${crypto.randomUUID()}`,
      grants: Array.isArray(parsed?.grants)
        ? parsed.grants.filter(
            (g) =>
              g &&
              typeof g.id === "string" &&
              typeof g.origin === "string" &&
              typeof g.path === "string",
          )
        : [],
    };
    if (!parsed?.deviceId) await this.save();
    return this.state;
  }

  save() {
    const body = JSON.stringify(this.state, null, 2);
    const target = this.file();
    this.saving = this.saving
      .catch(() => {})
      .then(async () => {
        await this.fs.mkdir(path.dirname(target), { recursive: true });
        const temp = `${target}.${process.pid}.tmp`;
        await this.fs.writeFile(temp, body, { mode: 0o600 });
        await this.fs.rename(temp, target);
      });
    return this.saving;
  }

  displayPath(folder) {
    return inside(this.home, folder)
      ? `~${folder.slice(this.home.length)}`
      : folder;
  }

  view(grant) {
    return {
      id: grant.id,
      name: grant.name,
      displayPath: this.displayPath(grant.path),
      readOnly: grant.readOnly === true,
      sessionIds: [...(grant.sessionIds || [])],
    };
  }

  async device() {
    const state = await this.load();
    return { id: state.deviceId, label: deviceLabel(this.hostname) };
  }

  async list(origin) {
    const state = await this.load();
    return state.grants
      .filter((g) => g.origin === origin)
      .map((g) => this.view(g));
  }

  async grant(origin, id) {
    const state = await this.load();
    const grant = state.grants.find((g) => g.origin === origin && g.id === id);
    if (!grant) throw new FolderError("This folder is no longer connected");
    return grant;
  }

  async pick(origin, window) {
    const chosen = await this.pickDirectory(window);
    if (!chosen) return null;
    const real = await this.fs.realpath(chosen);
    if (REFUSED_ROOTS.includes(real) || real === this.home)
      throw new FolderError(
        "Choose a project folder rather than a system or home folder",
      );
    const info = await this.fs.stat(real);
    if (!info.isDirectory()) throw new FolderError("Choose a folder");
    const state = await this.load();
    const existing = state.grants.find(
      (g) => g.origin === origin && g.path === real,
    );
    if (existing) return this.view(existing);
    if (state.grants.filter((g) => g.origin === origin).length >= MAX_GRANTS)
      throw new FolderError("Too many folders are connected");
    const grant = {
      id: crypto.randomUUID(),
      origin,
      path: real,
      name: path.basename(real) || real,
      readOnly: false,
      sessionIds: [],
      addedAt: Date.now(),
    };
    state.grants.push(grant);
    await this.save();
    return this.view(grant);
  }

  async update(origin, id, patch = {}) {
    const grant = await this.grant(origin, id);
    if (Array.isArray(patch.sessionIds))
      grant.sessionIds = [
        ...new Set(
          patch.sessionIds
            .filter(
              (s) =>
                typeof s === "string" && /^[A-Za-z0-9._:-]{1,120}$/.test(s),
            )
            .slice(0, 500),
        ),
      ];
    if (typeof patch.readOnly === "boolean") grant.readOnly = patch.readOnly;
    await this.save();
  }

  async remove(origin, id) {
    const state = await this.load();
    state.grants = state.grants.filter(
      (g) => !(g.origin === origin && g.id === id),
    );
    await this.save();
  }

  /** The real path for `relative`, proven to be inside the grant. A path that
   *  does not exist yet resolves through its deepest existing ancestor. */
  async resolve(grant, relative) {
    const parts = normalizeRelative(relative);
    let root;
    try {
      root = await this.fs.realpath(grant.path);
    } catch {
      throw new FolderError(`${grant.name} is no longer on this Mac`);
    }
    const missing = [];
    let probe = path.join(root, ...parts);
    for (;;) {
      try {
        const real = await this.fs.realpath(probe);
        if (!inside(root, real))
          throw new FolderError("That path leads outside the folder");
        return {
          real: path.join(real, ...missing.reverse()),
          exists: !missing.length,
          root,
        };
      } catch (error) {
        if (error instanceof FolderError) throw error;
        if (error?.code !== "ENOENT" || probe === root) throw error;
        missing.push(path.basename(probe));
        probe = path.dirname(probe);
      }
    }
  }

  async op(origin, id, op, args = {}) {
    const grant = await this.grant(origin, id);
    const writes = ["write", "mkdir", "move", "trash"];
    if (writes.includes(op) && grant.readOnly)
      throw new FolderError("This folder is connected read-only");
    const fs = this.fs;
    const need = async (rel) => {
      const resolved = await this.resolve(grant, rel);
      if (!resolved.exists)
        throw new FolderError(`${rel || "."} does not exist`);
      return resolved.real;
    };
    switch (op) {
      case "list": {
        const dir = await need(args.path);
        const entries = await fs.readdir(dir, { withFileTypes: true });
        const out = [];
        for (const entry of entries) {
          const kind = entry.isDirectory()
            ? "dir"
            : entry.isFile()
              ? "file"
              : "other";
          if (kind !== "file") {
            out.push({ name: entry.name, kind });
            continue;
          }
          const info = await fs
            .lstat(path.join(dir, entry.name))
            .catch(() => null);
          out.push({
            name: entry.name,
            kind,
            ...(info ? { size: info.size, mtimeMs: info.mtimeMs } : {}),
          });
        }
        return out;
      }
      case "stat": {
        const info = await fs.stat(await need(args.path));
        return {
          kind: info.isDirectory() ? "dir" : info.isFile() ? "file" : "other",
          size: info.size,
          mtimeMs: info.mtimeMs,
        };
      }
      case "read": {
        const file = await need(args.path);
        const offset = Math.max(0, Math.floor(Number(args.offset) || 0));
        const length = Math.min(
          MAX_READ,
          Math.max(0, Math.floor(Number(args.length) || 0)),
        );
        const handle = await fs.open(file, "r");
        try {
          const info = await handle.stat();
          if (!info.isFile())
            throw new FolderError(`${args.path} is not a file`);
          const buffer = Buffer.alloc(
            Math.max(0, Math.min(length, info.size - offset)),
          );
          const { bytesRead } = buffer.length
            ? await handle.read(buffer, 0, buffer.length, offset)
            : { bytesRead: 0 };
          return {
            data: new Uint8Array(buffer.buffer, buffer.byteOffset, bytesRead),
            size: info.size,
            mtimeMs: info.mtimeMs,
          };
        } finally {
          await handle.close();
        }
      }
      case "write": {
        const data = args.data;
        if (!(data instanceof Uint8Array))
          throw new FolderError("Missing data");
        if (data.length > MAX_WRITE) throw new FolderError("Chunk too large");
        const { real, root } = await this.resolve(grant, args.path);
        if (real === root) throw new FolderError("Name a file to write");
        await fs.mkdir(path.dirname(real), { recursive: true });
        if (args.append === true) await fs.appendFile(real, data);
        else await fs.writeFile(real, data);
        return null;
      }
      case "mkdir": {
        const { real } = await this.resolve(grant, args.path);
        await fs.mkdir(real, { recursive: true });
        return null;
      }
      case "move": {
        const from = await need(args.from);
        const target = await this.resolve(grant, args.to);
        if (target.exists) throw new FolderError(`${args.to} already exists`);
        await fs.mkdir(path.dirname(target.real), { recursive: true });
        await fs.rename(from, target.real);
        return null;
      }
      case "trash": {
        const file = await need(args.path);
        const { root } = await this.resolve(grant, "");
        if (file === root)
          throw new FolderError("Cannot trash the folder itself");
        await this.trashItem(file);
        return null;
      }
      default:
        throw new FolderError(`Unknown operation ${op}`);
    }
  }
}

module.exports = { LocalFolders, FolderError, normalizeRelative, deviceLabel };

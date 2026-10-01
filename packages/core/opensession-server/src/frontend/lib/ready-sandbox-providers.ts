/** The slice of `/api/sandbox/status` that says where a session can run. */
export interface SandboxAvailability {
  connections?: ReadonlyArray<{ provider: string; state: string }> | null;
  providers?: ReadonlyArray<{
    id: string;
    configured: boolean;
    certified: boolean;
  }> | null;
}

/**
 * Providers a session can run in right now: the Ready connections, or on an
 * instance that predates connections, the configured and certified providers.
 */
export function readySandboxProviders(
  status: SandboxAvailability | null | undefined,
): string[] {
  if (!status) return [];
  if (status.connections?.length)
    return status.connections
      .filter((connection) => connection.state === "ready")
      .map((connection) => connection.provider);
  return (status.providers || [])
    .filter((provider) => provider.configured && provider.certified)
    .map((provider) => provider.id);
}

const PROVIDER_LABELS = new Map([
  ["daytona", "Daytona"],
  ["box", "Boat"],
  ["tart", "Mac VM"],
  ["usecomputer", "use.computer"],
]);

export function sandboxProviderLabel(id: string): string {
  return PROVIDER_LABELS.get(id) ?? id;
}

const MAC_PROVIDERS = new Set(["tart", "usecomputer"]);

/** One line on what choosing this machine means, for pickers. The agent
 *  always runs on this server; a Sandbox is a machine attached to the
 *  session for its files, commands, and Portals. */
export function sandboxProviderNote(id: string): string {
  if (id === "") return "A worktree on this server.";
  if (MAC_PROVIDERS.has(id))
    return "Attached Mac Sandbox with a desktop. Sleeps between turns, keeps files and Portals.";
  return "Attached Linux Sandbox. Sleeps between turns, keeps files and Portals.";
}

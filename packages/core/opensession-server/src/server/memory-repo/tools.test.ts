import { afterEach, expect, test } from "bun:test";
import { createRepoMemoryMcpServer } from "./tools";
import { createMcpRuntime } from "../mcp-runtime";

const runtimes: Awaited<ReturnType<typeof createMcpRuntime>>[] = [];
afterEach(async () => {
  await Promise.all(runtimes.splice(0).map((runtime) => runtime.close()));
});

async function catalog(fileTools: boolean) {
  const server = createRepoMemoryMcpServer({
    scopeKeys: () => ["workspace"],
    fileTools: () => fileTools,
  });
  const runtime = await createMcpRuntime({
    mcpServers: [],
    deniedToolIds: new Set(),
    inProcessMcp: { "opensession-memory": server },
  });
  runtimes.push(runtime);
  return runtime.catalog();
}

test("sync tool is available only with authorized memory file tools", async () => {
  expect((await catalog(false)).map((tool) => tool.id)).not.toContain(
    "opensession-memory_sync_memory_repository",
  );
  const tools = await catalog(true);
  expect(tools.map((tool) => tool.id)).toContain(
    "opensession-memory_sync_memory_repository",
  );
});

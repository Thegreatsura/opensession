/**
 * Operator commands for memory repositories (docs/memory-repos.md).
 *
 *   bun scripts/memory-repo.ts parity     memory-v2 vs repository index
 *   bun scripts/memory-repo.ts reindex    rebuild the index from git
 *   bun scripts/memory-repo.ts rollback   upsert repo-mode entries into memory-v2
 *   bun scripts/memory-repo.ts import     run the one-time memory-v2 import now
 *
 * Runs in-process against the same state directory as the server; writes take
 * the same cross-process locks.
 */
import { memoryRepoOptions } from "../packages/core/opensession-server/src/server/memory-repo/client";
import { MemoryRepoService } from "../packages/core/opensession-server/src/server/memory-repo/service";
import { memoryDatabasePath } from "../packages/core/opensession-server/src/server/memory-v2/runtime";

const command = process.argv[2];
const service = new MemoryRepoService(memoryRepoOptions());
try {
  switch (command) {
    case "parity":
      await service.freshAll();
      console.log(
        JSON.stringify(
          await service.parityReport(memoryDatabasePath()),
          null,
          2,
        ),
      );
      break;
    case "reindex":
      for (const name of await service.listRepos()) {
        await service.refresh(name, { force: true });
        console.log(`reindexed ${name}`);
      }
      break;
    case "rollback":
      await service.freshAll();
      console.log(
        JSON.stringify(
          await service.rollbackIntoV2(memoryDatabasePath()),
          null,
          2,
        ),
      );
      break;
    case "import":
      console.log(
        JSON.stringify(
          await service.migrateFromV2(memoryDatabasePath(), "import"),
          null,
          2,
        ),
      );
      break;
    default:
      console.error(
        "usage: bun scripts/memory-repo.ts parity|reindex|rollback|import",
      );
      process.exitCode = 2;
  }
} finally {
  service.close();
}

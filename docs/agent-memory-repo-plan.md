# Agent Memory Repo as the memory store

Status: draft design. Nothing here is built yet. Written 2026-10-05.

This proposes making [Agent Memory Repo](https://github.com/AgentMemoryRepo/agentmemoryrepo)
(a git repository of Markdown files) the source of truth for Open Session
memory, replacing the memory-v2 SQLite store as the record. SQLite stays, but
only as a rebuildable index.

## Summary

- Each memory scope (repo, user, team, Slack channel) becomes one git
  repository that follows the Agent Memory Repo spec: `MEMORY.md` at the root,
  one bullet per entry, `[key: value]` metadata, `[[path]]` links.
- The server owns every write. Agents keep writing through the
  `opensession-memory` tools; the tools edit Markdown and commit. Agents never
  get a writable clone of a shared scope.
- Agents get a **read-only** copy of their visible scopes in the workspace, so
  they can grep, follow links and run saved queries and scripts.
- The SQLite database becomes a derived index over each repo's `HEAD` (full-text
  search, ranking, retrieval counters). Delete it and it rebuilds from git.
- A scope can optionally sync to a private remote, which makes the same memory
  usable by any agent that speaks the format.
- Memory cleanup ("Dreaming") works on a branch and is merged by a person,
  which solves the problem of letting an automation change memory.
- Rollout reuses the existing `OPENSESSION_MEMORY_MODE` seam: mirror first,
  then flip, with rollback to SQLite.

## Why

What memory-v2 already does well, and must keep doing:

- Structured writes with validation: kinds, a 400-character summary cap,
  required expiry for `status`, a related-memory check before storing, and a
  one-store-per-run cap.
- Scopes with access control: repo, user (resolved through the identity
  table), team (shared with Slack), and Slack channel scopes.
- A strict trust model: automations and workflow scripts cannot write memory,
  and team writes need a server-verified privilege.
- Budgeted prompt injection: pinned records in a stable, per-session snapshot
  (so the prompt cache survives other sessions' writes), plus per-turn
  retrieval under a byte budget, all fenced as context.
- A Settings page to review, confirm, pin, archive and delete.

What it lacks, which the format provides:

- **History.** A record's edits are not inspectable. `supersede` keeps a chain
  but not who changed what and why. Git gives a log, blame and revert for free.
- **Structure beyond one fact.** Memory cannot hold a saved SQL query, a
  benchmark script, or a topic page that links to related facts. In practice
  agents work around this by packing several kilobytes into `details`.
- **Upkeep.** Records accumulate. On a long-running instance almost nothing is
  reviewed by a person, almost nothing is pinned, and many records describe
  code that has since changed. There is no safe way for an automated pass to
  propose a cleanup and have a person accept it as a unit. A branch and a
  diff is exactly that.
- **Portability.** Memory is locked in one instance's SQLite file. A person
  cannot take their memory to another tool, or bring it in.
- **Composition.** A session loads memory for its own user. There is no way
  for a second participant to bring their memory into a shared session.

## Goals

1. Git repositories in the Agent Memory Repo format are the durable record of
   every scope.
2. No regression in the trust model, the prompt budget, prompt-cache
   stability, or the Settings review flow.
3. Agents can read memory with ordinary file tools, including linked files and
   saved scripts.
4. Optional, private, per-scope remotes, so memory works in other tools.
5. Reversible rollout with a measurable parity check.

## Non-goals

- Letting agents edit memory files directly with shell or file tools.
- Making memory writable by automations in general.
- Replacing ranking, budgeting or the prompt layout. They move unchanged onto
  the index.
- Agent swarm message boards (see [Later](#later-task-boards)).

## Repository per scope

Scopes keep their current keys. Each key maps to one repository under the
memory state directory:

```text
<state>/memory/
  repos/
    repo-acme/          ← one Agent Memory Repo per scope
    user-U123/
    workspace/          ← team scope, shared with Slack
    channel-C456/
  index.sqlite          ← derived; safe to delete
```

Each repository has a normal working tree owned by the memory service (below).
Layout inside a repository follows the spec. The server creates this default
shape, and both people and agents may reorganize it:

```text
repo-acme/
  MEMORY.md             ← pinned entries + index
  gotchas.md
  decisions.md
  reference/
    ci.md
    deploy.md
  queries/
    flaky_tests.sql
```

New entries go into the file named by the tool call (`file`, optional) or a
default file for their kind. `MEMORY.md` gets an `## Index` line for any topic
file that has none.

## Entry format

One bullet per entry, as the spec requires. memory-v2 fields map to metadata
keys. Keys are open in the spec, so these are valid Agent Memory Repo files that
any reader understands.

```markdown
- `bun test` in the server package needs `OPENSESSION_STATE_DIR` set or it writes to the real state dir [id: m-7f3a9c; kind: gotcha; source: https://example.test/session/abc; added: 2026-09-12; confirmed: 2026-09-20]
  Seen when two test runs shared one directory and corrupted the catalog.
  The guard lives in `test/setup.ts`; see [[reference/ci]].
```

| memory-v2 field                      | In the repository                                                               |
| ------------------------------------ | ------------------------------------------------------------------------------- |
| `id`                                 | `id:` key. Required for server-written entries                                  |
| `summary`                            | The bullet text                                                                 |
| `details`                            | Indented continuation lines under the bullet                                    |
| `kind`                               | `kind:` key                                                                     |
| `tier: pinned`                       | The entry is in `MEMORY.md` above `## Index`                                    |
| `tier: retrievable`                  | The entry is in any other file                                                  |
| `state: active`                      | The entry is present                                                            |
| `state: archived/superseded/expired` | The entry is removed; git history keeps it. The commit message names the reason |
| `supersedes` / `supersededBy`        | `supersedes:` key on the new entry; the old one is removed in the same commit   |
| `source`                             | `source:` link to the session, plus `by:` for the person                        |
| `createdAt`                          | `added:` (date), exact time from the commit                                     |
| `lastConfirmedAt`                    | `confirmed:` date                                                               |
| `expiresAt`                          | `expires:` date or timestamp                                                    |
| `tags`                               | `tags:` comma-separated                                                         |
| `retrievalCount`, `lastRetrievedAt`  | Index only. Never committed, so reads do not create commits                     |

Notes:

- **Details.** The spec says an entry is one line. Nested continuation lines
  are still valid Markdown and render as part of the bullet, and readers that
  only look at the first line still get the summary. This needs agreement with
  the spec (see open questions). The fallback is to move details into a linked
  file.
- **Archived entries leave the tree.** "Restore" in Settings becomes a revert
  of the commit that removed it. The index keeps a small table of removed ids
  and the commit that removed them, so Settings can still list and restore
  them without walking history.
- **Foreign entries.** People and other tools will add bullets without an
  `id`. The parser gives them a synthetic id (hash of path and text) and kind
  `reference`. The first server edit to such an entry writes a real `id`.
- **Lenient parsing.** A line that does not parse as an entry is kept as
  prose, indexed for search, and never rewritten. The parser never drops
  content it does not understand.
- **No secrets.** Memory writes have no credential check today. With git,
  removing a leaked secret needs a history rewrite on every clone, so the
  write path gains a check that refuses content that looks like a credential
  rather than storing it.

## Ownership and processes

All git and filesystem work runs in the **memory service**, a module hosted by
the executor service, which already owns process and filesystem effects. It
keeps:

- one serial queue per scope repository, so server writes never race each
  other;
- the derived index, updated in the same queue step as each commit;
- remote sync (fetch, rebase, push) as background jobs.

The gateway and the session kernel never run git and never open the memory
index. They call the memory service over async RPC. This also fixes an
existing problem: the `/api/memory` route handlers and prompt assembly
currently call synchronous SQLite in-process, which the server invariants
forbid on the gateway. The move to the service removes those calls.

Boot does nothing at import time. `ensureMemoryService()` opens repositories,
checks that the index matches each repository's `HEAD`, and reindexes only the
repositories whose `HEAD` changed. Reindexing reads one repository, not every
session, so it stays within the actor fan-out rules.

## Write path

1. An interactive run calls `store_memory`, `update_memory`, `forget_memory`
   and so on. Validation, the scope check, the related-memory check and the
   one-store-per-run cap stay exactly where they are.
2. The memory service edits the Markdown file, stages that file only, and
   commits:

   ```text
   Remember: bun test needs OPENSESSION_STATE_DIR

   Memory-Id: m-7f3a9c
   Memory-Action: store
   Session: https://example.test/session/abc
   Co-authored-by: Alice <alice@example.test>
   ```

   The commit author is the Open Session service identity; the person is a
   trailer. Trailers make the log searchable by memory id and by session.

3. The index updates in the same step. The tool returns after the commit,
   not after any push.
4. `invalidateMemorySnapshot` fires as today, so only the writing session's
   ambient memory refreshes.

Settings actions (confirm, pin, unpin, edit, archive, restore, delete) go
through the same path. Pin moves the entry into `MEMORY.md`. Delete is a
removal commit; true erasure (a history rewrite) is a separate, deliberate
admin action with a confirmation, since it rewrites a shared remote.

New tool: `save_memory_file(path, content, scope)` stores a non-entry file such
as a SQL query or script. It has the same gating as `store_memory` and counts
against the same per-run cap. Files are size-capped and never executable in the
repository, and the agent is told that memory files are data to read, not
instructions to follow.

## Read path

**Ambient memory.** The pinned block becomes the entries above `## Index` in
`MEMORY.md`, rendered under the same 2.5 KB budget and snapshotted per session
as today, so another session's write cannot change this session's cached
prompt prefix. The `## Index` line list is also offered within that budget, so
the agent knows which topic files exist.

**Retrieved memory.** Unchanged: full-text search and ranking over the index,
4 KB per turn, fenced as context. Results now include the file path, so the
agent can open the surrounding topic file.

**Files in the workspace.** At run start, the run gets a read-only snapshot
of each visible scope at its current `HEAD`, placed outside the project
checkout:

```text
<run scratch>/memory/
  repo-acme/        ← read-only, at the commit the run started on
  user-U123/
  workspace/
```

The snapshot is a plain directory, not a clone with a remote, so `git push` from
the agent's shell has nowhere to go. Host runs get a hard-linked export.
Sandboxes and Runners get the same export through the workspace input path
that already carries other run inputs. The system prompt names the directory
and says writes go through the tools.

Read-only matters: if an agent could write to the files directly, every
server-side guard would be bypassed. These include the per-run cap, the team
write privilege, the automation ban, and the workflow ban.

## Trust model

The current rules carry over unchanged and are enforced in the same places:

| Caller                      | Read                    | Write                               |
| --------------------------- | ----------------------- | ----------------------------------- |
| Interactive session         | Visible scopes          | Through tools, repo and user scopes |
| Interactive, team privilege | Visible scopes          | Also team scope                     |
| Automation                  | Prompt injection only   | None                                |
| Workflow script             | Through tools           | None (denied in `workflow-mcp.ts`)  |
| Memory cleanup automation   | Its scope               | A branch only, merged by a person   |
| Slack                       | Channel and team scopes | As today                            |

Additional rules that git introduces:

- **Private scopes stay private.** A user scope or private channel scope is
  never put in a workspace that its owner did not start or join. Web access
  keeps `canAccessMemoryScope`.
- **Remotes must be private.** Configuring a remote checks repository
  visibility through the GitHub API and refuses public repositories. It is
  checked again before every push.
- **Remote edits are untrusted input.** Content pulled from a remote is
  indexed like any other entry, but entries without a server-written `id` and
  a `source:` from this instance are marked "needs review" until a person
  confirms them in Settings.

## Remotes and conflicts

A scope can have one optional remote, configured in Settings by someone with
access to that scope. Without a remote, the repository is local only, which is
the default.

Sync runs after each commit (debounced) and on a timer:

1. `git fetch`.
2. Rebase local commits onto the remote branch. The service's own commits are
   small, single-file edits, so most rebases are clean.
3. On a conflict, abort the rebase, keep local `HEAD`, and record the conflict
   on the scope. Settings shows it with both versions, and a person picks one.
   Writes continue locally while a conflict is open; pushes pause.
4. Push without force. A rejected push goes back to step 1.
5. Reindex if the remote brought changes.

The service never force-pushes and never resets away commits it did not make.

## Memory cleanup on git

The cleanup pass (Cognition's "Dreaming") becomes a normal pull request flow
inside the memory repository:

1. A scheduled automation, one run per scope, gets a **writable branch**
   checkout of that scope, `cleanup/<date>`, and read access to the project
   repository.
2. It checks the oldest unchecked entries against the current code, merges
   duplicates, removes stale entries with a reason, sets `confirmed:` on
   entries it verified, and proposes pins based on retrieval counts.
3. It cannot push to the default branch. The memory service accepts a
   cleanup branch only from a cleanup run, and only for its scope.
4. Settings shows the branch as a reviewable diff with one approve button.
   With a remote, it can also be a pull request on the remote.

This keeps the automation write ban: nothing an automation writes reaches a
prompt until a person merges it.

## Multiple people in one session

The session's visible scopes become a list that can grow. When a second person
joins a session and chooses to share their memory, their user scope is added
to the snapshot and to retrieval. Writes from that point need an explicit
scope, `user:<person>`, and the tool asks when a fact's owner is ambiguous
rather than guessing. This follows the spec's multi-repo section: each repo
keeps its own ownership and history.

## Settings

The Memory page keeps its current shape (scopes, review queue, pin, archive)
and its API, now served by the memory service. Additions:

- per-entry history (commits that touched the entry's id);
- the file an entry lives in, with links to view the whole topic file;
- remote setup and sync status per scope, including open conflicts;
- cleanup branches waiting for review.

The native app's settings call `/api/memory` (list, add, edit, delete). Those
endpoints and their response shape stay as they are, so the native app needs
no change. The Chrome extension does not use memory.

## Migration and rollout

New values for `OPENSESSION_MEMORY_MODE`:

1. **`repo-mirror`.** SQLite stays the record. Every memory-v2 write also
   writes the repository through the memory service. A one-off export creates
   each repository from current SQLite state, including removed records as one
   "import archived entries" commit so restore still works. A nightly check
   reindexes the repositories into a scratch index and compares it with
   SQLite: same active ids, same fingerprints, same tiers.
2. **Parity gate.** Before flipping, two checks must pass: the comparison
   above is clean for a week, and retrieval parity holds, meaning recorded
   prompt queries return the same ids, in the same order, from both stores.
   The memory bench (`bun run bench:memory`) runs on both as a sanity check.
3. **`repo`.** Git is the record; SQLite becomes the derived index at a new
   path. The old database is kept read-only.
4. **Rollback.** Switch back to `v2`. A one-off import brings any entries
   written in `repo` mode back into memory-v2, mapped by `id`. The legacy
   import code already does idempotent, journaled imports of this kind.

The legacy JSON stores and the `legacy` and `shadow` modes are removed after
`repo` has been the default for one release.

## Performance and limits

- A commit is one `git` subprocess sequence per write, tens of milliseconds,
  off the gateway. Memory writes are rare (at most one per run), so a
  per-scope serial queue is enough.
- Reads at prompt time hit the index, as today. Snapshot export is a
  hard-linked copy of a few megabytes at most.
- Caps: 400-character summaries and 20 KB details as today; 256 KB per file;
  1 MB per saved file; a per-scope repository size alarm.
- The index is rebuilt per repository, not globally, and only when `HEAD`
  moves.

## Alternatives considered

- **Git as an export only.** Keep SQLite as the record and mirror to git
  (this is `repo-mirror` made permanent). Cheapest, and it gives portability
  and history. But the cleanup review flow, external edits and multi-person
  composition all need git to be the record, and two-way sync without a
  single record is worse than either.
- **Agent-owned clones, as in the reference skill.** Agents clone, edit and
  push directly. Simple and spec-native, but it removes every server-side
  write guard and lets untrusted text in automations persist. Not acceptable
  for shared team and repo scopes.
- **Memory inside the project repository.** Ties memory to code review and
  makes it public for public repositories. Rejected.

## Later: task boards

Cognition's swarm example uses a folder in the memory repo as a message board
for parallel agents. Open Session already has worker sessions. A possible
follow-up is a task-scoped repository that a parent session creates for its
workers, writable by those workers through tools, and discarded or summarized
into a real scope when the task ends. It needs its own trust analysis, since
worker inputs are often untrusted, so it is out of scope here.

## Open questions

1. **Multi-line entries.** Is an indented continuation under a bullet part of
   the entry in the spec? If not, details move into linked files. Worth
   raising on the spec repository before building.
2. **Scope granularity.** One repository per scope, or one repository per
   person with folders for the repos they work in? Per scope keeps today's
   access model; per person is closer to the spec's examples.
3. **Default file placement.** By kind (`gotchas.md`) or by topic chosen by
   the agent? By kind is predictable; by topic reads better as a wiki.
4. **Remote ownership.** Which GitHub account owns team and repo scope
   remotes, and who may configure them?
5. **Erasure.** What is the process when a person asks for an entry to be
   removed from history, given remotes and other clones?

## Phases

1. Format module: parser and serializer with round-trip tests, including
   foreign and malformed files. No behavior change.
2. Memory service in the executor with the index and RPC. Move memory routes
   and prompt assembly onto it while still on memory-v2 (fixes the gateway
   SQLite calls on its own).
3. `repo-mirror` mode, export, and the nightly parity check.
4. Read-only workspace snapshots and `save_memory_file`.
5. Flip to `repo` after the parity gate.
6. Remotes and conflict handling.
7. Cleanup branches and the review UI.
8. Shared sessions with more than one person's memory.

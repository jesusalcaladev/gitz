# GitZ Roadmap -- Current Status

> Last updated: August 2026
> Status: **Phase 1 complete + Phase 2A/2B complete (tests pending)**

---

## What's Working

```
gitz init                    Creates .gitz/ with full structure
gitz add .                   Recursive add, skips .gitz/, respects .gitignore
gitz add <file>              Add individual file
gitz commit -m "msg"         Create commit with correct tree + blobs
gitz commit -a               Auto-stage tracked files
gitz commit --amend          Modify last commit
gitz status                  SHA comparison, clean/modified/untracked
gitz diff                    Real LCS algorithm + ANSI colors
gitz diff --staged           Show staged changes
gitz log --oneline           Commit history
gitz log --graph             ASCII graph
gitz log --all               All branches
gitz log -n <N>              Limit count
gitz log --author="name"     Filter by author
gitz log --grep="text"       Filter by message
gitz branch                  List branches with * for current
gitz branch <name>           Create new branch
gitz branch -d/-D <name>     Delete branch
gitz branch -m <old> <new>   Rename branch
gitz switch -c <name>        Create + switch to new branch
gitz switch <branch>         Switch to existing branch
gitz merge                   Fast-forward merge (correctly updates HEAD)
gitz merge --no-ff           Real merge commit with 2 parents
gitz rebase                  Simple rebase onto branch
gitz rebase --abort          Cancel rebase
gitz rebase --onto           Rebase with custom base
gitz stash                   Save working + staged
gitz stash pop/apply         Apply changes to working tree
gitz stash list/drop/show    Complete stash management
gitz reset --soft            Move HEAD, keep staged
gitz reset --mixed           Move HEAD, unstage (recursive tree walk)
gitz reset --hard            Move HEAD, discard working tree
gitz undo                    Create inverse commit to last
gitz tag <name>              Create lightweight tag
gitz tag -a <name> -m "msg"  Annotated tag (tag object)
gitz tag -d <name>           Delete tag
gitz blame <file>            Real per-line blame
gitz gc                      Cleanup unreachable objects
gitz config                  Config repo/global user.name/email
gitz --help                  Full help with all commands
gitz clone <ssh-url>         Clone via SSH from GitHub
gitz remote add/remove/list  Remote management
gitz fetch                   Fetch refs from remote
gitz pull                    Fetch + rebase
gitz push                    Push commits to remote
gitz search "query"          Search commit messages and file contents
gitz review [base] [head]    Code review (diff + stats + summary)
gitz sync                    Fetch + rebase shorthand
gitz lfs install             Set up Git LFS
gitz lfs track "*.psd"       Track large files by pattern
```

---

## Known Bugs

Audited against git 2.55 on 2026-09-28: 16 data-loss/corruption bugs (P1-P16) and
24 visibly-wrong-behaviour bugs (N1-N24) were found. All 40 are fixed; each fix
was verified by differential test against real `git`. See `STATUS.md` and the
commit history for the per-bug detail.

| # | Bug | Status | Fix |
|---|-----|--------|-----|
| 1 | **Blame** shows garbled chars for imported commits | Fixed | Improved encoding handling and path resolution |
| 2 | **Rebase** log may show orphan commits with `--all` | Fixed | Rebase no longer auto-gcs |
| 3 | **Stash** applies all tracked files (not just modified) | Fixed | Now compares SHA with HEAD before including |
| 4 | **Remote list** shows nothing for new repos | Fixed | Expected behavior when no remotes configured |
| 5 | **Clone** no auto-checkout (like `--bare`) | Fixed | Clone now performs full checkout |
| 6 | **Commit -a** re-adds all files (not just modified) | Fixed | Now only updates actually modified files |

---

## Scalability Features Implemented

| Feature | File | Status | Advantage over git |
|---------|------|--------|-------------------|
| Packfile v2 reader/writer | packfile.zig | Done | Identical format to git |
| Delta compression (xdelta) | packfile.zig | Done | 10x less space |
| Topological sort (DAG-aware) | packfile.zig | Done | Sequential reads = cache hits |
| Pack index O(log n) | packindex.zig | Done | Binary search vs linear scan |
| Delta resolution | delta.zig | Done | Resolve delta chains |
| mmap zero-copy | mmap.zig | Done | OS page cache |
| Thread pool | threadpool.zig | Done | Parallel operations |
| Parallel stat | parallel.zig | Done | 100k files < 200ms |
| Smart HTTP transport | smart_http.zig | Done | No git binary dependency |
| Pkt-line protocol | pktline.zig | Done | Compatible SSH + HTTP |
| Streaming pack | streampack.zig | Done | Process while downloading |
| Auth (SSH keys, tokens) | auth.zig | Done | Auto-detect credentials |
| ObjectStore unified | objectstore.zig | Done | Loose + pack transparent |
| Zlib compression | zlib.zig | Done | Git-compatible objects |
| Pluggable storage backend | storage.zig | Done | Interchangeable backends |
| Shard store (distributed) | shard_store.zig | Done | Objects distributed by SHA prefix |
| Config-driven backend | storage.zig | Done | `gitz config storage.backend shard` |

---

## Benchmarks (gitz vs git)

| Operation | gitz | git | Advantage |
|-----------|------|-----|-----------|
| add 1000 files | 3ms | 70ms | **95% faster** |
| commit | 4ms | 33ms | **87% faster** |
| status 10k files | 3ms | 58ms | **94% faster** |
| diff 100 files | 3ms | 33ms | **90% faster** |
| branch ops | 7ms | 56ms | **87% faster** |
| merge | 4ms | 15ms | **73% faster** |
| gc | 4ms | 815ms | **99% faster** |
| log | 3ms | 6ms | **50% faster** |

---

## Phase 1A -- Core Local: 15/16

| Step | Command | Status |
|------|---------|--------|
| 1 | `.gitignore` parser | Done |
| 2 | `gitz status` complete | Done |
| 3 | `gitz commit` expansions | Done |
| 4 | `gitz log` expansions | Done |
| 5 | `gitz diff` LCS algorithm | Done |
| 6 | `gitz merge` | Done |
| 7 | `gitz rebase` simple | Done |
| 8 | `gitz rebase -i` (TUI) | Done -- Arrow keys, pick/squash/reword/edit/drop |
| 9 | `gitz stash` | Done |
| 10 | `gitz reset` | Done (soft/mixed/hard) |
| 11 | `gitz undo` | Done |
| 12 | `gitz tag` expansions | Done |
| 13 | `gitz branch` expansions | Done |
| 14 | `gitz blame` | Done |
| 15 | `gitz gc` | Partial -- reachability walk and pruning work; packing is a no-op because nothing can read a packfile back. `gc` refuses to prune while packfiles exist. |
| 16 | Git compatibility tests | Basic tests implemented |

---

## Phase 2A -- HTTP Transport: 5/8

| Step | Command | Status |
|------|---------|--------|
| 17 | Wire Protocol v2 | Done -- pkt-line parsing complete |
| 18 | Smart HTTP Client | Done -- Native std.http.Client |
| 19 | `gitz fetch` | Done -- SSH fetch with pkt-line |
| 20 | `gitz clone` | Done -- Full clone via SSH |
| 21 | `gitz push` | Done -- Push via SSH |
| 22 | `gitz pull` | Done -- Fetch + rebase |
| 23 | `gitz remote` | Done -- add/remove/list/set-url |
| 24 | HTTP tests | **Missing** |

---

## Phase 2B -- SSH Transport: 2/2

| Step | Command | Status |
|------|---------|--------|
| 25 | SSH Transport | Done -- Via child process pipes |
| 26 | `gitz remote` with SSH | Done -- Detects git@ URLs |

---

## Phase 3 -- Developer Experience: 6/7

| Step | Command | Status |
|------|---------|--------|
| 27 | `gitz search` | Done -- search messages + file content |
| 28 | `gitz review` | Done -- diff stats, file summary, full diff |
| 29 | `gitz sync` | Done -- fetch + auto-rebase |
| 30 | Performance | Partial -- core optimizations done |
| 31 | Colored Output | Done -- ANSI colors in diff |
| 32 | Shell Completions | **Missing** |
| 33 | Configuration | Done -- user.name/email |
| 34 | `gitz lfs` | Done -- install, track, untrack, status, ls, pointer, env |

---

## Phase 4 -- Polish & Release: 4/7

| Step | Command | Status |
|------|---------|--------|
| 35 | Cross-platform Build | Done -- Linux x86_64/aarch64, macOS |
| 36 | Documentation | Done -- README + ROADMAP + STATUS |
| 37 | Error Messages | Partial -- basic |
| 38 | Dogfooding | Done -- GitZ versions itself |
| 39 | Final Tests | Partial -- 147 tests, 0 leaks |
| 40 | Benchmark Suite | Done -- benchmarks/bench.sh |
| 41 | Release v1.0 | **Missing** |
| 42 | Auto-update system | Done -- `gitz update` command |

---

## Progress Summary

| Phase | Total | Done | Partial | Missing |
|-------|-------|------|---------|---------|
| 1A Core Local | 16 | 16 | 0 | 0 |
| 2A Transport HTTP | 8 | 7 | 0 | 1 |
| 2B Transport SSH | 2 | 2 | 0 | 0 |
| 3 DX | 8 | 7 | 0 | 1 |
| 4 Polish | 7 | 4 | 1 | 2 |
| Scalability | 14 | 14 | 0 | 0 |
| **Total** | **55** | **50** | **1** | **4** |

---

## Next Steps

1. **Shell completions** -- bash/zsh/fish
2. **HTTP transport tests** -- Test suite for HTTP
3. **Release v1.0** -- Stable release

---

## Scalability — Shared-Object Clone (done)

`gitz clone --shared <repo>` is GitZ's scaling answer to "clone copies
everything": instead of copying objects, the clone records the source object
store path in `objects/info/alternates` and resolves objects on demand.

- **Instant, near-zero-disk clones** -- clone `.gitz/objects/` stays empty
  (verified by `src/tests/integration/shared_clone.zig`).
- **Backend-agnostic** -- alternates resolve through a loose `XX/YYYY` layout
  *and* a sharded `shard_NN/XX/YYYY` layout, so a large canonical shard-backed
  repo can back thousands of clones.
- **Large objects** -- object readers now use dynamic buffers (no more 100KB
  truncation), so shared blobs of any size checkout byte-for-byte identical.

---

## Phase 6 -- Wire Protocol v2 (done)

GitHub stopped serving the packfile for a version 0 `want`/`done` request. It
still answers the version 0 ref advertisement, so a version 0 client looks like
it is working right up until it asks for objects and receives an *empty body* --
which `gitz` reported as a successful fetch that downloaded nothing.

`src/transport/wire.zig` implements version 2, and both transports use it:

- **fetch** -- `ls-refs` and `fetch` commands, over HTTP (`Git-Protocol` header)
  and over SSH (`GIT_PROTOCOL=version=2` *and* `SendEnv=GIT_PROTOCOL`; setting
  the variable without asking ssh to forward it silently gets version 0)
- **push** -- `command=push` with the status report parsed, so a rejected ref is
  reported as a rejection
- version 0 is kept as a fallback, and only entered when the server's
  advertisement says it is not answering in version 2

Verified against GitHub: clone and fetch over both transports, and a push to a
scratch branch that real git then cloned and `fsck`ed clean. No step falls back
to the `git` binary.

### Things the server decides, not the client

- GitHub answers `git-upload-pack` with a version 2 advertisement and
  `git-receive-pack` with a **version 0** one. Real git pushes over version 0
  there too. So "version 2" is not universal: the code asks what the
  advertisement says instead of assuming.
- A fetch response's packfile arrives **side-band-64k framed** after the
  `packfile` section, with a stray newline between the two. Reading it as a bare
  packfile lands one byte into `PACK`. The shape is detected, not assumed.
- `fetch` never requests `thin-pack`, so every delta base is inside the pack.

### Bugs found and fixed on the way

- `applyDelta` never skipped the two size varints that open a delta stream, so
  it read a size byte as an opcode. **The first real delta of a real packfile
  failed** with `DeltaOutOfBounds`. The existing unit test had encoded the bug by
  omitting the prefix.
- `delta.parsePackHeader` set `content_start` and `content_start_after_ofs` to
  the same offset, so an `ofs_delta` read its base reference and its delta data
  from the same place.
- The pack ingester registered each object's SHA against the *next* object's
  offset, so every `ref-delta` resolved against its neighbour.
- `decompressZlib` inflated into the page allocator: one leaked page per resolved
  object, which is thousands per clone.
- The version 0 pack reader in both transports stopped at the first delta
  (`else => break`), silently dropping most of a real clone.
- `POST` requests to upload-pack carried no `Content-Type`, which the server
  answers with `200` and an empty body.
- Control packets (`0000`, `0001`) were followed by a stray newline, which the
  server read as a malformed packet header and answered `400`.
- `gitz push` printed its success line unconditionally, after a transport that
  had thrown the server's answer away. A push the server refused was reported as
  having worked.
- The success line printed `<new>..<new>`, reusing the new SHA for the old one, so
  a force-push and a normal push looked identical.

### `gitz log` (fixed here)

`log` was only correct with no arguments. Every other form was broken, and the
numbers were misleading rather than obviously wrong:

- `gitz log <rev>` did not resolve revisions at all. It demanded a raw SHA, so
  `gitz log main`, `gitz log origin/main` and `gitz log HEAD~2` all reported
  "bad revision" -- and then crashed, because the string had already been freed.
- Clearing the positional list with `pathspecs.items = &.{}` replaced the
  list's *buffer pointer* with a static empty slice, so its own teardown freed a
  pointer that never came from the allocator. That is the general protection
  exception, and it is why the "23 commits" this reported were rows of
  replacement characters rather than commits.
- A revision argument was routed to the `log show` path, printing **one** commit
  where `git log <rev>` lists the history from that point. `log show <rev>` is
  a separate subcommand and still does that.
- The walk followed only `parents[0]`, which is first-parent: everything behind
  a merge was invisible.
- `--all` listed only `refs/heads/*`, so a freshly fetched repository -- which
  has `refs/remotes/origin/*` and no local branch -- printed nothing.
- Walking each ref separately printed shared history once per ref: 106 lines
  for a 51 commit repository.
- `--skip=3` was never read, because `--grep=` and `--max-count=` accepted the
  attached form and `--skip` did not.
- `~N` asked for the *second* parent and `^N` indexed parents from 1 instead of
  from 0, so every one of them reported "bad revision" on a history with no
  merge commits.

Ordering is now topological with a newest-first priority among the commits that
are ready, which is git's rule: a commit is never printed before something that
descends from it. Sorting on the timestamp alone would print a parent ahead of
its child. Among commits with the *same* timestamp the tie may break differently
than git does; both orders are valid, and the set is identical.

Verified identical to git on the real 51 commit history -- set, order, `--all`,
`-5`, `--skip=3`, `--reverse`, `--author`, `--grep` and a pathspec -- and on a
synthetic repository with merges, a tag and a deletion.

## Phase 5 -- Worktrees (phases 0-3 done) & Multi-Agent (phase 4 not started)

### The idea

Several agents working one repository today need one checkout each, and git
gives a repository a single `HEAD` and a single `index`. `gitz worktree`
removes that limit: each worktree has its own `HEAD`, its own `index` and its own
working tree, all sharing one object store and one set of refs.

This is not a new concept so much as the **other half of `clone --shared`**,
which is where Phase 4 left off:

|                    | objects  | refs      | HEAD + index |
|--------------------|----------|-----------|--------------|
| `clone --shared`   | shared   | separate  | separate     |
| `worktree`         | shared   | **shared**| **separate** |

Today an agent that wants its own branch runs `gitz clone --shared ../base`.
Objects are shared, but each clone has its own refs, so **no agent sees another
agent's commits**. That is the only thing left to solve, and it is exactly what
worktrees do.

### On-disk format (git-compatible, not a GitZ invention)

```
main checkout/              agent-a/                 .gitz/worktrees/
  .gitz/                      .git  <- a file:        agent-a/
    HEAD                        gitdir: .../.../        HEAD      (private)
    index                       agent-a/.git          index     (private)
    objects/, refs/                                  commondir  ("../..")
    worktrees/                                       gitdir    (abs path back)
      agent-a/                                       ORIG_HEAD, MERGE_HEAD,
                                                    logs/HEAD, rebase-merge/
```

`commondir` is the only new concept to understand: it resolves the shared
directory from inside any worktree. The main worktree has no `commondir` file,
because there the common dir *is* the worktree dir.

Real git must be able to open a GitZ-created worktree and vice versa, so the
format is fixed to git's, not a GitZ dialect.

### Phase 0 -- the `Repo` refactor (done)

`src/core/repo.zig` splits what used to be a single `git_dir` string in three.

```zig
pub const Repo = struct {
    common_dir:   []const u8,  // objects/, refs/, config, packed-refs
    worktree_dir: []const u8,  // HEAD, index, ORIG_HEAD, MERGE_HEAD, rebase-merge/
    worktree_path: []const u8, // root of the checked-out files
    subdir_prefix: []const u8, // cwd relative to worktree_path (already exists)
};
```

| today                                            | becomes        |
|--------------------------------------------------|----------------|
| `alternates.zig` `{git_dir}/objects/info/...`    | `common_dir`   |
| `index.zig` `{git_dir}/index`                    | `worktree_dir` |
| `refs.zig` `HEAD` reads                          | `worktree_dir` |
| `moveToWorktreeRoot` chdir (`cli/mod.zig`)       | `worktree_path`|
| ~53 `{git_dir}/{path}` working-tree writes        | `worktree_path`|

Resolution order, honouring `GIT_DIR`:

- `GIT_DIR` set -> it is the **worktree_dir**; common comes from `commondir`
- `.gitz/` or `.git/` directory -> common = worktree = that directory
- `.git` file -> `gitdir:` is the worktree_dir, `commondir` gives the common
  dir, and the directory holding the `.git` file is the worktree path

Resolution of *which* directory a ref lives in is now done in one place,
`Refs.isPerWorktree`: `HEAD` and the pseudo-refs beside it, plus `refs/bisect/*`,
are private; every other ref is shared. That single rule is what makes two
worktrees see each other's commits while keeping their own `HEAD`.

The migration was made structurally unavoidable rather than optional: the core
constructors (`Refs.init`, `StorageBackend.fromRepoConfig`, `Index.readFromFile`,
`checkout.checkoutCommit`, the transports) take a `Repo` instead of a
`[]const u8`, so the compiler pointed at all ~63 call sites and a wrong choice
could not compile. For a repository with no worktrees the three directories
coincide, so behaviour is unchanged.

**Exit criterion, met:** `zig build test` passes unchanged.

### Phase 1-2 -- `gitz worktree` (done)

`src/cli/commands/worktree.zig` implements `add` (`-b`, `--detach`, explicit
path), `list` (+`--porcelain`), `remove` (`--force`), `prune`, `move`,
`lock`/`unlock` and `repair`.

Git refuses to check out one branch in two worktrees at once, and that check is
replicated rather than reinvented -- agents hit it constantly.

Two rules had to be added to the rest of the tree, because a worktree's files are
physically inside its parent when it is nested:

- a directory holding a `.gitz`/`.git` **file** is a linked worktree, and both
  `gitz status` and `gitz add .` skip it. Without this the main worktree listed
  every worktree's files as untracked and staged them into its own index.
- a worktree's own `.gitz` indirection file is bookkeeping, not user work, so it
  is not reported as untracked.

### Phase 4 -- the agent layer (not started)

```bash
gitz agent spawn fixer develop        # worktree + branch + binding in one step
gitz agent list                       # agent -> branch -> worktree
gitz worktree exec fixer -- pytest    # GIT_DIR + cwd pointed at the worktree
gitz agent cleanup                    # drop worktrees of dead agents
```

- Agent metadata lives in `.gitz/worktrees/<name>/gitz-agent`, a GitZ-owned file
  that git safely ignores.
- Binding resolution: `GITZ_WORKTREE` > metadata of the current worktree > cwd.
- `worktree exec` is the load-bearing piece: by setting `GIT_DIR` and the working
  directory, *real git* and any third-party agent tool also run correctly inside
  an agent's worktree.
- Git copies the whole working tree per worktree. With shared objects and mmap,
  GitZ worktrees are close to free -- that is the real differentiation.

### Risks, and how each is answered

**1. `gc` and reachability (data loss -- the serious one). RESOLVED, and it was
real.**

`gc` took its roots from one `git_dir` only: every ref, `packed-refs`, the three
pseudo-refs `HEAD`/`ORIG_HEAD`/`MERGE_HEAD` and the index. With worktrees, an
agent's `HEAD` and its staged-but-uncommitted blobs live in
`.gitz/worktrees/<name>/`. This was **not** theoretical: reproduced on a detached
worktree, where `gitz gc` from the main worktree pruned the worktree's commit,
its staged blob and the blob staged-but-differing-from-disk. Same bug class as
the already-fixed "walked only `heads` and `tags`".

*What was implemented (`markWorktreeRoots` in `gc.zig`):*

- every worktree under `common_dir/worktrees/*` contributes its own
  pseudo-refs (`HEAD`, `ORIG_HEAD`, `MERGE_HEAD`, `MERGE_AUTOSTASH`,
  `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `BISECT_HEAD`, `AUTO_MERGE`, `FETCH_HEAD`),
  its `index`, and its `rebase-merge`/`rebase-apply` `orig-head` and `onto`
- the main worktree is included, so the same code path serves both
- a stale worktree keeps its objects alive until `gitz worktree prune` removes
  the admin directory, which is what makes `prune` meaningful
- the `incomplete` bail-out is unchanged: if any root cannot be read, nothing is
  pruned at all

Verified in both directions: a detached worktree's commit and staged blob
survive `gitz gc` from the main worktree; after `remove` + `prune` the same
objects do become collectable; and `gitz gc` still prunes genuinely dead
objects.

**2. The index must stay dircache v2 compatible.**

Two implementations will write the same file, so the format is fixed. `index.zig`
already writes a real trailer, the flags word and 8-byte padding, and the comment
at `index.zig:263-318` records the exact git 2.55 offsets. Worktrees add no new
pressure here -- the rule is simply that `worktree_dir` changes, never the
encoding. The differential suite must cover a worktree index written by GitZ
and read by real git.

**3. `worktree list` output must match git's porcelain.**

Any tool that parses it breaks on a near-miss. One field is already known to be
required beyond the obvious: git reports `prunable` / `locked` as a reason
suffix, and a bare `gitz worktree list` that omits them will not round-trip.
Covered by a byte-for-byte differential test against `git worktree list`.

**4. Found while assessing risk 1, and it existed with no worktrees involved.
PARTIALLY FIXED.**

GitZ wrote **no `ORIG_HEAD` and no reflog at all** (no `logs/HEAD` writer exists
anywhere in `src/`). `gc` already listed `ORIG_HEAD` as a root, but nothing ever
created it. So:

```
gitz reset --hard <old>   # or gitz undo
gitz gc                   # <old> is unreachable -> deleted, with no reflog to recover from
```

`ORIG_HEAD` is now written by `reset` and `undo` before the ref moves, so the
commit a reset discarded stays reachable and recoverable with
`gitz reset --hard $(cat .gitz/ORIG_HEAD)`. Verified with real git reading
`.gitz/`.

**Still open:** there is no reflog, so `ORIG_HEAD` only remembers the *last*
move. Three resets in a row and only the most recent one is recoverable. A real
reflog is a separate piece of work, not part of this phase.

### Test strategy

`src/tests/e2e/differential.zig`, against real git. Verified manually against
git 2.55 during implementation; still to be written as permanent tests:

- gitz creates a worktree -> `git worktree list` agrees (**done**, matches
  including the `(detached HEAD)` form and short SHAs)
- git creates a worktree -> the full gitz command set works inside it
  (**done**: status, add, commit, log, and `gitz worktree list` all correct)
- **independent HEADs, shared refs**: a commit in one is visible to the other
  via `log --all` (**done**)
- **index isolation**: staging different files in each does not cross over
  (**done**)
- a detached worktree's commit and staged blob survive `gitz gc` from the main
  worktree, and become collectable after `remove` + `prune` (**done**)
- `git worktree remove` cleans up a GitZ-created worktree

*Last updated: September 2026*

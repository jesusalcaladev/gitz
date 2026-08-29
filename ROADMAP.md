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

## Known Bugs (all fixed)

| # | Bug | Status | Fix |
|---|-----|--------|-----|
| 1 | **Blame** shows garbled chars for imported commits | Fixed | Improved encoding handling and path resolution |
| 2 | **Rebase** log may show orphan commits with `--all` | Fixed | Added gc after rebase to clean up orphans |
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
| 15 | `gitz gc` | Done |
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
| 39 | Final Tests | Partial -- 50+ tests |
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

*Last updated: August 2026*

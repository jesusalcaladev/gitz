# GitZ Specification

> **"Git, but faster. Every command. Every repo."**

---

## 1. What is GitZ?

GitZ is a drop-in replacement for Git, written in Zig. It is 100% compatible with the existing Git ecosystem — you can clone from GitHub, push to GitLab, and no server or user will notice the difference.

### Why does GitZ exist?

Git was designed in 2005 by Linus Torvalds to replace BitKeeper for Linux kernel development. Its distributed nature was perfect for that use case. Twenty years later, the vast majority of Git usage is centralized — everyone pushes to GitHub, GitLab, or Bitbucket. The distributed model is more of an obstacle than a feature.

GitZ keeps everything that makes Git great (the object model, the packfile format, the wire protocol) and fixes what doesn't work:

| Problem | Git | GitZ |
|---|---|---|
| 150+ commands, ambiguous names | `git checkout` does 3 things | `gitz switch`, `gitz reset` — one purpose each |
| Push rejected by default | Manual `git pull --rebase` | `gitz pull` does rebase by default |
| Rebase interactively = Vim | Unusable for most developers | TUI with arrow keys and confirmations |
| Status doesn't show ahead/behind | Must run `git status -b` | Always shown on every `gitz status` |
| No smart sync | Must remember fetch+rebase sequence | `gitz sync` does everything |
| No built-in undo | `git reset --hard` = lose work | `gitz undo` creates inverse commit |
| No code review | Need external tools | `gitz review` built-in |
| No content search | `git grep` is limited | `gitz search` with regex and context |

### Design Principles

1. **Compatibility first**: Every object, every packfile, every protocol packet is identical to Git. A server cannot distinguish a `gitz push` from a `git push`.

2. **Sane defaults**: `gitz pull` rebases. `gitz push` uses `--force-with-lease`. `gitz checkout` doesn't exist (use `gitz switch`).

3. **Performance**: Zig gives us C-level speed with better ergonomics. We use zstd instead of zlib, mmap for object reads, parallelism for blame/diff, and in-memory DAG caches.

4. **Single binary**: `gitz` is one statically-linked binary. No runtime dependencies. No Node.js. No Python. Cross-compile with `zig build`.

5. **Dogfooding**: GitZ uses itself for version control. If we can't eat our own dog food, the product is broken.

---

## 2. Compatibility Model

### 2.1 Object Format

GitZ uses the **exact same object format as Git**:

```
<type> <size>\0<content>
```

Where `type` is one of: `blob`, `tree`, `commit`, `tag`.

The SHA-1 hash is computed over this entire buffer (header + NUL + content). This is identical to how `git hash-object` works.

### 2.2 Packfiles

GitZ reads and writes Git packfiles. When pushing to a Git server, GitZ constructs a packfile in the standard format:

```
PACK                                    # Magic bytes
00000002                                # Version 2
XXXXXXXX                                # Number of objects
<objects...>                            # Object data (with delta compression)
<20-byte checksum>                      # SHA-1 of entire pack
```

When receiving packfiles (clone, fetch), GitZ parses them including delta chains (OFS_DELTA and REF_DELTA).

### 2.3 Wire Protocol

GitZ implements Git Protocol v2 over Smart HTTP. The flow is:

```
1. Client sends HTTP POST to /<repo>.git/info/refs?service=git-upload-pack
2. Server responds with capabilities and refs
3. Client sends want/have lines
4. Server sends packfile stream (multiplexed via sideband)
```

GitZ sends `User-Agent: git/2.45.0` for maximum compatibility with servers that filter by client version.

### 2.4 Refs

Standard Git ref layout:

```
.gitz/
├── HEAD                          # "ref: refs/heads/main\n"
├── config                        # Repository configuration
├── refs/
│   ├── heads/                    # Local branches
│   │   └── main                  # SHA of branch tip
│   ├── tags/                     # Tags
│   │   └── v1.0                  # SHA of tag
│   └── stash                     # Stash ref
├── packed-refs                   # Optimized ref storage
├── objects/                      # Object storage
│   ├── pack/                     # Packfiles
│   └── XX/YYYY...                # Loose objects
├── index                         # Staging area
├── info/
│   └── exclude                   # Global ignore patterns
└── refs/remotes/                 # Remote-tracking branches
    └── origin/
        └── main
```

### 2.5 .gitignore

GitZ reads `.gitignore` files with the same syntax as Git:

- `*.o` — ignore all .o files
- `build/` — ignore directories named build
- `/foo` — ignore only at root
- `!important.o` — negate (don't ignore)
- `**/temp` — match at any depth

---

## 3. Architecture

### 3.1 Project Structure

```
gitz/
├── build.zig                     # Build system
├── build.zig.zon                 # Dependencies
├── src/
│   ├── main.zig                  # Entry point, CLI dispatcher
│   │
│   ├── cli/
│   │   ├── mod.zig               # CLI module root
│   │   ├── parser.zig            # Argument parser
│   │   ├── printer.zig           # Colored output
│   │   └── commands/
│   │       ├── init.zig          # gitz init
│   │       ├── add.zig           # gitz add
│   │       ├── commit.zig        # gitz commit
│   │       ├── status.zig        # gitz status
│   │       ├── diff.zig          # gitz diff
│   │       ├── log.zig           # gitz log
│   │       ├── branch.zig        # gitz branch
│   │       ├── switch.zig        # gitz switch
│   │       ├── merge.zig         # gitz merge
│   │       ├── stash.zig         # gitz stash
│   │       ├── tag.zig           # gitz tag
│   │       ├── reset.zig         # gitz reset
│   │       ├── remote.zig        # gitz remote
│   │       ├── fetch.zig         # gitz fetch (Fase 2)
│   │       ├── clone.zig         # gitz clone (Fase 2)
│   │       ├── push.zig          # gitz push (Fase 2)
│   │       └── pull.zig          # gitz pull (Fase 2)
│   │
│   ├── core/
│   │   ├── mod.zig               # Core module root
│   │   ├── sha1.zig              # SHA-1 implementation
│   │   ├── object.zig            # Git objects (blob, tree, commit, tag)
│   │   ├── loose.zig             # Loose object store
│   │   ├── pack.zig              # Packfile reader/writer
│   │   ├── refs.zig              # Reference management
│   │   ├── index.zig             # Staging area
│   │   ├── ignore.zig            # .gitignore parser
│   │   ├── diff.zig              # Diff algorithm (Myers)
│   │   ├── merge.zig             # 3-way merge engine
│   │   ├── rebase.zig            # Rebase engine
│   │   ├── worktree.zig          # Working tree operations
│   │   └── config.zig            # Repository config
│   │
│   ├── transport/                # Fase 2
│   │   ├── mod.zig
│   │   ├── protocol.zig          # Git wire protocol v2
│   │   ├── packet_line.zig       # Packet-line format
│   │   ├── smart_http.zig        # Smart HTTP client
│   │   ├── ssh.zig               # SSH transport
│   │   └── pack_transfer.zig     # Pack negotiation
│   │
│   ├── server/                   # Fase 3
│   │   ├── mod.zig
│   │   ├── git_daemon.zig
│   │   ├── http_api.zig
│   │   ├── auth.zig
│   │   └── repo_manager.zig
│   │
│   └── util/
│       ├── fs.zig                # Filesystem helpers
│       ├── compression.zig       # zlib/zstd wrappers
│       ├── mmap.zig              # Memory-mapped I/O
│       ├── path.zig              # Path manipulation
│       └── temp.zig              # Temporary files
│
├── tests/
│   ├── integration/              # Integration tests
│   └── unit/                     # Unit tests
│
├── docs/
│   ├── spec.md                   # This document
│   ├── commands.md               # Command reference
│   └── protocol.md               # Wire protocol notes
│
└── web/                          # Fase 3: Web UI
    ├── index.html
    ├── app.js
    └── style.css
```

### 3.2 Module Dependency Graph

```
main.zig
  └── cli/mod.zig
        ├── cli/parser.zig
        ├── cli/printer.zig
        └── cli/commands/*.zig
              └── core/*.zig
                    └── util/*.zig
```

Key rule: **CLI never imports another CLI module.** Core never imports CLI. Transport never imports core (it receives/writes raw bytes). Clean separation.

### 3.3 Memory Management

Zig gives us manual memory control. Strategy:

- **Arena allocator** per command execution: allocate everything, free everything at the end
- **GeneralPurposeAllocator** for long-lived data (object cache, DAG)
- **No GC, no reference counting** — deterministic destruction via `defer`

```zig
// Every command starts with an arena
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const allocator = arena.allocator();
```

### 3.4 Error Handling

Zig uses error unions. Every fallible operation returns `!Type`. We use `try` for propagation and handle errors at the CLI layer with user-friendly messages:

```zig
// Core returns typed errors
pub fn readObject(sha: [20]u8) !GitObject { ... }

// CLI catches and prints
const obj = loose.read(sha) catch |err| switch (err) {
    error.ObjectNotFound => {
        try printer.err("fatal: object {s} not found", .{sha_hex});
        std.process.exit(128);
    },
    else => return err,
};
```

---

## 4. Command Reference

### 4.1 Init & Config

```bash
gitz init [directory]         # Create new repository
gitz init --bare             # Create bare repository (no working tree)
gitz config set <key> <val>  # Set config value
gitz config get <key>        # Get config value
gitz config --list           # List all config
```

### 4.2 Staging & Committing

```bash
gitz add <paths...>          # Stage files
gitz add .                   # Stage everything (respecting .gitignore)
gitz add -p                  # Stage interactively by hunk
gitz status                  # Show working tree status
gitz status --short          # Compact output
gitz commit -m "message"     # Commit staged changes
gitz commit -am "message"    # Auto-stage tracked + commit
gitz commit --amend          # Amend last commit
gitz diff                    # Working tree vs index
gitz diff --staged           # Index vs HEAD
gitz diff HEAD               # Working tree vs HEAD
gitz diff main..feature      # Between branches
```

### 4.3 Branching & Switching

```bash
gitz branch                  # List branches
gitz branch <name>           # Create branch from HEAD
gitz branch -d <name>        # Delete branch (safe)
gitz branch -D <name>        # Delete branch (force)
gitz switch <branch>         # Switch to branch
gitz switch -c <branch>      # Create and switch
gitz switch --               # Switch to previous branch
```

### 4.4 Merging & Rebasing

```bash
gitz merge <branch>          # Merge (fast-forward by default)
gitz merge --no-ff <branch>  # Force merge commit
gitz merge --squash <branch> # Squash merge
gitz rebase <branch>         # Rebase onto branch
gitz rebase -i <branch>      # Interactive rebase (TUI)
gitz rebase --abort          # Abort rebase
```

### 4.5 History

```bash
gitz log                     # Commit history
gitz log --oneline           # One line per commit
gitz log --graph             # ASCII graph
gitz log --all               # All branches
gitz log -n 10               # Last 10 commits
gitz log --author="name"     # Filter by author
gitz log --grep="text"       # Filter by message
gitz log --follow <file>     # Follow renames
gitz show <commit>           # Show commit details
gitz blame <file>            # Who changed each line
```

### 4.6 Stash

```bash
gitz stash                   # Stash working + staged changes
gitz stash push -m "msg"     # Stash with message
gitz stash list              # List stashes
gitz stash pop               # Apply and remove
gitz stash apply             # Apply without removing
gitz stash drop <ref>        # Remove stash
gitz stash show -p           # Show stash diff
```

### 4.7 Tags

```bash
gitz tag                     # List tags
gitz tag <name>              # Create lightweight tag
gitz tag -a <name> -m "msg"  # Create annotated tag
gitz tag -d <name>           # Delete tag
```

### 4.8 Remotes (Fase 2)

```bash
gitz remote add <name> <url>
gitz remote remove <name>
gitz remote -v
gitz fetch                   # Fetch from remote
gitz pull                    # Fetch + rebase (default!)
gitz push                    # Push upstream
gitz clone <url>             # Clone repository
```

### 4.9 New Commands

```bash
gitz undo                    # Undo last commit (creates inverse commit)
gitz undo --soft             # Undo, keep changes staged
gitz sync                    # Fetch + auto-rebase (always works)
gitz search "text"           # Search file contents
```

---

## 5. Roadmap

### Phase 1: Core (Weeks 1-8)

**Goal**: Local Git-compatible client. You can init repos, add/commit files, branch, merge, stash, view history.

| Week | Deliverable | Files |
|---|---|---|
| 1 | SHA-1, git objects, loose store | `sha1.zig`, `object.zig`, `loose.zig` |
| 2 | Packfiles, refs | `pack.zig`, `refs.zig` |
| 3 | Index, .gitignore | `index.zig`, `ignore.zig` |
| 4 | CLI + init/add/commit | `parser.zig`, `init.zig`, `add.zig`, `commit.zig` |
| 5 | Working tree, status | `worktree.zig`, `status.zig` |
| 6 | Diff, merge | `diff.zig`, `merge.zig` |
| 7 | branch, switch, merge, log, stash | 5 command files |
| 8 | tag, reset, undo, gc + tests | Remaining commands + test suite |

**Exit criteria**: `gitz init && gitz add . && gitz commit -m "first" && gitz log` works. `git init && git add . && git commit` produces identical objects.

### Phase 2: Transport (Weeks 9-14)

**Goal**: Clone from and push to GitHub/GitLab/Bitbucket.

| Week | Deliverable | Files |
|---|---|---|
| 9 | Wire protocol v2, packet-line | `protocol.zig`, `packet_line.zig` |
| 10 | Smart HTTP, pack negotiation | `smart_http.zig`, `pack_transfer.zig` |
| 11 | Fetch, clone | `fetch.zig`, `clone.zig` |
| 12 | Push, pull | `push.zig`, `pull.zig` |
| 13 | SSH transport, remote config | `ssh.zig`, `remote.zig` |
| 14 | Compatibility tests | `git_compat_test.zig` |

**Exit criteria**: `gitz clone https://github.com/octocat/Hello-World` works. `gitz push origin main` pushes to a real GitHub repo.

### Phase 3: Server (Weeks 15-22)

**Goal**: Self-hosted Git server with web UI.

| Week | Deliverable |
|---|---|
| 15-16 | Object store (sharded, SQLite index, DAG cache) |
| 17-18 | Git daemon, HTTP API, auth |
| 19-20 | Repo management, web UI |
| 21-22 | CI engine |

### Phase 4: Developer Experience (Weeks 23-26)

**Goal**: UX that makes Git feel outdated.

| Week | Deliverable |
|---|---|
| 23 | Interactive rebase TUI |
| 24 | Code review system, smart sync |
| 25 | Search engine, undo system |
| 26 | Documentation, benchmarks, release |

### v1.0 Stable Release Criteria

- [ ] All Phase 1 commands work with 100% Git object compatibility
- [ ] Phase 2: clone/push/fetch work against GitHub, GitLab, Bitbucket
- [ ] Phase 2: SSH transport works
- [ ] `git` can read repos created by `gitz` (bidirectional compatibility)
- [ ] 90%+ test coverage on core modules
- [ ] Cross-platform: Linux x86_64, macOS arm64, Windows x86_64
- [ ] Single static binary, no runtime dependencies
- [ ] Documentation for all commands
- [ ] Benchmark: `gitz status` 5x faster than `git status` on 100k files
- [ ] Benchmark: `gitz log` 3x faster than `git log`

### v2.0 Goals

- Server mode (`gitz serve`)
- Web UI (embedded, no external dependencies)
- Code review (`gitz review`)
- CI/CD engine
- Git LFS support

---

## 6. Testing Strategy

### Unit Tests

Every module has a `_test.zig` file. Tests are colocated with source using Zig's `test` blocks:

```zig
// src/core/sha1.zig

test "sha1 empty string" {
    const result = Sha1.hash("");
    try std.testing.expectEqualStrings(
        "da39a3ee5e6b4b0d3255bfef95601890afd80709",
        &std.fmt.bytesToHex(result, .lower),
    );
}
```

### Integration Tests

Tests that exercise multiple modules together:

```zig
// tests/integration/commit_test.zig

test "full commit workflow" {
    // 1. Init repo
    // 2. Create file
    // 3. Add to index
    // 4. Commit
    // 5. Verify: HEAD points to commit, commit has correct tree, tree has correct blob
}
```

### Compatibility Tests

Tests that verify `gitz` output is readable by `git`:

```zig
// tests/integration/git_compat_test.zig

test "git can read gitz commit" {
    // 1. gitz init + add + commit
    // 2. Run: git log --oneline
    // 3. Verify: commit appears in output
}
```

### Running Tests

```bash
zig build test              # All tests
zig build test-unit         # Unit tests only
zig build test-integration  # Integration tests only
```

---

## 7. Configuration

### Repository Config (.gitz/config)

```ini
[core]
    repositoryformatversion = 0
    filemode = true
    bare = false
    logallrefupdates = true
    autocrlf = input

[user]
    name = Your Name
    email = you@example.com

[remote "origin"]
    url = https://github.com/user/repo.git
    fetch = +refs/heads/*:refs/remotes/origin/*

[branch "main"]
    remote = origin
    merge = refs/heads/main
```

### Global Config (~/.gitzconfig)

```ini
[user]
    name = Your Name
    email = you@example.com

[core]
    editor = vim
    autocrlf = input

[init]
    defaultBranch = main
```

---

## 8. Performance Targets

| Operation | Git (baseline) | GitZ target | Technique |
|---|---|---|---|
| `status` (100k files) | ~2s | <200ms | mmap, parallel stat, bloom filter |
| `log -20` | ~50ms | <10ms | In-memory commit graph cache |
| `diff main..feature` | ~500ms | <100ms | Parallel diff, lazy loading |
| `blame` (10k lines) | ~200ms | <30ms | Parallel blame, cached parents |
| `commit` | ~100ms | <20ms | Direct object write, no index rebuild |
| `clone` (1GB repo) | ~5min | ~2min | zstd compression, parallel fetch |
| `push` (100MB) | ~30s | ~15s | zstd, parallel packing |

---

## 9. Naming Conventions

### Binary

- `gitz` — main binary

### Directory

- `.gitz/` — repository data (equivalent to `.git/`)

### File Extensions

- No extensions for Zig source files (Zig convention)
- `.md` for documentation
- `.toml` for configuration

### Code Style

Follow Zig standard style:
- 4 spaces indentation
- snake_case for variables and functions
- PascalCase for types
- `pub` for public API
- `_` prefix for unused parameters

### Git Object Compatibility

- SHA-1 for all objects (not SHA-256) — for maximum compatibility
- Standard object headers: `blob <size>\0`, `tree <size>\0`, etc.
- Standard packfile format v2

---

## 10. FAQ

**Q: Why not use JGit, libgit2, or go-git?**
A: We want zero dependencies and full control over performance. Zig compiles to a single static binary with no runtime. libgit2 requires C linking. JGit requires a JVM. go-git requires a Go runtime.

**Q: Why SHA-1 and not SHA-256?**
A: SHA-256 support exists in Git but most servers don't fully support it yet. SHA-1 ensures compatibility with every Git server in existence. We can add SHA-256 later.

**Q: Can I use Git and GitZ on the same repo?**
A: Yes. They share the same object format, packfiles, and refs. Switch between them freely.

**Q: Does GitZ support submodules?**
A: Not yet. Submodules are a known pain point. We plan a better dependency system in v2.0.

**Q: What about Git LFS?**
A: Not in Phase 1. LFS support is planned for v2.0.

**Q: Is the CLI 100% compatible with Git's CLI?**
A: No. We deliberately changed some commands (checkout → switch, pull default → rebase). We provide a `--git-compat` flag for scripts that need exact Git behavior.

**Q: How do I install GitZ?**
A: Download the single binary for your platform. No package manager needed. Or build from source: `zig build -Doptimize=ReleaseFast`.

---

*Spec version: 0.1.0 — August 2026*

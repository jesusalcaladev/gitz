# 🔮 GitZ

**Git, but faster. A drop-in replacement for git written in Zig.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16-orange.svg)](https://ziglang.org)
[![Platform](https://img.shields.io/badge/Platform-Linux-brightgreen.svg)](README.md)

---

## ⚡ Features

- **Full local workflow** — init, add, commit, status, diff, log, branch, merge, rebase, stash, reset, tag, blame, gc
- **Developer experience** — search, review, show, clean, shortlog, worktree, pack-refs
- **SSH clone from GitHub** — `gitz clone git@github.com:user/repo.git`
- **Bidirectional compatibility** — git can read gitz objects and vice versa
- **Respects .gitignore** — full parser with `!`, `**`, `*`, `?` support
- **Colored diff** — ANSI colors for added/removed lines
- **Interactive rebase** — `gitz rebase -i` with pick/squash/drop menu
- **Pluggable storage backend** — loose objects or sharded directories, configurable per-repo
- **Shard store for horizontal scaling** — distribute objects across N shards by SHA prefix
- **Monorepo support** — auto-detect parent `.gitz` across directory tree + worktrees
- **Written in Zig** — single binary, no dependencies, blazing fast

## 🚀 Quick Start

### One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/jesusalcaladev/gitz/main/install.sh | bash
```

### Manual install

```bash
# Clone the repository
git clone git@github.com:jesusalcaladev/gitz.git
cd gitz

# Build with Zig
zig build

# Install globally
mkdir -p ~/.local/bin
cp zig-out/bin/gitz ~/.local/bin/gzig

# Or add to PATH
e export PATH="$HOME/.local/bin:\$PATH"

# The binary is at zig-out/bin/gitz
./zig-out/bin/gitz --version
```

### Requirements

- **Linux** (x86_64, aarch64) or **macOS** (x86_64, aarch64)
- **Zig 0.16+** (auto-installed by install script)
- **git** (optional, for SSH clone/push)

### Usage

```bash
# Initialize a repo
gitz init

# Stage and commit
gitz add .
gitz commit -m "Initial commit"

# Check status
gitz status

# View history
gitz log --oneline
gitz log --graph --all

# Branch operations
gitz branch feature
gitz switch feature
gitz switch main
gitz branch -d feature

# Diff
gitz diff
gitz diff --staged

# Clone from GitHub
gitz clone git@github.com:user/repo.git

# Remote operations
gitz remote add origin git@github.com:user/repo.git
gitz push origin main
gitz pull
```

## 📦 Commands Reference

### Local Commands (17)

| Command | Description |
|---------|-------------|
| `gitz init` | Initialize a new repository |
| `gitz add <files>` | Stage files for commit (respects .gitignore, progress bar) |
| `gitz commit -m "msg"` | Record changes. Use `-a` to auto-stage, `--amend` to edit |
| `gitz status` | Show staged, unstaged, and untracked files (color-coded) |
| `gitz diff` | Show changes. Use `--staged`, or `gitz diff main..feature` |
| `gitz log` | Show history. Use `--graph`, `--all`, `-n`, `--author`, `--grep` |
| `gitz branch` | List/create branches. Use `-d`/`-D` to delete, `-m` to rename |
| `gitz switch` | Switch branches. Use `-c` to create and switch |
| `gitz merge` | Merge branches. Use `--no-ff` for merge commit |
| `gitz rebase` | Rebase current branch. Use `--onto`, `--abort`, `-i` for interactive |
| `gitz stash` | Stash changes. Use `push`, `pop`, `apply`, `list`, `drop`, `show` |
| `gitz reset` | Reset HEAD. Use `--soft`, `--mixed`, `--hard` |
| `gitz undo` | Undo last commit (creates inverse commit) |
| `gitz tag` | Create/list tags. Use `-a` for annotated, `-d` to delete |
| `gitz blame` | Show per-line author history |
| `gitz gc` | Clean up unreachable objects |
| `gitz config` | Get/set user.name and user.email |

### DX Commands (7)

| Command | Description |
|---------|-------------|
| `gitz search <pattern>` | Search file contents and commit messages |
| `gitz review [base] [target]` | Code review between branches with inline diff |
| `gitz show [commit]` | Show commit details and diff |
| `gitz clean` | Remove untracked files. Use `-f`, `-n`, `-fd`, `-fdx` |
| `gitz shortlog` | Summarize commits by author. Use `-s`, `-n`, `-e` |
| `gitz worktree` | Manage multiple working trees (add/list/remove/prune) |
| `gitz pack-refs` | Compact loose refs into packed-refs |

### Remote Commands (6)

| Command | Description |
|---------|-------------|
| `gitz clone <url>` | Clone a repository (SSH + HTTP, `--depth` support) |
| `gitz fetch` | Download objects and refs from remote |
| `gitz push` | Upload local objects to remote |
| `gitz pull` | Fetch and rebase from remote |
| `gitz remote` | Manage remotes (add, remove, list, set-url) |
| `gitz sync` | Fetch + rebase + push in one step |

## 🧪 Testing

```bash
# Run all tests
zig build test

# Run specific test
zig build test -- --test-filter "sha1"
```

## 🏗️ Architecture

```
src/
├── main.zig                  # Entry point + comptime module registration
├── cli/
│   ├── mod.zig               # Command dispatch + findGitDir (parent .gitz detection)
│   ├── parser.zig            # Argument parser
│   └── commands/             # 30 command implementations
│       │
│       │  ── Local Commands ──
│       ├── init.zig          # gitz init (--bare)
│       ├── add.zig           # gitz add (progress bar, .gitignore support)
│       ├── commit.zig        # gitz commit (-m, -a, --amend)
│       ├── status.zig        # gitz status (color-coded: green/yellow/red)
│       ├── diff.zig          # gitz diff (LCS, --staged, branch..branch)
│       ├── log.zig           # gitz log (--oneline, --graph, --all, --author)
│       ├── branch.zig        # gitz branch (-d, -D, -m)
│       ├── switch.zig        # gitz switch (-c)
│       ├── merge.zig         # gitz merge (--no-ff)
│       ├── rebase.zig        # gitz rebase (interactive TUI, --onto, --abort)
│       ├── stash.zig         # gitz stash (push/pop/apply/list/drop/show)
│       ├── reset.zig         # gitz reset (--soft/--mixed/--hard)
│       ├── undo.zig          # gitz undo
│       ├── tag.zig           # gitz tag (-a, -d)
│       ├── blame.zig         # gitz blame (with encoding sanitization)
│       ├── gc.zig            # gitz gc
│       ├── config.zig        # gitz config (user.name/email)
│       │
│       │  ── DX Commands ──
│       ├── search.zig        # gitz search (file content + commit messages)
│       ├── review.zig        # gitz review (branch diff + inline stats)
│       ├── show.zig          # gitz show (commit details + diff)
│       ├── clean.zig         # gitz clean (-n/-f/-fd/-fdx)
│       ├── shortlog.zig      # gitz shortlog (-s/-n/-e)
│       ├── worktree.zig      # gitz worktree (add/list/remove/prune)
│       ├── pack_refs.zig     # gitz pack-refs
│       │
│       │  ── Remote Commands ──
│       ├── clone.zig         # gitz clone (--depth, SSH/HTTP, progress phases)
│       ├── fetch.zig         # gitz fetch
│       ├── push.zig          # gitz push (--force)
│       ├── pull.zig          # gitz pull (--rebase)
│       ├── remote.zig        # gitz remote (add/remove/list/set-url)
│       └── sync.zig          # gitz sync (fetch+rebase+push)
│
├── core/                     # Git object model + storage (22 modules)
│   │
│   │  ── Hashing & Compression ──
│   ├── sha1.zig              # SHA-1 hashing
│   ├── zlib.zig              # Zlib compression/decompression
│   │
│   │  ── Git Objects ──
│   ├── object.zig            # Git objects (blob, tree, commit, tag)
│   ├── loose.zig             # Loose object store (read/write)
│   ├── index.zig             # Staging area (.gitz/index)
│   ├── refs.zig              # Reference system (HEAD, branches, packed-refs)
│   │
│   │  ── Diff & Merge ──
│   ├── diff.zig              # LCS diff algorithm + colored output
│   ├── merge.zig             # 3-way merge
│   ├── stash.zig             # Stash management
│   │
│   │  ── Packfile Layer ──
│   ├── packfile.zig          # Packfile reader/writer (v2, topological sort)
│   ├── packindex.zig         # Pack index O(log n) binary search
│   ├── delta.zig             # Delta resolution (ofs-delta, ref-delta, chains)
│   ├── streampack.zig        # Streaming pack processor
│   ├── pktline.zig           # Pkt-line wire protocol (want/have/side-band)
│   │
│   │  ── Storage Backends ──
│   ├── storage.zig           # Pluggable storage backend (loose/shard)
│   ├── objectstore.zig       # Unified object store (loose + pack transparent)
│   ├── shard_store.zig       # Distributed shard backend (SHA prefix routing)
│   │
│   │  ── Concurrency ──
│   ├── parallel.zig          # Parallel file stat (100k files < 200ms)
│   ├── threadpool.zig        # Thread pool for parallel operations
│   ├── mmap.zig              # mmap zero-copy (OS page cache)
│   │
│   │  ── Config & Ignore ──
│   ├── config.zig            # Config parser (user.name, storage.backend)
│   └── ignore.zig            # .gitignore parser (!, **, *, ?)
│
├── transport/                # Network transports (4 modules)
│   ├── http.zig              # HTTP transport (std.http, pack resolution)
│   ├── smart_http.zig        # Smart HTTP protocol (upload-pack/receive-pack)
│   ├── auth.zig              # Auth (URL creds, env vars, tokens)
│   └── ssh.zig               # SSH transport (child process pipes)
│
├── util/                     # Shared utilities (2 modules)
│   ├── io.zig                # I/O wrapper for Zig 0.16 std.Io
│   └── ui.zig                # TUI helpers (colors, progress bars, symbols)
│
└── tests/
    └── integration/
        └── compat.zig        # Git compatibility tests
```

## 🔄 Git Compatibility

GitZ objects are **fully compatible** with git:

```bash
# Git can read gitz objects
git --git-dir=.gitz log --oneline

# Gitz can read git objects (via clone)
gitz clone git@github.com:user/repo.git
gitz log --oneline
```

Objects use standard git format:
- Blob: `blob <size>\0<content>`
- Tree: `tree <size>\0<entries>`
- Commit: `commit <size>\0<tree + parents + author + message>`
- All objects are zlib-compressed

## 🧩 Pluggable Storage Backend

GitZ separates the **wire protocol** (always packfiles, git-compatible) from the
**internal storage** (pluggable). This allows scaling beyond git's single-filesystem model.

### Loose backend (default)

Standard git layout: `objects/XX/YYYY...YYYY`

```bash
gitz init  # uses loose by default
```

### Shard backend

Distributes objects across N shards by SHA-1 prefix. Each shard can live on a
different physical volume for horizontal I/O scaling.

```bash
gitz init
gitz config storage.backend shard
gitz config storage.shards 16

# Objects are now stored as:
# .gitz/objects/shard_00/XX/YYYY...YYYY
# .gitz/objects/shard_01/XX/YYYY...YYYY
# ...
# .gitz/objects/shard_0f/XX/YYYY...YYYY
```

The shard index is `sha[0] % num_shards`, providing uniform distribution.
The wire protocol is unaffected — objects are unpacked from incoming packfiles
and routed to the correct shard. When sending, objects are collected from
their shards and packed on the fly.

## 📋 Roadmap

- [x] Phase 1: Core local commands (16/16)
- [x] Phase 2A: HTTP transport (partial)
- [x] Phase 2B: SSH transport (complete)
- [x] Phase 3: Developer experience (search, review, completions)
- [x] Phase 4: Cross-platform builds, documentation

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing`)
3. Commit your changes (`git commit -m 'feat: add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing`)
5. Open a Pull Request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

*Built with 💜 using [Zig](https://ziglang.org)*

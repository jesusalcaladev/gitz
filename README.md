# 🔮 GitZ

**Git, but faster. A drop-in replacement for git written in Zig.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16-orange.svg)](https://ziglang.org)
[![Platform](https://img.shields.io/badge/Platform-Linux-brightgreen.svg)](README.md)

---

## ⚡ Features

- **Full local workflow** — init, add, commit, status, diff, log, branch, merge, rebase, stash, reset, tag, blame, gc
- **SSH clone from GitHub** — `gitz clone git@github.com:user/repo.git`
- **Bidirectional compatibility** — git can read gitz objects and vice versa
- **Respects .gitignore** — full parser with `!`, `**`, `*`, `?` support
- **Colored diff** — ANSI colors for added/removed lines
- **Interactive rebase** — `gitz rebase -i` with pick/squash/drop menu
- **Pluggable storage backend** — loose objects or sharded directories, configurable per-repo
- **Shard store for horizontal scaling** — distribute objects across N shards by SHA prefix
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

### Local Commands

| Command | Description |
|---------|-------------|
| `gitz init` | Initialize a new repository |
| `gitz add <files>` | Stage files for commit (respects .gitignore) |
| `gitz commit -m "msg"` | Record changes. Use `-a` to auto-stage, `--amend` to edit |
| `gitz status` | Show staged, unstaged, and untracked files |
| `gitz diff` | Show changes. Use `--staged` for staged changes |
| `gitz log` | Show history. Use `--graph`, `--all`, `-n`, `--author`, `--grep` |
| `gitz branch` | List/create branches. Use `-d`/`-D` to delete, `-m` to rename |
| `gitz switch` | Switch branches. Use `-c` to create and switch |
| `gitz merge` | Merge branches. Use `--no-ff` for merge commit |
| `gitz rebase` | Rebase current branch. Use `--onto`, `--abort` |
| `gitz stash` | Stash changes. Use `push`, `pop`, `apply`, `list`, `drop`, `show` |
| `gitz reset` | Reset HEAD. Use `--soft`, `--mixed`, `--hard` |
| `gitz undo` | Undo last commit (creates inverse commit) |
| `gitz tag` | Create/list tags. Use `-a` for annotated, `-d` to delete |
| `gitz blame` | Show per-line author history |
| `gitz gc` | Clean up unreachable objects |
| `gitz config` | Get/set user.name and user.email |

### Remote Commands

| Command | Description |
|---------|-------------|
| `gitz clone <url>` | Clone a repository (supports SSH URLs) |
| `gitz fetch` | Download objects and refs from remote |
| `gitz push` | Upload local objects to remote |
| `gitz pull` | Fetch and rebase from remote |
| `gitz remote` | Manage remotes (add, remove, list, set-url) |

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
├── main.zig              # Entry point
├── cli/
│   ├── mod.zig           # Command dispatch
│   ├── parser.zig        # Argument parser
│   └── commands/         # All command implementations
│       ├── init.zig      # gitz init
│       ├── add.zig       # gitz add (with .gitignore support)
│       ├── commit.zig    # gitz commit
│       ├── status.zig    # gitz status
│       ├── log.zig       # gitz log
│       ├── diff.zig      # gitz diff (LCS algorithm)
│       ├── branch.zig    # gitz branch
│       ├── merge.zig     # gitz merge
│       ├── rebase.zig    # gitz rebase (simple + interactive)
│       ├── stash.zig     # gitz stash
│       ├── reset.zig     # gitz reset
│       ├── tag.zig       # gitz tag
│       ├── blame.zig     # gitz blame
│       ├── gc.zig        # gitz gc
│       ├── clone.zig     # gitz clone
│       ├── fetch.zig     # gitz fetch
│       ├── push.zig      # gitz push
│       ├── pull.zig      # gitz pull
│       ├── remote.zig    # gitz remote
│       ├── config.zig    # gitz config
│       └── undo.zig      # gitz undo
├── core/
│   ├── sha1.zig          # SHA-1 hashing
│   ├── object.zig        # Git objects (blob, tree, commit, tag)
│   ├── loose.zig         # Loose object store (with zlib)
│   ├── index.zig         # Staging area
│   ├── refs.zig          # Reference system
│   ├── diff.zig          # Diff algorithm (LCS)
│   ├── merge.zig         # 3-way merge
│   ├── stash.zig         # Stash management
│   ├── ignore.zig        # .gitignore parser
│   ├── config.zig        # Config parser
│   └── zlib.zig          # Zlib compression
├── transport/
│   ├── ssh.zig           # SSH transport
│   └── http.zig          # HTTP transport
└── util/
    └── io.zig            # I/O wrapper for Zig 0.16
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
- [ ] Phase 3: Developer experience (search, completions)
- [ ] Phase 4: Cross-platform builds, documentation

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

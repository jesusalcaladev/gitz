# GitZ

**Git, but faster. A drop-in replacement for git written in Zig.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16-orange.svg)](https://ziglang.org)

---

## Features

- **Full local workflow** -- init, add, commit, status, diff, log, branch, merge, rebase, stash, reset, tag, blame, gc
- **SSH clone from GitHub** -- `gitz clone git@github.com:user/repo.git`
- **Bidirectional compatibility** -- git can read gitz objects and vice versa
- **Respects .gitignore** -- full parser with `!`, `**`, `*`, `?` support
- **Colored diff** -- ANSI colors for added/removed lines
- **Interactive rebase** -- `gitz rebase -i` with pick/squash/drop menu (TUI)
- **Pluggable storage backend** -- loose objects or sharded directories, configurable per-repo
- **Shard store for horizontal scaling** -- distribute objects across N shards by SHA prefix
- **Written in Zig** -- single binary, no dependencies, blazing fast

## Quick Start

### One-line install (Recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/jesusalcaladev/gitz/main/install.sh | bash
```

This will:
1. **Download pre-built binary** (fastest, no Zig required)
2. **Or build from source** (if no binary available for your platform)
3. Add `gitz` to your PATH automatically

### Manual install from releases

Download the latest binary from [GitHub Releases](https://github.com/jesusalcaladev/gitz/releases):

```bash
# Linux x86_64
curl -fsSL https://github.com/jesusalcaladev/gitz/releases/latest/download/gitz-linux-x86_64.tar.gz | tar -xz

# Linux aarch64
curl -fsSL https://github.com/jesusalcaladev/gitz/releases/latest/download/gitz-linux-aarch64.tar.gz | tar -xz

# macOS x86_64
curl -fsSL https://github.com/jesusalcaladev/gitz/releases/latest/download/gitz-macos-x86_64.tar.gz | tar -xz

# macOS aarch64 (Apple Silicon)
curl -fsSL https://github.com/jesusalcaladev/gitz/releases/latest/download/gitz-macos-aarch64.tar.gz | tar -xz

# Install to ~/.local/bin
mkdir -p ~/.local/bin
mv gitz ~/.local/bin/
```

### Build from source

```bash
# Clone the repository
git clone git@github.com:jesusalcaladev/gitz.git
cd gitz

# Build with Zig
zig build -Doptimize=ReleaseFast

# Install globally
mkdir -p ~/.local/bin
cp zig-out/bin/gitz ~/.local/bin/

# Add to PATH (if not already)
export PATH="$HOME/.local/bin:$PATH"

# Verify installation
gitz --version
```

### Requirements

- **Linux** (x86_64, aarch64) or **macOS** (x86_64, aarch64)
- **Zig 0.16+** (only needed for building from source)
- **git** (optional, for SSH clone/push)

## Usage

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

## Commands Reference

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

### Utility Commands

| Command | Description |
|---------|-------------|
| `gitz update` | Update gitz to the latest version |
| `gitz update --check` | Check for updates without installing |

## Testing

```bash
# Run all tests
zig build test

# Run specific test
zig build test -- --test-filter "sha1"
```

## Architecture

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
│       ├── switch.zig    # gitz switch
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
│   ├── packfile.zig      # Packfile reader/writer
│   ├── packindex.zig     # Pack index
│   ├── delta.zig         # Delta compression
│   ├── mmap.zig          # Memory-mapped I/O
│   ├── threadpool.zig    # Thread pool
│   ├── parallel.zig      # Parallel operations
│   ├── pktline.zig       # Packet-line protocol
│   ├── streampack.zig    # Streaming pack
│   ├── zlib.zig          # Zlib compression
│   ├── storage.zig       # Pluggable storage backend
│   ├── shard_store.zig   # Shard storage backend
│   └── objectstore.zig   # Unified object store
├── transport/
│   ├── ssh.zig           # SSH transport
│   ├── smart_http.zig    # Smart HTTP client
│   ├── auth.zig          # Authentication
│   └── http.zig          # HTTP transport
└── util/
    ├── io.zig            # I/O wrapper for Zig 0.16
    ├── fs.zig            # Filesystem helpers
    ├── compression.zig   # Compression wrappers
    ├── mmap.zig          # Memory-mapped I/O
    ├── path.zig          # Path manipulation
    └── temp.zig          # Temporary files
```

## Git Compatibility

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

## Pluggable Storage Backend

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
The wire protocol is unaffected -- objects are unpacked from incoming packfiles
and routed to the correct shard. When sending, objects are collected from
their shards and packed on the fly.

## Project Status

### Completed

- **Phase 1 (Core Local)**: 15/16 commands -- all local commands working
- **Phase 2A (HTTP Transport)**: 5/8 -- fetch, clone, push, pull, remote working
- **Phase 2B (SSH Transport)**: 2/2 -- full SSH transport complete
- **Phase 4 (Cross-platform)**: Binary builds for Linux x86_64/aarch64, macOS x86_64/aarch64

### Known Bugs (all fixed)

| Issue | Status | Description |
|-------|--------|-------------|
| Blame encoding | Fixed | Improved encoding handling and path resolution |
| Rebase orphan commits | Fixed | Added gc after rebase to clean up orphans |
| Stash over-staging | Fixed | Now compares SHA with HEAD before including |
| Remote list empty | Fixed | Expected behavior when no remotes configured |
| Clone no checkout | Fixed | Clone now performs full checkout |
| Commit -a re-adds all | Fixed | Now only updates actually modified files |

### Missing Features

| Feature | Priority | Description |
|---------|----------|-------------|
| Interactive rebase TUI | High | Arrow keys, pick/squash/drop menu |
| `gitz search` | Medium | Search commit contents |
| `gitz review` | Medium | Built-in code review |
| `gitz sync` | Medium | Fetch + auto-rebase |
| Shell completions | Medium | bash/zsh/fish |
| Windows support | Low | Build for Windows |
| Git LFS support | Low | Large file storage |
| HTTP transport tests | Low | Test suite for HTTP |
| Release v1.0 | Low | Stable release |

### Roadmap

- [x] Phase 1: Core local commands (15/16)
- [x] Phase 2A: HTTP transport (partial)
- [x] Phase 2B: SSH transport (complete)
- [x] Phase 4: Cross-platform builds
- [ ] Phase 3: Developer experience (search, completions, review)
- [ ] Phase 1 completion: Interactive rebase TUI
- [ ] Release v1.0

## Releases

Pre-built binaries are available for:
- Linux x86_64 and aarch64
- macOS x86_64 and aarch64 (Apple Silicon)

Check the [Releases page](https://github.com/jesusalcaladev/gitz/releases) for the latest version.

To create a release, tag a commit and push:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The GitHub Actions workflow will automatically build and publish binaries for all platforms.

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing`)
3. Commit your changes (`git commit -m 'feat: add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

*Built with [Zig](https://ziglang.org)*

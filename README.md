# GitZ

**Git, but faster. A drop-in replacement for git written in Zig.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16-orange.svg)](https://ziglang.org)

---

## Quick Start

```bash
# Install
curl -fsSL https://raw.githubusercontent.com/jesusalcaladev/gitz/main/install.sh | bash

# Or build from source
git clone git@github.com:jesusalcaladev/gitz.git && cd gitz
zig build -Doptimize=ReleaseFast
cp zig-out/bin/gitz ~/.local/bin/
```

### Requirements

- **Linux** (x86_64, aarch64) or **macOS** (x86_64, aarch64)
- **Zig 0.16+** (only for building from source)
- **SSH** (for clone/push/pull)

---

## Usage

```bash
gitz init                              # Create .gitz/ repository
gitz add .                             # Stage all files
gitz commit -m "Initial commit"        # Create commit
gitz status                            # Beautiful status display
gitz log --graph --all                 # Visual history
gitz diff                              # Colored diffs
gitz branch feature                    # Create branch
gitz switch feature                    # Switch branch
gitz merge main                        # Merge branches
gitz rebase -i main                    # Interactive rebase (TUI)
gitz stash / stash pop                 # Stash management
gitz search "TODO"                     # Search commits & content
gitz review HEAD~3 HEAD                # Code review
gitz sync                              # Fetch + rebase
gitz clone git@github.com:user/repo.git # Clone via SSH
gitz push origin main                  # Push (native SSH)
gitz pull                              # Pull + rebase
gitz lfs track "*.psd"                 # Large file storage
gitz completions bash > /etc/bash_completion.d/gitz  # Shell completions
```

---

## Commands

### Local

| Command | Description |
|---------|-------------|
| `gitz init` | Initialize repository |
| `gitz add <files>` | Stage files (respects .gitignore) |
| `gitz commit -m "msg"` | Record changes (`-a` auto-stage, `--amend` edit) |
| `gitz status` | Show staged, unstaged, and untracked files |
| `gitz diff` | Show changes (`--staged` for staged) |
| `gitz log` | History (`--graph`, `--all`, `-n`, `--author`, `--grep`) |
| `gitz branch` | List/create/delete/rename branches |
| `gitz switch` | Switch/create branches (`-c` to create) |
| `gitz merge` | Join branches (`--no-ff` for merge commit) |
| `gitz rebase` | Rebase (`-i` interactive, `--abort`, `--onto`) |
| `gitz stash` | Stash (`push`, `pop`, `apply`, `list`, `drop`, `show`) |
| `gitz reset` | Reset HEAD (`--soft`, `--mixed`, `--hard`) |
| `gitz undo` | Undo last commit |
| `gitz tag` | Tags (`-a` annotated, `-d` delete) |
| `gitz blame` | Per-line author history |
| `gitz gc` | Clean up unreachable objects |
| `gitz config` | Set user.name / user.email |
| `gitz search` | Search commit messages & file contents |
| `gitz review` | Code review with diff stats |
| `gitz sync` | Fetch + auto-rebase |
| `gitz lfs` | Git Large File Storage |

### Remote

| Command | Description |
|---------|-------------|
| `gitz clone <url>` | Clone repository (SSH) |
| `gitz fetch` | Download from remote |
| `gitz push` | Upload to remote (native SSH) |
| `gitz pull` | Fetch + rebase |
| `gitz remote` | Manage remotes (`add`, `remove`, `list`, `set-url`) |

### Utility

| Command | Description |
|---------|-------------|
| `gitz update` | Update to latest version |
| `gitz completions <shell>` | Generate bash/zsh/fish completions |

---

## Architecture

```
src/
├── main.zig              # Entry point
├── cli/
│   ├── mod.zig           # Command dispatch
│   └── commands/         # 26 command implementations
├── core/
│   ├── sha1.zig          # SHA-1 hashing
│   ├── object.zig        # Git objects (blob, tree, commit, tag)
│   ├── loose.zig         # Loose object store
│   ├── index.zig         # Staging area
│   ├── refs.zig          # Reference system
│   ├── diff.zig          # LCS diff algorithm
│   ├── merge.zig         # 3-way merge
│   ├── packfile.zig      # Packfile reader/writer
│   ├── delta.zig         # Delta compression
│   ├── storage.zig       # Pluggable storage backend
│   ├── shard_store.zig   # Shard storage backend
│   └── ...               # 15+ core modules
├── transport/
│   ├── ssh_cmd.zig       # Native SSH transport
│   ├── smart_http.zig    # Smart HTTP client
│   └── auth.zig          # Authentication
└── util/
    └── ...               # I/O, compression, filesystem
```

## Pluggable Storage

```bash
# Default: loose objects
gitz init

# Shard backend for horizontal scaling
gitz config storage.backend shard
gitz config storage.shards 16

# Objects distributed: .gitz/objects/shard_XX/YY/...
```

## Testing

```bash
zig build test                    # Run all tests (84+ tests, 0 leaks)
zig build test -- --test-filter "sha1"  # Specific test
```

## Git Compatibility

GitZ objects are **fully compatible** with git:

```bash
git --git-dir=.gitz log --oneline     # Git reads gitz objects
gitz clone git@github.com:user/repo.git  # Gitz reads git objects
```

---

## License

MIT License

---

*Built with [Zig](https://ziglang.org) -- single binary, no dependencies, blazing fast*

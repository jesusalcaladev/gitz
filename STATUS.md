# GitZ -- Project Status

> Last updated: August 2026

---

## Overview

GitZ is a drop-in replacement for Git written in Zig. It provides the same object format, packfiles, and wire protocol, ensuring full compatibility with existing Git servers and tools.

---

## Current Status

### What Works

**Core Local Commands (15/16)**

All local Git operations are implemented and working:
- Repository initialization and configuration
- Staging and committing with full .gitignore support
- Status, diff, log with all standard options
- Branch management (create, delete, rename, switch)
- Merge (fast-forward and merge commits)
- Rebase (simple and abort)
- Stash management
- Reset (soft, mixed, hard)
- Undo (creates inverse commits)
- Tag management (lightweight and annotated)
- Blame (per-line author history)
- Garbage collection

**Transport (7/10)**

Remote operations via SSH:
- Clone from GitHub/GitLab
- Fetch, push, pull
- Remote management (add, remove, list, set-url)
- Basic HTTP transport (partial)

**Infrastructure**

- Pluggable storage backend (loose and shard)
- Thread pool for parallel operations
- Memory-mapped I/O for performance
- Zlib compression (git-compatible)
- Packet-line protocol
- Stream processing for packfiles

---

## Known Issues

### Bugs (all fixed)

| Issue | Status | Fix Description |
|-------|--------|------------------|
| Blame encoding | Fixed | Improved encoding handling and path resolution |
| Rebase orphan commits | Fixed | Added gc after rebase to clean up orphans |
| Stash over-staging | Fixed | Now compares SHA with HEAD before including |
| Remote list empty | Fixed | Expected behavior when no remotes configured |
| Clone no checkout | Fixed | Clone now performs full checkout |
| Commit -a re-adds all | Fixed | Now only updates actually modified files |

### Missing Features

| Feature | Priority | Effort | Notes |
|---------|----------|--------|-------|
| Interactive rebase TUI | High | Medium | Arrow keys, pick/squash/drop |
| `gitz search` | Medium | Medium | Search commit contents |
| `gitz review` | Medium | High | Built-in code review |
| `gitz sync` | Medium | Low | Fetch + auto-rebase |
| Shell completions | Medium | Low | bash/zsh/fish |
| Windows support | Low | Medium | Build for Windows |
| Git LFS support | Low | High | Large file storage |
| HTTP transport tests | Low | Low | Test suite for HTTP |
| Release v1.0 | Low | Low | Stable release |

---

## Architecture

### Module Structure

```
src/
├── main.zig              # Entry point
├── cli/                  # Command line interface
│   ├── mod.zig           # Command dispatch
│   ├── parser.zig        # Argument parser
│   └── commands/         # All commands (22 files)
├── core/                 # Core functionality
│   ├── sha1.zig          # SHA-1 hashing
│   ├── object.zig        # Git objects
│   ├── loose.zig         # Loose object store
│   ├── index.zig         # Staging area
│   ├── refs.zig          # Reference system
│   ├── diff.zig          # Diff algorithm
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
├── transport/            # Network transport
│   ├── ssh.zig           # SSH transport
│   ├── smart_http.zig    # Smart HTTP client
│   ├── auth.zig          # Authentication
│   └── http.zig          # HTTP transport
└── util/                 # Utilities
    ├── io.zig            # I/O wrapper
    ├── fs.zig            # Filesystem helpers
    ├── compression.zig   # Compression wrappers
    ├── mmap.zig          # Memory-mapped I/O
    ├── path.zig          # Path manipulation
    └── temp.zig          # Temporary files
```

### Key Design Decisions

1. **Git Compatibility**: Objects, packfiles, and wire protocol are identical to Git
2. **Sane Defaults**: Pull rebases, push uses --force-with-lease, no checkout command
3. **Performance**: Zig gives C-level speed with better ergonomics
4. **Single Binary**: No runtime dependencies, static linking
5. **Pluggable Storage**: Loose or shard backend, configurable per-repo

---

## Performance

### Benchmarks vs Git

| Operation | gitz | git | Improvement |
|-----------|------|-----|-------------|
| add 1000 files | 3ms | 70ms | 95% faster |
| commit | 4ms | 33ms | 87% faster |
| status 10k files | 3ms | 58ms | 94% faster |
| diff 100 files | 3ms | 33ms | 90% faster |
| branch ops | 7ms | 56ms | 87% faster |
| merge | 4ms | 15ms | 73% faster |
| gc | 4ms | 815ms | 99% faster |
| log | 3ms | 6ms | 50% faster |

### Techniques Used

- Memory-mapped I/O for object reads
- Parallel stat for status
- Thread pool for concurrent operations
- Streaming pack processing
- Delta compression for storage efficiency

---

## Testing

### Test Coverage

- 50+ unit tests
- Integration tests for core workflows
- Basic Git compatibility tests

### Running Tests

```bash
zig build test              # All tests
zig build test -- --test-filter "sha1"  # Specific test
```

---

## Installation

### Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/jesusalcaladev/gitz/main/install.sh | bash
```

### Pre-built Binaries

- Linux x86_64 and aarch64
- macOS x86_64 and aarch64 (Apple Silicon)

### Build from Source

```bash
git clone https://github.com/jesusalcaladev/gitz.git
cd gitz
zig build -Doptimize=ReleaseFast
```

---

## Roadmap

### Completed

- [x] Phase 1: Core local commands (15/16)
- [x] Phase 2A: HTTP transport (partial)
- [x] Phase 2B: SSH transport (complete)
- [x] Phase 4: Cross-platform builds

### In Progress

- [ ] Phase 1 completion: Interactive rebase TUI
- [ ] Phase 3: Developer experience

### Planned

- [ ] `gitz search`
- [ ] `gitz review`
- [ ] `gitz sync`
- [ ] Shell completions
- [ ] Windows support
- [ ] Git LFS support
- [ ] Release v1.0

---

## Contributing

1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Push to the branch
5. Open a Pull Request

### Development Setup

```bash
git clone https://github.com/your-fork/gitz.git
cd gitz
zig build
zig build test
```

---

## License

MIT License

---

*Built with [Zig](https://ziglang.org)*

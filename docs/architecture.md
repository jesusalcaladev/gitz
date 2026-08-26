# Architecture

GitZ is organized into 4 main layers: CLI, Core, Transport, and Util.

## High-Level Overview

```
┌─────────────────────────────────────────────────┐
│                   CLI Layer                      │
│  main.zig → mod.zig → commands/*.zig             │
├─────────────────────────────────────────────────┤
│                   Core Layer                     │
│  object.zig, loose.zig, index.zig, refs.zig     │
│  diff.zig, merge.zig, stash.zig                 │
│  packfile.zig, delta.zig, pktline.zig           │
│  storage.zig, shard_store.zig, objectstore.zig  │
│  parallel.zig, threadpool.zig, mmap.zig         │
├─────────────────────────────────────────────────┤
│                Transport Layer                   │
│  http.zig, smart_http.zig, ssh.zig, auth.zig    │
├─────────────────────────────────────────────────┤
│                   Util Layer                     │
│  io.zig (I/O wrapper), ui.zig (TUI helpers)     │
└─────────────────────────────────────────────────┘
```

## Module Descriptions

### CLI Layer (`src/cli/`)

| Module | Purpose |
|--------|---------|
| `main.zig` | Entry point, comptime module registration |
| `mod.zig` | Command dispatcher + `findGitDir()` parent detection |
| `parser.zig` | Argument parser |
| `commands/*.zig` | 30 command implementations |

### Core Layer (`src/core/`)

**Hashing & Compression:**
| Module | Purpose |
|--------|---------|
| `sha1.zig` | SHA-1 hashing (digest, hex, fromHex) |
| `zlib.zig` | Zlib compression/decompression |

**Git Objects:**
| Module | Purpose |
|--------|---------|
| `object.zig` | Git objects: blob, tree, commit, tag |
| `loose.zig` | Loose object store (read/write/exists/delete) |
| `index.zig` | Staging area (.gitz/index format) |
| `refs.zig` | Reference system (HEAD, branches, packed-refs) |

**Diff & Merge:**
| Module | Purpose |
|--------|---------|
| `diff.zig` | LCS diff algorithm with ANSI color output |
| `merge.zig` | 3-way merge implementation |
| `stash.zig` | Stash management (save/restore/delete) |

**Packfile Layer:**
| Module | Purpose |
|--------|---------|
| `packfile.zig` | Packfile reader/writer (v2, topological sort) |
| `packindex.zig` | Pack index with O(log n) binary search |
| `delta.zig` | Delta resolution (ofs-delta, ref-delta, chains) |
| `streampack.zig` | Streaming pack processor |
| `pktline.zig` | Pkt-line wire protocol (want/have/side-band) |

**Storage Backends:**
| Module | Purpose |
|--------|---------|
| `storage.zig` | Pluggable storage backend (loose/shard) |
| `objectstore.zig` | Unified object store (loose + pack transparent) |
| `shard_store.zig` | Distributed shard backend (SHA prefix routing) |

**Concurrency:**
| Module | Purpose |
|--------|---------|
| `parallel.zig` | Parallel file stat (100k files < 200ms) |
| `threadpool.zig` | Thread pool for parallel operations |
| `mmap.zig` | mmap zero-copy (OS page cache) |

**Config:**
| Module | Purpose |
|--------|---------|
| `config.zig` | Config parser (user.name, storage.backend) |
| `ignore.zig` | .gitignore parser (!, **, *, ?) |

### Transport Layer (`src/transport/`)

| Module | Purpose |
|--------|---------|
| `http.zig` | HTTP transport (std.http, pack resolution) |
| `smart_http.zig` | Smart HTTP protocol (upload-pack/receive-pack) |
| `auth.zig` | Auth (URL creds, env vars, tokens) |
| `ssh.zig` | SSH transport (child process pipes) |

### Util Layer (`src/util/`)

| Module | Purpose |
|--------|---------|
| `io.zig` | I/O wrapper for Zig 0.16 std.Io |
| `ui.zig` | TUI helpers (colors, progress bars, symbols) |

## Object Model

GitZ uses the standard git object model:

```
Blob:   blob <size>\0<content>
Tree:   tree <size>\0<entries>
Commit: commit <size>\0<tree + parents + author + message>
Tag:    tag <size>\0<object + tag_name + tagger + message>
```

All objects are zlib-compressed. The object format is 100% compatible with real git.

## Storage Architecture

```
.gitz/
├── HEAD                    # Symbolic ref to current branch
├── config                  # Repository configuration
├── index                   # Staging area
├── refs/
│   ├── heads/              # Local branches
│   ├── tags/               # Tags
│   └── remotes/            # Remote tracking branches
├── objects/                # Object storage
│   ├── XX/                 # Loose objects (2-char prefix)
│   │   └── YYYY...         # Remaining 38 chars of SHA
│   └── pack/               # Packfiles
│       ├── pack-*.pack     # Object data
│       └── pack-*.idx      # Pack index
└── worktrees/              # Monorepo worktrees (optional)
```

### Pluggable Storage Backend

GitZ separates the wire protocol (always packfiles) from internal storage (pluggable):

**Loose backend (default):**
```bash
gitz init  # Uses loose objects by default
```

**Shard backend:**
```bash
gitz init
gitz config storage.backend shard
gitz config storage.shards 16

# Objects stored as:
# .gitz/objects/shard_00/XX/YYYY...
# .gitz/objects/shard_01/XX/YYYY...
# ...
```

The shard index is `sha[0] % num_shards`, providing uniform distribution.

## Monorepo Support

GitZ automatically detects parent `.gitz` directories:

```
monorepo/
├── .gitz/                    # Parent repo
├── packages/
│   ├── app/
│   │   └── src/              # gitz status works here ✓
│   └── core/
│       ├── .gitz/            # Independent sub-repo
│       └── src/
└── README.md
```

Worktrees allow multiple working directories:
```bash
gitz worktree add ../feature-branch
gitz worktree list
gitz worktree remove ../feature-branch
```

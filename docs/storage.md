# Storage Backends

GitZ separates the wire protocol (always packfiles, git-compatible) from the internal storage (pluggable). This design allows scaling beyond git's single-filesystem model.

## Loose Backend (Default)

Standard git layout: `objects/XX/YYYY...YYYY`

```bash
gitz init  # Uses loose by default
```

Objects are stored individually as zlib-compressed files. The first 2 hex characters of the SHA-1 form the directory name, and the remaining 38 characters form the filename.

**Pros:** Simple, fast for small repos, git-compatible layout.
**Cons:** Many small files on disk, slow for large repos.

## Shard Backend

Distributes objects across N shards by SHA-1 prefix. Each shard can live on a different physical volume for horizontal I/O scaling.

```bash
gitz init
gitz config storage.backend shard
gitz config storage.shards 16

# Objects stored as:
# .gitz/objects/shard_00/XX/YYYY...
# .gitz/objects/shard_01/XX/YYYY...
# ...
# .gitz/objects/shard_0f/XX/YYYY...
```

The shard index is `sha[0] % num_shards`, providing uniform distribution. The wire protocol is unaffected — objects are unpacked from incoming packfiles and routed to the correct shard. When sending, objects are collected from their shards and packed on the fly.

**Pros:** Parallel I/O, horizontal scaling, better for large repos.
**Cons:** More complex layout, requires config.

## Configuration

```bash
# Set storage backend
gitz config storage.backend loose    # Default
gitz config storage.backend shard    # Distributed

# Set number of shards (only for shard backend)
gitz config storage.shards 8
gitz config storage.shards 16
gitz config storage.shards 256
```

## Packfiles

Packfiles are used for network operations (clone, fetch, push) and are always git-compatible. They are the wire format.

### Reading (clone/fetch)

Full delta resolution is supported:
- **OFS_DELTA** — offset-based delta (most common in modern packs)
- **REF_DELTA** — ref-based delta (references another object by SHA)
- **Thin packs** — packs with base objects referenced but not included
- **Delta chains** — multi-level deltas resolved recursively

### Writing (push)

Packfiles are valid but non-deltified (no delta compression between objects). This means packs are larger than git's output but are 100% valid and readable by any git client.

### Performance

| Operation | GitZ | Git | Advantage |
|-----------|------|-----|-----------|
| Pack read (deltified) | Full resolution | Full resolution | Equal |
| Pack write | Non-deltified | Deltified | Git smaller, but GitZ valid |
| Topological sort | DAG-aware | DAG-aware | Equal |
| Pack index | O(log n) binary search | O(log n) binary search | Equal |

## Object Store

The unified object store (`objectstore.zig`) provides transparent access across storage backends:

```zig
// Read from any backend
const obj = store.read(allocator, io, sha);

// Write to configured backend
const sha = try store.write(allocator, io, git_object);
```

The store automatically:
- Routes reads/writes to the correct backend (loose or shard)
- Handles packfile objects transparently
- Falls back gracefully on errors

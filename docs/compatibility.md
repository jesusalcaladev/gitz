# Git Compatibility

GitZ produces objects that are **100% compatible** with real git.

## Verified Compatibility

```bash
# Git can read GitZ objects
git --git-dir=.gitz log --oneline

# GitZ can read git objects (via clone)
gitz clone git@github.com:user/repo.git
gitz log --oneline
```

## Compatibility Matrix

| Component | Compatibility | Notes |
|-----------|:------------:|-------|
| **Object format** (blob/tree/commit/tag) | 100% | Bidirectional, verified with `git fsck` |
| **Wire protocol** Smart HTTP + Auth | 100% | Push/fetch/pull/clone verified E2E |
| **Packfiles read** (full + delta) | 100% | Complete delta resolution |
| **Packfiles write** (push) | 100% valid | Compatible but non-deltified (larger packs) |
| **Refs** | ~95% | Full support including packed-refs |
| **SSH transport** | ~80% | Works via child process |
| **Local CLI** | ~98% | Complete: rebase -i, search, sync |

> **Design note:** GitZ deliberately uses its own index format and shard store for
> horizontal scaling advantages. The wire protocol, objects, and packfile format
> are 100% git-compatible — any git server cannot distinguish a GitZ client from
> a real git client.

## Wire Protocol

Implemented in `src/core/pktline.zig`:

- `want <sha> <caps>` with capabilities on first want: `multi_ack thin-pack side-band-64k ofs-delta agent=git/2.45.0`
- `have` lines for thin packs
- Sideband unwrapping (band 1 = pack, bands 2/3 ignored)
- Push: `<old> <new> <ref>\0report-status agent=...` + `unpack ok` / `ok ref` / `ng ref reason`
- Required Smart HTTP headers: `Content-Type: application/x-git-{upload,receive}-pack-request`, `Accept: ...-result`, `User-Agent: git/2.45.0`

## Authentication

Verified E2E against Smart HTTP server with Basic Auth:

- **URL credentials:** `gitz clone https://user:token@github.com/user/repo.git`
- **Environment fallback:** `GITZ_HTTP_USERNAME` + `GITZ_HTTP_PASSWORD`
- **Tokens:** `GIT_TOKEN` / `GITHUB_TOKEN` (auto `x-access-token` username for GitHub format)
- **Authorization header** sent on all 3 requests: info/refs GET, upload-pack POST, receive-pack POST

## E2E Verification Results

```
gitz init → add → commit → push origin main     ✅
git clone http://…/origin.git                    ✅ Same SHA, intact content
git commit + git push → gitz fetch              ✅ refs/remotes/origin/main updated
gitz pull                                        ✅ Fast-forward + working tree synced
gitz pull (with local commits) → rebase         ✅ Rebased history readable by git
gitz clone from DELTIFIED repo (gc --aggressive) ✅ Identical object set to git
gitz fetch incremental (thin-pack REF_DELTA)     ✅ Complete new objects
```

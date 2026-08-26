# Changelog

## v0.7.0 (August 2026)

### New Features
- **Monorepo support** — Auto-detect parent `.gitz` across directory tree + worktrees
- **`gitz worktree`** — Manage multiple working trees (add/list/remove/prune)
- **`gitz show`** — Show commit details and diff
- **`gitz clean`** — Remove untracked files (`-n`, `-f`, `-fd`, `-fdx`)
- **`gitz shortlog`** — Summarize commits by author (`-s`, `-n`, `-e`)
- **`gitz diff main..feature`** — Branch-to-branch diff comparison
- **`--version` flag** — `gitz --version` / `gitz -v`

### Bug Fixes (15 total)
- Fixed blame encoding — sanitized author names in imported commits
- Fixed rebase orphan commits with `--all` — SHA deduplication
- Fixed stash applying all tracked files — now only modified/deleted
- Fixed remote list empty for new repos — dynamic directory scan
- Fixed clone checkout path for subdirectories
- Fixed `commit -a` re-adding all files — mtime check optimization
- Fixed `branch -m` dangling allocPrint in HEAD
- Fixed `add` memory leak for ignored files
- Fixed shortlog `collectCommits` with undefined `io` parameter
- Fixed worktree `while` loop syntax and missing `io` parameter
- Fixed show `formatTimestamp` dangling pointer
- Fixed shortlog footer empty contributor count
- Fixed shortlog O(n²) BFS — changed to O(1) swapRemove
- Fixed show.zig `tag.name` → `tag.tag_name` field name
- Fixed format string argument mismatches across multiple commands

### Improvements
- Improved TUI output for `gitz add` — progress bar instead of per-file lines
- Improved TUI output for `gitz status` — color-coded sections (green/yellow/red)
- Improved TUI output for `gitz log` — styled oneline with colored graph
- Improved TUI output for `gitz commit` — cleaner success message
- Improved TUI output for `gitz clone` — richer progress bar with phases
- Updated README with complete architecture tree (62 files)

## v0.5.0 (August 2026)

### New Features
- **`gitz search`** — Search file contents and commit messages
- **`gitz review`** — Code review between branches with inline diff
- **`gitz sync`** — Fetch + rebase + push in one step
- **Shell completions** — bash/zsh/fish completions
- **`gitz pack-refs`** — Compact loose refs into packed-refs
- **Cross-platform build** — Linux, macOS, Windows targets

### Improvements
- Colored output across all commands
- Interactive rebase TUI with arrow keys
- Progress bars for long operations
- Better error messages with hints

## v0.4.2 (August 2026)

### Bug Fixes
- Blame garbled characters in imported commits
- Rebase orphan commits with `--all`
- Stash applying all tracked files
- Remote list empty for new repos
- Clone not checking out subdirectories
- `commit -a` re-adding all files
- `branch -m` dangling allocation
- `add` memory leak for ignored files
- `--version` flag not implemented

## v0.4.0 (August 2026)

### Features
- Complete local workflow (16 commands)
- HTTP transport with pack resolution
- SSH transport via child process
- Pluggable storage backend (loose/shard)
- Shard store for horizontal scaling
- Interactive rebase TUI
- Progress bars and colored output

## v0.1.0 (July 2026)

### Initial Release
- Core git object model (blob, tree, commit, tag)
- Loose object store with zlib compression
- SHA-1 hashing
- Basic init, add, commit, status, log, diff, branch, merge, stash, reset, tag, blame, gc

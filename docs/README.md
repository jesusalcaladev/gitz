# 📚 GitZ Documentation

Welcome to the GitZ documentation. GitZ is a drop-in replacement for git, written in Zig.

## Table of Contents

| Document | Description |
|----------|-------------|
| [Installation](installation.md) | How to install GitZ on Linux, macOS, and Windows |
| [Quick Start](quickstart.md) | Get up and running in 5 minutes |
| [Commands Reference](commands.md) | Complete reference for all 30 commands |
| [Architecture](architecture.md) | Internal design and module structure |
| [Git Compatibility](compatibility.md) | How GitZ works with real git repositories |
| [Storage Backends](storage.md) | Pluggable storage: loose, shard, and custom backends |
| [Wire Protocol](protocol.md) | Smart HTTP protocol implementation details |
| [Contributing](contributing.md) | How to contribute to GitZ |
| [Changelog](changelog.md) | Version history and release notes |

## Quick Links

- **GitHub**: https://github.com/jesusalcaladev/gitz
- **License**: MIT
- **Minimum Zig**: 0.16+

## Overview

GitZ is a complete git implementation in Zig that:

- Implements the full local workflow (init, add, commit, status, diff, log, branch, merge, rebase, stash, reset, tag, blame, gc)
- Supports remote operations via Smart HTTP and SSH
- Produces objects 100% compatible with real git
- Features a pluggable storage backend (loose or sharded)
- Includes interactive TUI for rebase
- Provides 30 commands with colored output and progress bars

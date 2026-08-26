# Quick Start

Get up and running with GitZ in 5 minutes.

## Your First Repository

```bash
# Initialize a new repository
gitz init

# Create a file
echo "# My Project" > README.md

# Stage and commit
gitz add .
gitz commit -m "Initial commit"

# Check status
gitz status
```

## Daily Workflow

### Morning: Pull Latest Changes
```bash
gitz pull
```

### Working: Stage, Commit, Push
```bash
# See what changed
gitz status

# Stage specific files
gitz add src/main.zig src/utils.zig

# Or stage everything
gitz add .

# Commit with a message
gitz commit -m "Add new feature"

# Push to remote
gitz push origin main
```

### Check History
```bash
# View recent commits
gitz log --oneline

# View with graph
gitz log --graph --all

# Search for commits
gitz log --author="Juan"
gitz log --grep="fix"

# Search file contents
gitz search "TODO"
```

### Branching
```bash
# Create and switch to a new branch
gitz switch -c feature/new-api

# Work on the branch
gitz add .
gitz commit -m "Implement new API"

# Switch back to main
gitz switch main

# Merge the feature
gitz merge feature/new-api

# Delete the branch
gitz branch -d feature/new-api
```

### Diff and Review
```bash
# See unstaged changes
gitz diff

# See staged changes
gitz diff --staged

# Compare branches
gitz diff main..feature

# Code review between branches
gitz review main feature

# Show a specific commit
gitz show a3f2b1c
```

## Cloning a Repository

```bash
# Clone via SSH
gitz clone git@github.com:user/repo.git

# Clone via HTTPS
gitz clone https://github.com/user/repo.git

# Shallow clone (faster)
gitz clone --depth 1 https://github.com/user/repo.git
```

## Stashing Changes

```bash
# Save current changes
gitz stash

# List stashes
gitz stash list

# Apply the most recent stash
gitz stash pop

# Apply without removing from stash list
gitz stash apply
```

## Undoing Mistakes

```bash
# Undo the last commit (keeps changes staged)
gitz undo --soft

# Undo the last commit (discards changes)
gitz undo --hard

# Reset to a specific commit
gitz reset --soft HEAD~1   # Move HEAD, keep changes
gitz reset --mixed HEAD~1  # Move HEAD, unstage changes
gitz reset --hard HEAD~1   # Move HEAD, discard everything
```

## Configuration

```bash
# Set your identity
gitz config user.name "Your Name"
gitz config user.email "you@example.com"

# View all config
gitz config --list
```

## What's Different from Git?

| Feature | GitZ | Git |
|---------|------|-----|
| Language | Zig (single binary) | C (multiple binaries) |
| Speed | 70-95% faster | Baseline |
| Storage | Pluggable (loose/shard) | Fixed |
| Object format | 100% compatible | Native |
| Monorepo | Auto-detect parent | Manual |
| TUI rebase | Built-in | External (vim) |

GitZ produces objects that are **100% compatible** with real git. You can use both tools interchangeably on the same repository.

# Commands Reference

Complete reference for all 30 GitZ commands.

---

## Local Commands

### `gitz init`
Initialize a new repository.

```bash
gitz init           # Creates .gitz/ directory
gitz init --bare    # Creates a bare repository
```

### `gitz add`
Stage files for commit. Respects `.gitignore` with full support for `!`, `**`, `*`, and `?` patterns.

```bash
gitz add .          # Stage all files recursively
gitz add src/       # Stage a directory
gitz add file.zig   # Stage a single file
```

**Progress:** Shows animated progress bar during staging.

### `gitz commit`
Record changes to the repository.

```bash
gitz commit -m "message"    # Commit with message
gitz commit -a              # Auto-stage all tracked files before committing
gitz commit -am "message"   # Auto-stage and commit
gitz commit --amend         # Amend the last commit
```

### `gitz status`
Show working tree status with color-coded output.

```bash
gitz status
```

**Output colors:**
- 🟢 Green: staged files
- 🟡 Yellow: unstaged modified files  
- 🔴 Red: untracked files

### `gitz diff`
Show changes between commits, working tree, and staging.

```bash
gitz diff                  # Working tree vs index
gitz diff --staged         # Staged changes (vs HEAD)
gitz diff main..feature    # Compare two branches
gitz diff HEAD~5           # Diff vs 5 commits ago
```

### `gitz log`
Show commit history with colored graph.

```bash
gitz log --oneline         # One line per commit
gitz log --graph           # ASCII graph visualization
gitz log --all             # Show all branches
gitz log -n 10             # Limit to 10 commits
gitz log --author="name"   # Filter by author
gitz log --grep="fix"      # Filter by message
gitz log -- src/            # Filter by path
```

### `gitz branch`
List, create, or delete branches.

```bash
gitz branch               # List local branches
gitz branch feature       # Create new branch
gitz branch -d feature    # Delete branch
gitz branch -D feature    # Force delete branch
gitz branch -m old new    # Rename branch
```

### `gitz switch`
Switch branches or create new ones.

```bash
gitz switch main          # Switch to existing branch
gitz switch -c feature    # Create and switch to new branch
```

### `gitz merge`
Join branches together.

```bash
gitz merge feature        # Merge feature into current branch
gitz merge --no-ff feature # Force merge commit
```

### `gitz rebase`
Reapply commits on top of another base.

```bash
gitz rebase main          # Rebase current branch onto main
gitz rebase --onto a b c  # Rebase c onto a, skipping b
gitz rebase --abort       # Abort current rebase
gitz rebase --continue    # Continue after resolving conflicts
gitz rebase -i            # Interactive rebase (TUI)
```

**Interactive rebase TUI:** Arrow keys to navigate, select pick/squash/drop/reword/edit for each commit.

### `gitz stash`
Stash changes in a dirty working directory.

```bash
gitz stash                # Save current changes
gitz stash list           # List all stashes
gitz stash pop            # Apply and remove most recent stash
gitz stash apply          # Apply without removing
gitz stash drop           # Remove most recent stash
gitz stash show           # Show stash contents
gitz stash clear          # Remove all stashes
```

### `gitz reset`
Reset current HEAD to a specified state.

```bash
gitz reset --soft HEAD~1  # Move HEAD only (keep staged)
gitz reset --mixed HEAD~1 # Move HEAD + unstage
gitz reset --hard HEAD~1  # Discard all changes
```

### `gitz undo`
Undo the last commit (creates an inverse commit).

```bash
gitz undo                 # Undo with commit
gitz undo --soft          # Undo, keep changes staged
gitz undo --hard          # Undo, discard changes
```

### `gitz tag`
Create, list, or delete tags.

```bash
gitz tag v1.0             # Lightweight tag
gitz tag -a v1.0 -m "Release"  # Annotated tag
gitz tag -d v1.0          # Delete tag
gitz tag --list           # List all tags
```

### `gitz blame`
Show per-line author history.

```bash
gitz blame src/main.zig   # Show who last modified each line
```

### `gitz gc`
Clean up unreachable objects.

```bash
gitz gc                   # Remove orphaned objects
```

### `gitz config`
Get and set repository options.

```bash
gitz config user.name "Name"
gitz config user.email "email@example.com"
gitz config --list       # Show all config
gitz config --global     # Use global config
```

---

## DX Commands

### `gitz search`
Search file contents and commit messages.

```bash
gitz search "pattern"          # Search file contents
gitz search -m "pattern"       # Search commit messages
gitz search -a "pattern"       # Search all branches
gitz search -C 3 "pattern"     # Show 3 lines of context
gitz search -p src/ "pattern"  # Search in specific path
```

### `gitz review`
Code review between branches with inline diff.

```bash
gitz review                    # Review current branch vs main
gitz review main feature       # Compare two branches
gitz review --stat             # Show only statistics
gitz review -C 5               # 5 lines of context
```

**Output includes:**
- Per-commit diffs with author and date
- Summary with file change statistics
- Visual bar graph of additions vs deletions

### `gitz show`
Show commit details and diff.

```bash
gitz show                      # Show HEAD commit
gitz show a3f2b1c              # Show specific commit
gitz show HEAD~3               # Show 3 commits back
gitz show --stat               # Only show statistics
gitz show main                 # Show HEAD of a branch
```

### `gitz clean`
Remove untracked files.

```bash
gitz clean -n                  # Dry run (show what would be deleted)
gitz clean -f                  # Force delete untracked files
gitz clean -fd                 # Delete files and directories
gitz clean -fdx                # Also delete ignored files
```

### `gitz shortlog`
Summarize commits by author.

```bash
gitz shortlog                  # List by author
gitz shortlog -s               # Summary counts only
gitz shortlog -n               # Sort by commit count
gitz shortlog -e               # Show email addresses
```

### `gitz worktree`
Manage multiple working trees (monorepo support).

```bash
gitz worktree add ../feature   # Create worktree at path
gitz worktree add -b fix ../fix # Create with new branch
gitz worktree list (ls)        # List all worktrees
gitz worktree remove ../feature # Remove worktree
gitz worktree prune            # Clean stale data
```

### `gitz pack-refs`
Compact loose refs into packed-refs for performance.

```bash
gitz pack-refs
```

---

## Remote Commands

### `gitz clone`
Clone a repository from a URL.

```bash
gitz clone git@github.com:user/repo.git        # SSH
gitz clone https://github.com/user/repo.git    # HTTPS
gitz clone --depth 1 https://...               # Shallow clone
gitz clone https://... mydir                   # Clone into specific dir
```

**Authentication:**
- URL credentials: `https://user:token@github.com/user/repo.git`
- Environment: `GITZ_HTTP_USERNAME` + `GITZ_HTTP_PASSWORD`
- Tokens: `GIT_TOKEN` / `GITHUB_TOKEN` (auto-detects GitHub format)

### `gitz fetch`
Download objects and refs from remote.

```bash
gitz fetch                    # Fetch from origin
gitz fetch upstream           # Fetch from specific remote
```

### `gitz push`
Upload local objects to remote.

```bash
gitz push origin main         # Push to specific branch
gitz push --force             # Force push (dangerous!)
gitz push -f                  # Force push shorthand
```

### `gitz pull`
Fetch and integrate from remote.

```bash
gitz pull                     # Fetch + rebase from origin
gitz pull --rebase            # Explicit rebase strategy
gitz pull --merge             # Use merge instead of rebase
```

### `gitz remote`
Manage remote repositories.

```bash
gitz remote add origin git@github.com:user/repo.git
gitz remote remove origin
gitz remote list
gitz remote set-url origin new-url
```

### `gitz sync`
Fetch + rebase + push in one step.

```bash
gitz sync                     # Sync with origin
gitz sync upstream            # Sync with specific remote
```

---

## Global Options

| Flag | Description |
|------|-------------|
| `-h`, `--help` | Show help message |
| `-v`, `--version` | Show version |

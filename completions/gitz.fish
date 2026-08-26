# GitZ fish completions
# Copy to: ~/.config/fish/completions/gitz.fish

# Helper: complete subcommands
function __gitz_subcommands
    echo -e "init\tInitialize a new repository"
    echo -e "add\tStage files for commit"
    echo -e "commit\tRecord changes to the repository"
    echo -e "status\tShow working tree status"
    echo -e "diff\tShow changes between commits"
    echo -e "log\tShow commit history"
    echo -e "branch\tList, create, or delete branches"
    echo -e "switch\tSwitch to a branch or create a new one"
    echo -e "merge\tJoin two branches together"
    echo -e "rebase\tReapply commits on top of another base"
    echo -e "stash\tStash changes in a dirty working directory"
    echo -e "reset\tReset current HEAD to a specified state"
    echo -e "undo\tUndo the last commit"
    echo -e "tag\tCreate, list, delete tags"
    echo -e "blame\tShow what revision last modified each line"
    echo -e "gc\tClean up unreachable objects"
    echo -e "config\tGet and set repository options"
    echo -e "clone\tClone a repository from a URL"
    echo -e "fetch\tDownload objects and refs from a remote"
    echo -e "push\tUpdate remote refs using associated local objects"
    echo -e "pull\tFetch from and integrate with another repository"
    echo -e "remote\tManage set of tracked repositories"
    echo -e "sync\tFetch + rebase + push the current branch"
    echo -e "search\tSearch file contents and commit messages"
    echo -e "review\tCode review between branches"
    echo -e "show\tShow commit details and diff"
    echo -e "clean\tRemove untracked files"
    echo -e "shortlog\tSummarize commits by author"
    echo -e "worktree\tManage multiple working trees"
    echo -e "pack-refs\tCompact loose refs into packed-refs"
end

function __gitz_branches
    git branch --format='%(refname:short)' 2>/dev/null
end

function __gitz_remotes
    git remote 2>/dev/null
end

# Disable file completions by default
complete -c gitz -f

# Subcommands (only when no subcommand is entered yet)
complete -c gitz -n __gitz_use_subcommand -a '(__gitz_subcommands)' -d 'Command'

function __gitz_use_subcommand
    set -l cmd (commandline -opc)
    test (count $cmd) -eq 1
end

# ── Global options ──
complete -c gitz -s h -l help -d 'Show help'
complete -c gitz -s v -l version -d 'Show version'

# ── init ──
complete -c gitz -n '__gitz_command init' -l bare -d 'Create bare repository'

# ── add ──
complete -c gitz -n '__gitz_command add' -F

# ── commit ──
complete -c gitz -n '__gitz_command commit' -s m -r -d 'Commit message'
complete -c gitz -n '__gitz_command commit' -s a -d 'Auto-stage all tracked files'
complete -c gitz -n '__gitz_command commit' -l amend -d 'Amend last commit'

# ── diff ──
complete -c gitz -n '__gitz_command diff' -l staged -d 'Show staged changes'
complete -c gitz -n '__gitz_command diff' -l cached -d 'Alias for --staged'
complete -c gitz -n '__gitz_command diff' -l no-color -d 'Disable colored output'

# ── log ──
complete -c gitz -n '__gitz_command log' -l oneline -d 'One line per commit'
complete -c gitz -n '__gitz_command log' -l graph -d 'Show ASCII graph'
complete -c gitz -n '__gitz_command log' -l all -d 'Show all branches'
complete -c gitz -n '__gitz_command log' -l author -r -d 'Filter by author'
complete -c gitz -n '__gitz_command log' -l grep -r -d 'Filter by message'
complete -c gitz -n '__gitz_command log' -s n -r -d 'Limit count'

# ── branch ──
complete -c gitz -n '__gitz_command branch' -s d -r -d 'Delete branch'
complete -c gitz -n '__gitz_command branch' -s D -r -d 'Force delete branch'
complete -c gitz -n '__gitz_command branch' -s m -r -d 'Rename branch'

# ── switch ──
complete -c gitz -n '__gitz_command switch' -s c -d 'Create and switch to new branch'
complete -c gitz -n '__gitz_command switch' -a '(__gitz_branches)' -d 'Branch'

# ── merge ──
complete -c gitz -n '__gitz_command merge' -l no-ff -d 'No fast-forward merge'
complete -c gitz -n '__gitz_command merge' -s m -r -d 'Merge message'
complete -c gitz -n '__gitz_command merge' -a '(__gitz_branches)' -d 'Branch'

# ── rebase ──
complete -c gitz -n '__gitz_command rebase' -s i -d 'Interactive rebase'
complete -c gitz -n '__gitz_command rebase' -l interactive -d 'Interactive rebase'
complete -c gitz -n '__gitz_command rebase' -l abort -d 'Abort rebase'
complete -c gitz -n '__gitz_command rebase' -l continue -d 'Continue rebase'
complete -c gitz -n '__gitz_command rebase' -l onto -r -d 'Rebase onto base'
complete -c gitz -n '__gitz_command rebase' -a '(__gitz_branches)' -d 'Branch'

# ── stash ──
complete -c gitz -n '__gitz_command stash' -a 'push save list pop apply drop show clear'

# ── reset ──
complete -c gitz -n '__gitz_command reset' -l soft -d 'Move HEAD only'
complete -c gitz -n '__gitz_command reset' -l mixed -d 'Move HEAD and reset index'
complete -c gitz -n '__gitz_command reset' -l hard -d 'Move HEAD, reset index and working tree'

# ── undo ──
complete -c gitz -n '__gitz_command undo' -l soft -d 'Undo, keep changes staged'
complete -c gitz -n '__gitz_command undo' -l hard -d 'Undo, discard changes'

# ── tag ──
complete -c gitz -n '__gitz_command tag' -s a -d 'Create annotated tag'
complete -c gitz -n '__gitz_command tag' -s m -r -d 'Tag message'
complete -c gitz -n '__gitz_command tag' -s d -d 'Delete tag'
complete -c gitz -n '__gitz_command tag' -l delete -d 'Delete tag'

# ── config ──
complete -c gitz -n '__gitz_command config' -l global -d 'Use global config'
complete -c gitz -n '__gitz_command config' -l list -d 'List all config'
complete -c gitz -n '__gitz_command config' -s l -d 'List all config'

# ── clone ──
complete -c gitz -n '__gitz_command clone' -l depth -r -d 'Shallow clone depth'

# ── fetch ──
complete -c gitz -n '__gitz_command fetch' -a '(__gitz_remotes)' -d 'Remote'

# ── push ──
complete -c gitz -n '__gitz_command push' -l force -d 'Force push'
complete -c gitz -n '__gitz_command push' -s f -d 'Force push'
complete -c gitz -n '__gitz_command push' -a '(__gitz_remotes)' -d 'Remote'

# ── pull ──
complete -c gitz -n '__gitz_command pull' -l merge -d 'Use merge strategy'
complete -c gitz -n '__gitz_command pull' -s m -d 'Use merge strategy'
complete -c gitz -n '__gitz_command pull' -l rebase -d 'Use rebase strategy'
complete -c gitz -n '__gitz_command pull' -s r -d 'Use rebase strategy'
complete -c gitz -n '__gitz_command pull' -a '(__gitz_remotes)' -d 'Remote'

# ── remote ──
complete -c gitz -n '__gitz_command remote' -a 'add remove rename set-url get-url'

# ── sync ──
complete -c gitz -n '__gitz_command sync' -a '(__gitz_remotes)' -d 'Remote'

# ── search ──
complete -c gitz -n '__gitz_command search' -l message -d 'Search commit messages'
complete -c gitz -n '__gitz_command search' -s m -d 'Search commit messages'
complete -c gitz -n '__gitz_command search' -l all -d 'Search all branches'
complete -c gitz -n '__gitz_command search' -s a -d 'Search all branches'
complete -c gitz -n '__gitz_command search' -l context -r -d 'Context lines'
complete -c gitz -n '__gitz_command search' -s C -r -d 'Context lines'
complete -c gitz -n '__gitz_command search' -l path -r -d 'Path filter'
complete -c gitz -n '__gitz_command search' -s p -r -d 'Path filter'

# ── review ──
complete -c gitz -n '__gitz_command review' -l stat -d 'Show only stats'
complete -c gitz -n '__gitz_command review' -l context -r -d 'Context lines'
complete -c gitz -n '__gitz_command review' -s C -r -d 'Context lines'
complete -c gitz -n '__gitz_command review' -a '(__gitz_branches)' -d 'Base branch'

# ── show ──
complete -c gitz -n '__gitz_command show' -l stat -d 'Show only stats'
complete -c gitz -n '__gitz_command show' -a '(__gitz_branches)' -d 'Commit'

# ── clean ──
complete -c gitz -n '__gitz_command clean' -s f -d 'Force removal'
complete -c gitz -n '__gitz_command clean' -s n -d 'Dry run'
complete -c gitz -n '__gitz_command clean' -s i -d 'Interactive'
complete -c gitz -n '__gitz_command clean' -s d -d 'Include directories'
complete -c gitz -n '__gitz_command clean' -l dry-run -d 'Dry run'
complete -c gitz -n '__gitz_command clean' -l force -d 'Force removal'

# ── shortlog ──
complete -c gitz -n '__gitz_command shortlog' -s s -d 'Summary only'
complete -c gitz -n '__gitz_command shortlog' -s n -d 'Sort by count'
complete -c gitz -n '__gitz_command shortlog' -s e -d 'Show email'
complete -c gitz -n '__gitz_command shortlog' -l summary -d 'Summary only'
complete -c gitz -n '__gitz_command shortlog' -l numbered -d 'Sort by count'
complete -c gitz -n '__gitz_command shortlog' -l email -d 'Show email'

# ── worktree ──
complete -c gitz -n '__gitz_command worktree' -a 'add' -d 'Create a new worktree'
complete -c gitz -n '__gitz_command worktree' -a 'list' -d 'List all worktrees'
complete -c gitz -n '__gitz_command worktree' -a 'remove' -d 'Remove a worktree'
complete -c gitz -n '__gitz_command worktree' -a 'prune' -d 'Remove stale worktree data'
complete -c gitz -n '__gitz_command worktree' -l b -r -d 'Create new branch'

# Helpers
function __gitz_command
    set -l cmd (commandline -opc)
    test (count $cmd) -gt 1; and test "$cmd[2]" = "$argv[1]"
end

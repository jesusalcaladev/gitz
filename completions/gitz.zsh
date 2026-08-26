#compdef gitz

# GitZ zsh completions
# Add to fpath: fpath=(/path/to/gitz/completions $fpath)

_gitz() {
    local -a commands
    commands=(
        'init:Initialize a new repository'
        'add:Stage files for commit'
        'commit:Record changes to the repository'
        'status:Show working tree status'
        'diff:Show changes between commits'
        'log:Show commit history'
        'branch:List, create, or delete branches'
        'switch:Switch to a branch or create a new one'
        'merge:Join two branches together'
        'rebase:Reapply commits on top of another base'
        'stash:Stash changes in a dirty working directory'
        'reset:Reset current HEAD to a specified state'
        'undo:Undo the last commit'
        'tag:Create, list, delete tags'
        'blame:Show what revision last modified each line'
        'gc:Clean up unreachable objects'
        'config:Get and set repository options'
        'clone:Clone a repository from a URL'
        'fetch:Download objects and refs from a remote'
        'push:Update remote refs using associated local objects'
        'pull:Fetch from and integrate with another repository'
        'remote:Manage set of tracked repositories'
        'sync:Fetch + rebase + push the current branch'
        'search:Search file contents and commit messages'
        'review:Code review between branches'
        'show:Show commit details and diff'
        'clean:Remove untracked files'
        'shortlog:Summarize commits by author'
        'worktree:Manage multiple working trees'
        'pack-refs:Compact loose refs into packed-refs'
    )

    _arguments -C \
        '1:command:->command' \
        '*::arg:->args'

    case $state in
        command)
            _describe 'command' commands
            ;;
        args)
            case ${words[1]} in
                init)
                    _arguments \
                        '--bare[Create bare repository]'
                    ;;
                add)
                    _files -/'
                    ;;
                commit)
                    _arguments \
                        '-m[Commit message]:message:' \
                        '-a[Auto-stage all tracked files]' \
                        '-am[Auto-stage and commit]' \
                        '--amend[Amend last commit]'
                    ;;
                status)
                    ;;
                diff)
                    _arguments \
                        '--staged[Show staged changes]' \
                        '--cached[Alias for --staged]' \
                        '--no-color[Disable colored output]'
                    ;;
                log)
                    _arguments \
                        '--oneline[One line per commit]' \
                        '--graph[Show ASCII graph]' \
                        '--all[Show all branches]' \
                        '--author[Filter by author]:author:' \
                        '--grep[Filter by message]:pattern:' \
                        '-n[Limit count]:count:' \
                        '1:file:_files'
                    ;;
                branch)
                    _arguments \
                        '-d[Delete branch]' \
                        '-D[Force delete branch]' \
                        '-m[Rename branch]:old: :->branch_names'
                    ;;
                switch)
                    _arguments \
                        '-c[Create and switch to new branch]' \
                        '1:branch:->branch_names'
                    ;;
                merge)
                    _arguments \
                        '--no-ff[No fast-forward merge]' \
                        '-m[Merge message]:message:' \
                        '1:branch:->branch_names'
                    ;;
                rebase)
                    _arguments \
                        '-i[Interactive rebase]' \
                        '--interactive[Interactive rebase]' \
                        '--abort[Abort rebase]' \
                        '--continue[Continue rebase]' \
                        '--onto[Rebase onto]:base:' \
                        '1:branch:->branch_names'
                    ;;
                stash)
                    _arguments \
                        '1:subcommand:(push save list pop apply drop show clear)'
                    ;;
                reset)
                    _arguments \
                        '--soft[Move HEAD only]' \
                        '--mixed[Move HEAD and reset index]' \
                        '--hard[Move HEAD, reset index and working tree]' \
                        '1:commit:'
                    ;;
                undo)
                    _arguments \
                        '--soft[Undo, keep changes staged]' \
                        '--hard[Undo, discard changes]'
                    ;;
                tag)
                    _arguments \
                        '-a[Create annotated tag]' \
                        '-m[Tag message]:message:' \
                        '-d[Delete tag]' \
                        '--delete[Delete tag]' \
                        '-n[List tags]' \
                        '--list[List tags]'
                    ;;
                blame)
                    '1:file:_files'
                    ;;
                config)
                    _arguments \
                        '--global[Use global config]' \
                        '--list[List all config]' \
                        '-l[List all config]' \
                        '1:key:' \
                        '2:value:'
                    ;;
                clone)
                    _arguments \
                        '--depth[Shallow clone]:depth:' \
                        '1:url:' \
                        '2:directory:_directories'
                    ;;
                fetch)
                    '1:remote:->remotes'
                    ;;
                push)
                    _arguments \
                        '--force[Force push]' \
                        '-f[Force push]' \
                        '1:remote:->remotes' \
                        '2:branch:->branch_names'
                    ;;
                pull)
                    _arguments \
                        '--merge[Use merge strategy]' \
                        '-m[Use merge strategy]' \
                        '--rebase[Use rebase strategy]' \
                        '-r[Use rebase strategy]' \
                        '1:remote:->remotes'
                    ;;
                remote)
                    _arguments \
                        '1:subcommand:(add remove rename set-url get-url -v --verbose)' \
                        '2:name:' \
                        '3:url:'
                    ;;
                sync)
                    '1:remote:->remotes'
                    ;;
                search)
                    _arguments \
                        '--message[Search commit messages]' \
                        '-m[Search commit messages]' \
                        '--all[Search all branches]' \
                        '-a[Search all branches]' \
                        '--context[Context lines]:lines:' \
                        '-C[Context lines]:lines:' \
                        '--path[Path filter]:path:' \
                        '1:pattern:'
                    ;;
                review)
                    _arguments \
                        '--stat[Show only stats]' \
                        '--context[Context lines]:lines:' \
                        '-C[Context lines]:lines:' \
                        '1:base:->branch_names' \
                        '2:target:->branch_names'
                    ;;
                show)
                    _arguments \
                        '--stat[Show only stats]' \
                        '1:commit:'
                    ;;
                clean)
                    _arguments \
                        '-f[Force removal]' \
                        '-n[Dry run]' \
                        '-i[Interactive]' \
                        '-d[Include directories]' \
                        '-fd[Force + directories]' \
                        '-fdx[Force + dirs + ignored]'
                    ;;
                shortlog)
                    _arguments \
                        '-s[Summary only]' \
                        '-n[Sort by count]' \
                        '-e[Show email]' \
                        '--summary[Summary only]' \
                        '--numbered[Sort by count]' \
                        '--email[Show email]'
                    ;;
                worktree)
                    _arguments \
                        '1:subcommand:(add list ls remove rm prune lock unlock)' \
                        '2:path:_directories'
                    ;;
            esac
            ;;
    esac

    _branch_names() {
        local -a branches
        branches=(${(f)"$(git branch --format='%(refname:short)' 2>/dev/null)"})
        _describe 'branch' branches
    }

    _remotes() {
        local -a remotes
        remotes=(${(f)"$(git remote 2>/dev/null)"})
        _describe 'remote' remotes
    }
}

_gitz "$@"

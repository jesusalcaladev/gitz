#!/usr/bin/env bash
# GitZ bash completions
# Source this file: source completions/gitz.bash

_gitz() {
    local cur prev commands
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    commands="init add commit status diff log branch switch merge rebase stash reset undo tag blame gc config clone fetch push pull remote sync search review show clean shortlog worktree pack-refs"

    # Global options
    if [[ ${cur} == -* ]]; then
        COMPREPLY=( $(compgen -W "-h --help -v --version" -- "${cur}") )
        return 0
    fi

    # Command-specific completions
    if [[ ${COMP_CWORD} -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "${commands}" -- "${cur}") )
        return 0
    fi

    local cmd="${COMP_WORDS[1]}"
    case "${cmd}" in
        branch)
            if [[ ${prev} == -[dDm] ]]; then
                # Complete branch names
                local branches=$(git branch --format='%(refname:short)' 2>/dev/null || echo "")
                COMPREPLY=( $(compgen -W "${branches}" -- "${cur}") )
            elif [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "-d -D -m" -- "${cur}") )
            fi
            ;;
        switch)
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "-c" -- "${cur}") )
            else
                local branches=$(git branch --format='%(refname:short)' 2>/dev/null || echo "")
                COMPREPLY=( $(compgen -W "${branches}" -- "${cur}") )
            fi
            ;;
        rebase)
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "-i --interactive --abort --continue --onto" -- "${cur}") )
            else
                local branches=$(git branch --format='%(refname:short)' 2>/dev/null || echo "")
                COMPREPLY=( $(compgen -W "${branches}" -- "${cur}") )
            fi
            ;;
        merge)
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "--no-ff -m" -- "${cur}") )
            else
                local branches=$(git branch --format='%(refname:short)' 2>/dev/null || echo "")
                COMPREPLY=( $(compgen -W "${branches}" -- "${cur}") )
            fi
            ;;
        push)
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "--force -f" -- "${cur}") )
            else
                local remotes=$(git remote 2>/dev/null || echo "origin")
                COMPREPLY=( $(compgen -W "${remotes}" -- "${cur}") )
            fi
            ;;
        pull)
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "--merge -m --rebase -r" -- "${cur}") )
            else
                local remotes=$(git remote 2>/dev/null || echo "origin")
                COMPREPLY=( $(compgen -W "${remotes}" -- "${cur}") )
            fi
            ;;
        fetch)
            local remotes=$(git remote 2>/dev/null || echo "origin")
            COMPREPLY=( $(compgen -W "${remotes}" -- "${cur}") )
            ;;
        remote)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "add remove rename set-url get-url" -- "${cur}") )
            elif [[ ${prev} == add || ${prev} == remove || ${prev} == rename ]]; then
                local remotes=$(git remote 2>/dev/null || echo "origin")
                COMPREPLY=( $(compgen -W "${remotes}" -- "${cur}") )
            fi
            ;;
        reset)
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "--soft --mixed --hard" -- "${cur}") )
            fi
            ;;
        stash)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "push save list pop apply drop show clear" -- "${cur}") )
            fi
            ;;
        diff)
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "--staged --cached --no-color" -- "${cur}") )
            fi
            ;;
        log)
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "--oneline --graph --all --author --grep -n show" -- "${cur}") )
            fi
            ;;
        tag)
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "-a -m -d --delete -n --list" -- "${cur}") )
            fi
            ;;
        search)
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "--message -m --all -a --context -C --path -p" -- "${cur}") )
            fi
            ;;
        config)
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "--global --list -l" -- "${cur}") )
            fi
            ;;
        undo)
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "--soft --hard" -- "${cur}") )
            fi
            ;;
        add)
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "." -- "${cur}") )
            fi
            ;;
        init)
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "--bare" -- "${cur}") )
            fi
            ;;
        show)
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "--stat" -- "${cur}") )
            fi
            ;;
        clean)
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "-f -n -i -d -fd -fdx --dry-run --force --interactive --dirs" -- "${cur}") )
            fi
            ;;
        shortlog)
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "-s -n -e --summary --numbered --email" -- "${cur}") )
            fi
            ;;
        review)
            if [[ ${cur} == -* ]]; then
                COMPREPLY=( $(compgen -W "--stat -C --context" -- "${cur}") )
            else
                local branches=$(git branch --format='%(refname:short)' 2>/dev/null || echo "")
                COMPREPLY=( $(compgen -W "${branches}" -- "${cur}") )
            fi
            ;;
        worktree)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "add list ls remove rm prune lock unlock" -- "${cur}") )
            elif [[ ${prev} == add ]]; then
                COMPREPLY=( $(compgen -W "-b" -- "${cur}") )
            elif [[ ${prev} == remove || ${prev} == rm ]]; then
                COMPREPLY=( $(compgen -d -- "${cur}") )
            fi
            ;;
    esac

    return 0
}

complete -F _gitz gitz

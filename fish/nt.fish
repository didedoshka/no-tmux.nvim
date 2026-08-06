# no-tmux client: per-project nvim servers instead of tmux sessions.
# Shaped like tmux -- `nt a` attaches, `nt ls` lists, `nt ssh` is the entry
# point -- and bare `nt` is `nt a` on the cwd. readme.md is the spec.
function nt --description "no-tmux: per-project nvim servers (a|ls|ssh)"
    set -l cmd a
    if test (count $argv) -gt 0
        set cmd $argv[1]
        set -e argv[1]
    end

    switch $cmd
        case a attach
            __nt_attach $argv
        case ls list
            __nt_ls
        case ssh
            __nt_ssh $argv
        case '*'
            echo "nt: unknown subcommand '$cmd' (expected a, ls or ssh)" >&2
            return 1
    end
end

# Attach to the per-project server for a directory, starting it if needed --
# the tmux new/attach analogue (see notes/nvim-as-tmux.md). The server is
# detached from this login session (setsid) so ssh death never reaches it; the
# TUI client here is disposable: :detach or a dropped ssh leaves it running.
function __nt_attach
    if test (count $argv) -gt 0
        set -f dir (realpath $argv[1]); or return 1
    else
        set -f dir (pwd -P)
    end
    set -f sockdir ~/.cache/nvim/servers
    mkdir -p $sockdir
    # socket name is the project path, / encoded as % (decoded by :Connect)
    set -f sock $sockdir/(string replace -a / % $dir)

    if not nvim --server $sock --remote-expr 1 >/dev/null 2>&1
        rm -f $sock
        sh -c "cd '$dir' && setsid nvim --headless --listen '$sock' >/dev/null 2>&1 &"
        for i in (seq 50)
            test -S $sock; and break
            sleep 0.1
        end
        if not test -S $sock
            echo "nt: server for $dir did not come up" >&2
            return 1
        end
    end

    if set -q NVIM
        # Inside a server's :terminal a nested TUI is useless -- swing the host's
        # UI to the target instead. fnameescape because :connect %-expands its
        # argument and every socket name contains %.
        nvim --server $NVIM --remote-expr "execute('connect ' .. fnameescape('$sock'))" >/dev/null
    else
        nvim --server $sock --remote-ui
    end
end

# List per-project servers with liveness. Dead sockets (machine reboot,
# crashed server) are cleaned up on sight.
function __nt_ls
    set -l sockdir ~/.cache/nvim/servers
    for sock in $sockdir/*
        set -l name (string replace -a % / (basename $sock))
        if nvim --server $sock --remote-expr 1 >/dev/null 2>&1
            echo $name
        else
            rm -f $sock
            echo "$name (dead, removed)"
        end
    end
end

# iTerm entry point: ssh, then land in the home server -- the `tmux a || tmux`
# analogue. Worktree prep happens in a terminal tab there; `nt a <dir>` from
# that terminal hops this UI to the project server. After :detach (or if the
# server ever refuses to start) fish -C leaves an interactive shell on the box.
function __nt_ssh --wraps ssh
    ssh $argv -t '~/.local/bin/fish -C "nt a ~"'
end

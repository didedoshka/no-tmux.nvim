# no-tmux client: per-project nvim servers instead of tmux sessions.
# One verb -- `nt [dir]` starts-or-attaches, the tmux new/attach analogue (see
# notes/nvim-as-tmux.md) -- plus `nt --ls`, which is rare enough not to earn a
# subcommand. The ssh entry point is a raw line in the iTerm profile
# (readme.md), not a function here: the laptop holds no checkout.
#
# The server is detached from this login session (setsid) so ssh death never
# reaches it; the TUI client here is disposable: :detach or a dropped ssh
# leaves the server running.
function nt --description "attach to the project nvim server, starting it if needed"
    if test "$argv[1]" = --ls
        __nt_ls
        return
    end

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
        # env -u NVIM: launched from a server's :terminal the spawn inherits $NVIM,
        # and flatten.nvim makes the new instance forward to the host and exit --
        # the server dies silently before the socket ever appears (measured live).
        sh -c "cd '$dir' && setsid env -u NVIM nvim --headless --listen '$sock' >/dev/null 2>&1 &"
        for i in (seq 50)
            test -S $sock; and break
            sleep 0.1
        end
        if not test -S $sock
            echo "nt: server for $dir did not come up" >&2
            return 1
        end
    end

    # One UI per server (tmux attach -d): nvim sizes the shared grid to the
    # smallest attached UI, so a stale client (dead ssh, forgotten window)
    # shrinks every later one. chanclose detaches the UI and its client exits
    # 0 like :detach (measured), so an old window just ends its ssh session.
    # Skipped when the target is this terminal's own host -- the UI rendering
    # us is attached there, and killing it would kill us.
    if test "$sock" != "$NVIM"
        nvim --server $sock --remote-expr 'map(nvim_list_uis(), "chanclose(v:val.chan)")' >/dev/null 2>&1
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

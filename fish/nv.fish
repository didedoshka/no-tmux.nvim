# Attach to the per-project nvim server for a directory, starting it if
# needed -- the tmux new/attach analogue (see notes/nvim-as-tmux.md).
# The server is detached from this login session (setsid) so ssh death never
# reaches it; the TUI client here is disposable: :detach or a dropped ssh
# leaves the server running.
function nv --description "attach to the project nvim server, starting it if needed"
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
            echo "nv: server for $dir did not come up" >&2
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

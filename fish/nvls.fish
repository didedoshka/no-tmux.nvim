# List per-project nvim servers started by nv, with liveness. Dead sockets
# (machine reboot, crashed server) are cleaned up on sight.
function nvls --description "list project nvim servers"
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

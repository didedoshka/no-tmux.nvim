# iTerm entry point: ssh, then land in the home nvim server -- the
# `tmux a || tmux` analogue. Worktree prep happens in a terminal tab there;
# `nv <dir>` from that terminal hops this UI to the project server. After
# :detach (or if the server ever refuses to start) fish -C leaves an
# interactive shell on the box.
function nvsh --wraps ssh --description "ssh into the home nvim server"
    ssh $argv -t '~/.local/bin/fish -C "nv ~"'
end

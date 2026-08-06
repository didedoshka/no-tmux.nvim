# no-tmux.nvim

nvim as the tmux replacement: one detached headless nvim server per project, disposable TUI
clients, and hopping the UI between servers instead of switching tmux sessions. ssh → nvim,
nothing in between.

    laptop ──ssh──▶ nvim --remote-ui (client) ──unix socket──▶ nvim --listen (server)

The client renders grids and forwards input — it does not load config or plugins; init.lua,
LSP and terminal jobs all live in the server. One server per project: a crash costs one
project, `:Restart` is per-project, hopping is cheap.

Requires an nvim with `:detach` / `:connect` / `:restart` (v0.13.0-dev on this box); the
commands are existence-gated, so older builds simply get none of them. fzf-lua is optional
(`:FzfConnect` only); litre integration activates only when litre is already loaded.

## Install

lazy.nvim, local checkout:

    {
        dir = vim.fn.expand("~/personal/no-tmux.nvim"),
        config = function()
            require("nv").setup()
        end,
    }

fish half: symlink the functions into the autoload dir —

    ln -s ~/personal/no-tmux.nvim/fish/{nv,nvls,nvsh}.fish ~/.config/fish/functions/

## fish commands

| command | does |
| --- | --- |
| `nv [dir]` | start-or-attach the server for `dir` (default: cwd). Inside a `:terminal` (`$NVIM` set) it starts the server and swings the host's UI there instead of nesting a TUI |
| `nvls` | list servers with liveness; dead sockets are pruned on sight |
| `nvsh <ssh args>` | ssh wrapper: land in the home (`~`) server — the `tmux a \|\| tmux` analogue. Worktree prep happens in a terminal tab there, then `nv <dir>` hops onward. `:detach` drops to an interactive shell on the box |

Sockets live at `~/.cache/nvim/servers/`, named by absolute project path with `/` encoded
as `%`.

## nvim commands

| command | does |
| --- | --- |
| `:Restart` | `:restart` with the layout preserved: mksession (terminals excluded — restoring would respawn jobs) + `restart source` |
| `:Connect` | hop this UI to another live server, `vim.ui.select` picker |
| `:FzfConnect` | same hop, fzf-lua `fzf_exec` picker |

Trap, measured: `:connect` %-expands its argument, and every socket name contains `%` — all
hops go through `fnameescape` (E499 otherwise).

## quitguard

A server `:qa` kills running jobs silently. On `QuitPre`, while any terminal shell has a
running child or a litre task is alive, the quit fails (E37 via a hidden modified sentinel
buffer) and a notify names the jobs; an idle shell does not block. `:qa!` overrides — what
it kills is appended to `stdpath("state")/killed-jobs.txt` with cwd and command.

## SSH_AUTH_SOCK

Pinned server-side to `~/.ssh/ssh_auth_sock`; a bashrc login hook repoints that symlink at
every ssh login, so terminal buffers keep a working agent however old the server is (tmux
did this with `set-environment -g`). The pin happens whenever the symlink itself exists,
even dangling — a server started after its agent died still heals at the next login. Only
a box without the symlink at all is left alone.

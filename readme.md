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
            require("no-tmux").setup()
        end,
    }

fish half: symlink the function into the autoload dir —

    ln -s ~/personal/no-tmux.nvim/fish/nt.fish ~/.config/fish/functions/

## fish commands

| command | does |
| --- | --- |
| `nt [dir]` | start-or-attach the server for `dir` (default: cwd), detaching any client already on it (tmux `attach -d`). Inside a `:terminal` (`$NVIM` set) it starts the server and swings the host's UI there instead of nesting a TUI |
| `nt --ls` | list servers with liveness; dead sockets are pruned on sight |

One verb and one flag, not subcommands: attaching is the whole daily surface, and `--ls` is
rare. Nothing else is planned.

Sockets live at `~/.cache/nvim/servers/`, named by absolute project path with `/` encoded
as `%`.

One UI per server, always: nvim sizes the shared grid to the *smallest* attached UI, so a
stale client — dead ssh, forgotten window — shrinks every later one (measured: three
clients left two servers at 107×42 in a 215×89 terminal). Every attach therefore
`chanclose`s whatever UIs the target already has, the tmux `attach -d` that was never
optional here. The detach runs in an external client process with a 1s timeout: a target
wedged mid-command (half-typed count, hit-enter prompt) queues RPC without serving it, and
a synchronous request from the hopping server froze it and every UI on it (measured live).
On timeout the hop proceeds with the stale UI still attached — a clamped grid beats a
freeze. The detached client exits **0** like `:detach` (measured), so with the
iTerm line above the old window just ends its ssh session instead of falling into a shell.
The one exception: `nt` run from a `:terminal` of the *same* server it targets kills
nothing — the UI rendering that terminal is attached there, and closing it would close you.

## Connecting from the laptop

The laptop is a terminal and ssh, nothing else — no checkout, no functions. The iTerm
profile does the whole `tmux a || tmux` job with **Command: `Login Shell`** and **Send text
at start**:

    ssh <host> -t '~/.local/bin/fish -c "nt ~; or exec ~/.local/bin/fish"'

Every connection lands in the server rooted at `~`, the hub: worktree prep happens in a
terminal tab there (surviving disconnects, unlike a raw ssh shell), then `nt <dir>` hops
onward. `~/.local/bin/fish` is the *remote* fish, twice — the login shell and the fallback.

`:detach` ends the ssh session and drops you back to the laptop, the way detaching from
tmux did. That is what `fish -c` buys: it runs the one command and exits, so nothing holds
the connection open once the client is gone. The `; or` branch is the safety valve —
measured, `:detach` exits the `--remote-ui` client **0** and `nt` returns **1** when the
server never came up, so only the failure lands you in an interactive shell on the box
instead of bouncing you off a machine you cannot reach.

`Login Shell` rather than putting the ssh in iTerm's `Command` field so the closing session
lands back at a *local* prompt — reconnect is `↑`+`Enter`. Don't use iTerm's `SSH` profile
type: it injects shell integration and wants python3 remotely, both pointless when the
login immediately becomes a UI client.

## nvim commands

| command | does |
| --- | --- |
| `:Restart` | `:restart` with the layout preserved: mksession (terminals excluded — restoring would respawn jobs) + `restart source` |
| `:RestartAll` | `:Restart` for the whole fleet: every other server, then this one |
| `:Connect` | hop this UI to another live server, `vim.ui.select` picker |
| `:FzfConnect` | the pinned-servers picker (below); warns when there is nothing to list |

Hops detach the target's UIs first, same one-UI-per-server rule as `nt` (the hop targets
are always *other* servers, so this never closes the hopping UI itself).

Trap, measured: `:connect` %-expands its argument, and every socket name contains `%` — all
hops go through `fnameescape` (E499 otherwise). The same expansion bites `-S` and `:source`,
so `:RestartAll`'s label-derived session names are `fnameescape`d too.

`:RestartAll` restarts the other servers first, in parallel, then this one via `:Restart`.
The others have no UI attached, and `:restart` without a UI leaves a dangling server
process (`:h :restart`) — so each one is restarted by hand: its session is saved over RPC
(terminals excluded, session file per server under `stdpath("state")`), it is `:qall`ed,
respawned with its own `v:argv` in its own cwd (under `env -u NVIM` — jobstart sets `$NVIM`
in the job's env, and a respawn that sees it becomes a flatten guest and dies before its
socket appears, the same trap `nt` guards against), and the session is sourced back. The RPC
payload is self-contained Lua: a target still running a pre-`:RestartAll` build of the
plugin restarts fine. A server whose quitguard refuses the quit (jobs running) is skipped
and keeps its old config; when anything was skipped, the current server is *not* restarted —
the report would die with the UI — and the notify says to `:Restart` it manually. Typical
use: add a plugin spec to the config, `:RestartAll`, every server comes back on the new
config (lazy.nvim installs missing plugins at startup).

## Pinned servers

`:FzfConnect` opens an [fzf-pin](../fzf-pin.nvim) picker: pinned servers first as
`[e] /path/to/project`, then the other live ones. A pinned char hops immediately; a free
char pins the *current* server to that char (refused when this instance's socket is not a
no-tmux one); `ctrl-x` unpins; `i` drops into fuzzy search. Pins are stored globally by
project
label — the fzf-pin store, `servers` namespace — so they survive socket churn across
restarts. A pinned server with no live socket shows `(down)`; activating it starts the
server the way `nt` would (detached, in the project directory the label names) and hops
there once the socket appears — refused only when that directory no longer exists. The
current one shows `(this)`. The source is `require("no-tmux.server").source`.

## quitguard

A server `:qa` kills running jobs silently. On `ExitPre` — only a quit that would actually
end the session; `:q` on a split never triggers it — while any terminal shell has a running
child or a litre task is alive: with a UI attached, a `confirm()` prompt names the jobs and
asks stay / quit-and-kill; choosing quit exits normally. Staying, and any headless instance
(which cannot answer — notably `:RestartAll`'s rpc `:qall`, marked by `g:quitguard_auto`),
blocks the quit instead (E37 via a hidden modified sentinel buffer; headless also notifies
into `:messages`). An idle shell and an fzf-lua picker terminal (filetype `fzf`) never
block. `:qa!` always overrides — whatever quit goes through appends what it killed to
`stdpath("state")/killed-jobs.txt` with cwd and command.

A `:restart` quit (`v:exitreason` is `restart`/`restart!`) is exempt: no prompt, no block,
kills still logged. By the time the quit runs, `ex_restart` has already handed the socket
to the respawned server and told every UI to reattach to it on exit — refusing the quit
cancels the restart but leaves that reattach order armed forever, and the *next* real quit
kills the UI with `connection refused` (measured live). `:Restart` deliberately does not
ask first either — restarting is itself the considered act, and `killed-jobs.txt` keeps
the record of what to re-run.

## habit

`:qa` is the tmux-era reflex and now kills the session everything lives in; the move is
`:detach`. So `:q` and `:qa` print `habit` instead, like the config's `s`/`S`/`<C-o>`, and
only inside a server `nt` started — a throwaway `nvim file.txt` still quits normally.

Two exceptions, both deliberate: `:q` with another window or tab open closes the window as
always (there is no habit to unlearn in closing a split — it nags only when the quit would
end the session), and the `!` forms are untouched, since `:qa!` is the considered override
and the one quitguard points you at. Implemented as cmdline abbreviations to `:NtQ`/`:NtQa`,
which take a bang and pass it through; typed cmdline only, so a plugin's `:qa` still quits.

Pinned server-side to `~/.ssh/ssh_auth_sock`; a bashrc login hook repoints that symlink at
every ssh login, so terminal buffers keep a working agent however old the server is (tmux
did this with `set-environment -g`). The pin happens whenever the symlink itself exists,
even dangling — a server started after its agent died still heals at the next login. Only
a box without the symlink at all is left alone.

`$SHELL` and `'shell'` are pinned to fish the same way (tmux: `default-shell`): `'shell'`
is seeded from `$SHELL`, inherited from whatever spawned the server, so a respawn chain
that once passed through a bash environment (a `:terminal` running Claude Code, a
`:RestartAll` respawn) would otherwise leak bash into every `:term` from then on. A box
without fish is left alone.

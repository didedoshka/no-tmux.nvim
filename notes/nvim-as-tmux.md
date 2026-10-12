# nvim as tmux replacement

Goal: ssh → nvim, no tmux in between. Everything below verified against the
installed build (v0.13.0-dev-547) on 2026-07-19; `:detach`, `:connect`,
`:restart`, `--remote-ui` all present.

## Architecture

Both halves run on the dev box; the laptop is just a terminal + ssh, exactly as
with tmux. The client renders grids and forwards input — it does **not** load
config or plugins; init.lua, LSP, terminal jobs all live in the server.

    laptop ──ssh──▶ nvim --remote-ui (client) ──unix socket──▶ nvim --listen (server)

| tmux | nvim |
| --- | --- |
| `tmux new -s proj` | `nvim --listen ~/.cache/nvim/proj.sock`, detached (`setsid`/`systemd-run --user` — server must not be a child of the ssh session or SIGHUP kills it) |
| `tmux attach` | `nvim --server <sock> --remote-ui` |
| `prefix d` | `:detach` (abrupt ssh death has the same effect: server survives) |
| `switch-client` | `:connect <other sock>` |

Prefer one server **per project**, not one server with project tabs: a crash
(rare, but treesitter segfaults exist) then costs one project, `:restart` is
per-project, LSP memory growth is contained. `:connect` makes hopping cheap.
Tabs stay free for use within a project.

## Config updates without losing the session

`:restart` quits the server, re-execs it with the same argv, and reattaches all
UIs. `:mksession! Session.vim | restart source Session.vim` restores layout.
Also the plugin-update idiom: `:restart lua vim.pack.update()`.
Caveats from `:h :restart`: UI and server must be on the same machine; a UI
that doesn't handle the restart event leaves a dangling server.

What does *not* survive: terminal buffers (processes + scrollback). So the
whole plan is only comfortable if terminals are disposable — anything worth
keeping ran as a re-runnable brd task, and genuinely long-lived processes go to
`systemd-run --user`, not a terminal buffer. This couples the tmux-exit to the
brd redesign.

Fragility concerns that motivated tmux are mostly stale: LSP lifecycle was
overhauled in 0.11, a *client* crash never matters (only the headless server's),
and cheap `:restart` turns "session got weird" from catastrophe into seconds.
Remaining honest risk: `--remote-ui` is 0.12-era and still getting polish —
running nightly means occasionally being the person who finds the bug.

## SSH_AUTH_SOCK — current tmux solution carries over as-is

*Superseded 2026-10-12 (see the entry at the end): the link is now no-tmux's own and `nt`
writes it; the bashrc hook below lived only on the old box and never reached dotfiles.*

The working mechanism today (verified live: symlink fresh, agent answers
`ssh-add -l` through it):

1. `~/.bashrc` on each ssh login: `ln -sf "$SSH_AUTH_SOCK"
   ~/.ssh/ssh_auth_sock` (guarded so shells already using the link path don't
   clobber it). The copies in config.fish / `~/.ssh/rc` are commented-out
   remnants — bashrc is the live one, don't "clean it up".
2. tmux: `set-environment -g SSH_AUTH_SOCK "$HOME/.ssh/ssh_auth_sock"`.

nvim equivalent of step 2 is one server-side line in init.lua:

    vim.env.SSH_AUTH_SOCK = vim.fs.normalize("~/.ssh/ssh_auth_sock")

Terminal jobs inherit the server's env, the path never changes, so even
long-running shells keep a working agent after re-ssh — same property as tmux.
Step 1 stays untouched. Multiple concurrent logins: last one wins the symlink,
same as today.

No update-environment analogue is needed here: KRB5CCNAME is unset on this box
and nothing else in tmux's update-environment list is load-bearing. If some
per-session var ever matters, the attach wrapper can push it before attaching:
`nvim --server <sock> --remote-expr "setenv('VAR','$VAR')"`.

## Implemented 2026-07-19

- `plugin/server.lua`: pins SSH_AUTH_SOCK to the symlink; `:Restart` =
  mksession (terminals excluded) + `:restart source`; `:Connect` = pick
  another project server from `stdpath("cache")/servers` and hop.
- fish: `nt [dir]` starts (detached, socket at
  `~/.cache/nvim/servers/<path with / as %>`) and/or attaches with
  `--remote-ui`; `nt --ls` lists servers with liveness. Detach: `:detach` or
  just kill the ssh.
- `<leader>m` still runs plain `:restart` (loses layout); switch it to
  `:Restart` after the session flow proves itself.
- Not yet done: actually living in it. tmux config untouched; nothing forces
  the migration.

## Implemented 2026-08-06 — home server as the entry point

The `tmux a || tmux` analogue: every connection lands in a server rooted at `~`,
which acts as the hub — worktree prep happens in a terminal tab there (and so
survives disconnects, unlike a raw ssh shell), then `nt <dir>` hops onward.

- the iTerm profile (replaces tmuxsh):
  `ssh <host> -t '~/.local/bin/fish -c "nt ~; or exec ~/.local/bin/fish"'`.
  `fish -c` exits after the client does, so `:detach` ends the ssh session and
  drops back to the laptop, like detaching from tmux. Measured: `:detach` exits
  the `--remote-ui` client 0 and `nt` returns 1 when the server never came up,
  so `; or` only fires on failure — the safety valve against bouncing off a box
  whose server refuses to start.
- `nt` run inside a `:terminal` (`$NVIM` set) no longer nests a TUI: it starts
  the target server, then swings the host's UI there with
  `nvim --server $NVIM --remote-expr "execute('connect <sock>')"` (verified
  live: the UI count moves from one server to the other).
- Trap, measured: `:connect` %-expands its argument, and every socket name
  contains `%` — without `fnameescape` the hop dies with E499. `:Connect` had
  this bug for every real socket; all paths now go through fnameescape.
- `:FzfConnect` — fzf_exec picker over the other servers; `:Connect`
  (vim.ui.select) kept as the plain fallback. No keymaps by design.

## Implemented 2026-08-14 — one UI per server (tmux attach -d)

Measured live: three `nt ~` clients from stale ssh sessions (dead laptop
connections sshd had not reaped) left two servers clamped to 107×42 in a
215×89 terminal — nvim sizes the shared grid to the smallest attached UI.
Multiple UIs were never useful here, so every attach now detaches the rest:

- `nt` chancloses the target's UI channels before attaching (skipped when
  `$NVIM` equals the target socket — that UI is rendering us); `hop()` does
  the same over RPC before `:connect`, covering `:Connect`/`:FzfConnect`.
- Measured: `chanclose` on the UI channel makes the `--remote-ui` client
  exit **0**, same as `:detach` — the stale iTerm window ends its ssh
  session cleanly instead of hitting the `; or exec fish` valve.

## Implemented 2026-10-12 — nt owns the agent link

A fresh box (dotfiles installed, stock `~/.bashrc`) had no `~/.ssh/ssh_auth_sock`: the
bashrc login hook was never in dotfiles. The pin skipped silently, the `~` server kept the
raw `/tmp/ssh-*/agent.*` of the login that spawned it, and once that session ended every
terminal got "SSH agent connection failed".

- The writing half moves into no-tmux: `__nt_link_agent` (fish/nt.fish), called by every
  `nt` attach, which is the entry point of every iTerm login. Guarded: not inside `$NVIM`
  (a `:terminal`'s value is the link or a stale path), not when `SSH_AUTH_SOCK` already is
  the link, and only for a live socket (`test -S`).
- Dedicated name `~/.ssh/no-tmux-agent.sock` instead of `~/.ssh/ssh_auth_sock`, so a user's
  own agent handling for plain sessions coexists — neither side clobbers the other.
- Kept: last login wins; closing the newest of two sessions dangles the link until the next
  `nt` login. A repair-on-exit in `nt` would fail exactly when ssh drops (fish gets the
  hangup), so not worth it.
- e2e covers the helper under a sandboxed `fish -N`.

---
name: verify
description: Verify a no-tmux change actually works — the offline suite always, plus the live checks that need real servers, a real UI client, or the fish side.
---

# Verifying no-tmux

## Tier 1 — offline, always run this

```bash
tests/run.sh          # lua-language-server (baseline: 0 problems) + spec
tests/run.sh spec     # just the spec
tests/run.sh check    # just lua-language-server
```

The spec runs end-to-end on `nvim --clean`: command registration and
existence-gating, `setup()` re-running cleanly, the quitguard's whole
sentinel lifecycle against real terminal jobs and a stubbed liter, the
SSH_AUTH_SOCK pin under a fabricated `$HOME`, and `:Connect`'s listing
against a sandboxed `XDG_CACHE_HOME`. A PostToolUse hook runs the whole
suite on every Lua edit. There is no standalone lua on this box;
`nvim --clean -l` is the runtime. Run lua-language-server from the repo
root or `.luarc.json` is not found.

## Tier 2 — e2e, live headless servers, still offline

```bash
tests/run.sh e2e      # tests/e2e.sh; ~5s, so not part of "all"
```

Starts real detached `--listen` servers with `HOME` and every XDG dir
sandboxed under a mktemp tree (the real `~/.cache/nvim/servers` is never
touched): the SSH_AUTH_SOCK pin at startup and its inheritance by terminal
jobs, `:Connect` excluding the server's own socket, and quitguard against a
real `:qa` / `:qa!` including the killed-jobs.txt log.

## Tier 3 — needs a real UI or a human

The spec cannot hop between servers or see a UI. After changes to these,
check by hand:

- **quitguard's confirm prompt**: the spec and e2e are headless (zero UIs), so
  they only ever exercise the blocking branch. The prompt on a busy `:qa`,
  "quit and kill" actually exiting, and "stay" leaving just the bare E37 need
  a real UI.
- **a real hop**: needs two live servers and a `--remote-ui` client. Verify
  with `--remote-expr 'len(nvim_list_uis())'` on both sides before claiming a
  hop works — a hop that "returned" can still have left zero UIs attached.
- **`:Connect` escaping**: every socket name contains `%`; a path that avoids
  `fnameescape` is E499 in a live client even though the spec passes.
- **the fish half** (`nt`, `nt --ls`): the tests never touch fish.
  Exercise from a real shell; the iTerm ssh line additionally needs an ssh session.
- **SSH_AUTH_SOCK against a real agent**: e2e proves the pin mechanics; that
  `ssh -A` actually authenticates from a terminal buffer in a server that
  outlived its original ssh session still needs a human.

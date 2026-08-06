---
name: verify
description: Verify an nv change actually works — the offline suite always, plus the live checks that need real servers, a real UI client, or the fish side.
---

# Verifying nv

## Tier 1 — offline, always run this

```bash
tests/run.sh          # lua-language-server (baseline: 0 problems) + spec
tests/run.sh spec     # just the spec
tests/run.sh check    # just lua-language-server
```

The spec runs end-to-end on `nvim --clean`: command registration and
existence-gating, `setup()` re-running cleanly, and the quitguard's whole
sentinel lifecycle against real terminal jobs and a stubbed litre. A
PostToolUse hook runs the whole suite on every Lua edit. There is no
standalone lua on this box; `nvim --clean -l` is the runtime. Run
lua-language-server from the repo root or `.luarc.json` is not found.

## Tier 2 — needs live servers or a human

The spec cannot hop between servers or see a UI. After changes to these,
check by hand:

- **a real hop**: needs two live servers and a `--remote-ui` client. Verify
  with `--remote-expr 'len(nvim_list_uis())'` on both sides before claiming a
  hop works — a hop that "returned" can still have left zero UIs attached.
- **`:Connect` escaping**: every socket name contains `%`; a path that avoids
  `fnameescape` is E499 in a live client even though the spec passes.
- **the fish half** (`nv`, `nvls`, `nvsh`): the spec never touches fish.
  Exercise from a real shell; `nvsh` additionally needs an ssh session.
- **SSH_AUTH_SOCK pin**: needs a server that outlived its original ssh
  session — check `:echo $SSH_AUTH_SOCK` points at the pinned path.

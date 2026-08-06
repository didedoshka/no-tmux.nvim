# no-tmux.nvim — session rules

nvim-as-tmux machinery: per-project headless nvim servers (lua half) plus the fish client
commands (fish/). Personal project, single user, loaded from a local checkout via
lazy.nvim. Extracted from the nvim config's `plugin/` 2026-08-06.

## Layout
- `lua/nv/init.lua` — `setup()`, nothing else. `server.lua` = SSH_AUTH_SOCK pin, `:Restart`,
  `:Connect`/`:FzfConnect`. `quitguard.lua` = the `:qa` job guard.
- `fish/` — canonical `nv`/`nvls`/`nvsh`; `~/.config/fish/functions/` holds symlinks here.
- **`readme.md` is the spec** — a behaviour change is incomplete until it matches.
- `notes/nvim-as-tmux.md` — the research and dated implementation log.

## Invariants
- Commands are existence-gated on `:connect`/`:restart` — older nvim builds must load
  cleanly and simply get fewer commands.
- fzf-lua and litre stay optional: fzf-lua required only inside `:FzfConnect`'s callback,
  litre only via `package.loaded` (the guard must never be what loads it).
- `setup()` must re-run cleanly: commands replace themselves, the quitguard augroup clears,
  the sentinel buffer is reused via `vim.g`.
- `:connect` %-expands its argument and every socket name contains `%` — every hop goes
  through `fnameescape` (E499 otherwise, measured live).

## Verify
- `tests/run.sh` — `lua-language-server --check` (baseline **0 problems**; run from repo
  root or `.luarc.json` is not found) + the spec under `nvim --clean`. The spec cannot
  exercise a real UI hop; that needs two live servers and a `--remote-ui` client — check UI
  counts with `--remote-expr 'len(nvim_list_uis())'` before claiming a hop works.

## Style & workflow
- 4-space indent, double quotes, ~100 cols; formatting via lua_ls/EmmyLuaCodeStyle
  (`.luarc.json`), no stylua.
- Commit each verified change without asking (`area: lowercase summary`,
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`). Never rewrite history — no
  amend, rebase, or reset past a commit; fix forward with a new commit.

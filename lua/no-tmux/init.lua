-- nvim-as-tmux: per-project headless servers instead of tmux sessions.
-- This is the server-side half; the client half is fish (fish/nt.fish --
-- `nt a` starts/attaches, `nt ls` lists, `nt ssh` is the entry point).
-- readme.md is the spec; notes/nvim-as-tmux.md the research.
local M = {}

function M.setup()
    require("no-tmux.server").setup()
    require("no-tmux.quitguard").setup()
end

return M

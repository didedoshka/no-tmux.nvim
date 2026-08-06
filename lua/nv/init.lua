-- nvim-as-tmux: per-project headless servers instead of tmux sessions.
-- This is the server-side half; the client half is fish (fish/nv.fish
-- starts/attaches, nvls lists, nvsh is the ssh entry point).
-- readme.md is the spec; notes/nvim-as-tmux.md the research.
local M = {}

function M.setup()
    require("nv.server").setup()
    require("nv.quitguard").setup()
end

return M

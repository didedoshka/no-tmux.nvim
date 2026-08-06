-- Loads the plugin under nvim --clean and checks the public surface. A real
-- UI hop between servers cannot happen here (no --remote-ui client) -- that
-- is a live check, see CLAUDE.md.
local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))))
vim.opt.rtp:prepend(repo)

local failed = 0
local function check(name, ok)
    if ok then
        print("  ok    " .. name)
    else
        print("  FAIL  " .. name)
        failed = failed + 1
    end
end

require("nv").setup()

-- commands are existence-gated on the host build's :connect/:restart
local cmds = vim.api.nvim_get_commands({})
check(":Connect registered", vim.fn.exists(":connect") ~= 2 or cmds.Connect ~= nil)
check(":FzfConnect registered", vim.fn.exists(":connect") ~= 2 or cmds.FzfConnect ~= nil)
check(":Restart registered", vim.fn.exists(":restart") ~= 2 or cmds.Restart ~= nil)
check("quitguard QuitPre+VimLeavePre", #vim.api.nvim_get_autocmds({ group = "quitguard" }) == 2)

-- re-running setup must not error or duplicate autocmds
require("nv").setup()
check("setup re-runs cleanly", #vim.api.nvim_get_autocmds({ group = "quitguard" }) == 2)

-- an idle instance must not be blocked from quitting: QuitPre with no busy
-- terminals and no litre tasks leaves no modified sentinel behind
vim.api.nvim_exec_autocmds("QuitPre", {})
local sentinel = vim.g.quitguard_sentinel
check("idle quit unblocked", sentinel == nil or not vim.bo[sentinel].modified)

if failed > 0 then
    print(("%d checks failed"):format(failed))
    os.exit(1)
end
print("spec: all passed")

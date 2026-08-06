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

-- quitguard arms its sentinel while a busy terminal exists. The block itself
-- is nvim core (a modified buffer fails :qa with E37); the guard's own
-- contract is the sentinel's modified flag on QuitPre.
do
    local term = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(term)
    -- sh as the "shell", sleep as the thing running in it: busy means the
    -- shell has children, so a direct job would not arm the guard
    local job = vim.fn.jobstart({ "sh", "-c", "sleep 30" }, { term = true })
    check("terminal job started", job > 0)
    local pid = vim.b[term].terminal_job_pid
    check("shell spawned its child", vim.wait(2000, function()
        local alive, kids = pcall(vim.api.nvim_get_proc_children, pid)
        return alive and #kids > 0
    end))

    vim.api.nvim_exec_autocmds("QuitPre", {})
    local buf = vim.g.quitguard_sentinel
    check("sentinel created", buf and vim.api.nvim_buf_is_valid(buf))
    check("sentinel armed with a busy terminal", vim.bo[buf].modified)
    check("sentinel line names the running command",
        vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:find("sleep", 1, true) ~= nil)

    -- shell gone: QuitPre must disarm
    vim.fn.jobstop(job)
    vim.wait(1000, function()
        return not pcall(vim.api.nvim_get_proc, pid)
    end)
    vim.api.nvim_exec_autocmds("QuitPre", {})
    check("sentinel disarmed with the shell gone", not vim.bo[buf].modified)

    vim.api.nvim_buf_delete(term, { force = true })
end

-- quitguard arms its sentinel while a litre task runs, and only then
do
    package.loaded["litre.runner"] = {
        running_tasks = function()
            return { { id = "build" } }
        end,
    }

    vim.api.nvim_exec_autocmds("QuitPre", {})
    local buf = vim.g.quitguard_sentinel
    check("sentinel created for litre task", buf and vim.api.nvim_buf_is_valid(buf))
    check("sentinel armed with a task running", vim.bo[buf].modified)
    check("sentinel line names the running task",
        vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:find("litre build", 1, true) ~= nil)

    -- the flag self-clears right after the quit attempt it blocked
    check("sentinel self-clears after the quit attempt", vim.wait(1000, function()
        return not vim.bo[buf].modified
    end))

    -- no running tasks: QuitPre must leave the sentinel unmodified
    package.loaded["litre.runner"] = {
        running_tasks = function()
            return {}
        end,
    }
    vim.api.nvim_exec_autocmds("QuitPre", {})
    check("sentinel unarmed with nothing running", not vim.bo[buf].modified)

    package.loaded["litre.runner"] = nil
end

if failed > 0 then
    print(("%d checks failed"):format(failed))
    os.exit(1)
end
print("spec: all passed")

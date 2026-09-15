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

require("no-tmux").setup()

-- commands are existence-gated on the host build's :connect/:restart
local cmds = vim.api.nvim_get_commands({})
check(":Connect registered", vim.fn.exists(":connect") ~= 2 or cmds.Connect ~= nil)
check(":FzfConnect registered", vim.fn.exists(":connect") ~= 2 or cmds.FzfConnect ~= nil)
check(":Restart registered", vim.fn.exists(":restart") ~= 2 or cmds.Restart ~= nil)
check(":RestartAll registered", vim.fn.exists(":restart") ~= 2 or cmds.RestartAll ~= nil)
check("quitguard ExitPre+VimLeavePre", #vim.api.nvim_get_autocmds({ group = "quitguard" }) == 2)

-- re-running setup must not error or duplicate autocmds
require("no-tmux").setup()
check("setup re-runs cleanly", #vim.api.nvim_get_autocmds({ group = "quitguard" }) == 2)

-- an idle instance must not be blocked from quitting: ExitPre with no busy
-- terminals and no litre tasks leaves no modified sentinel behind
vim.api.nvim_exec_autocmds("ExitPre", {})
local sentinel = vim.g.quitguard_sentinel
check("idle quit unblocked", sentinel == nil or not vim.bo[sentinel].modified)

-- quitguard arms its sentinel while a busy terminal exists. The block itself
-- is nvim core (a modified buffer fails :qa with E37); the guard's own
-- contract is the sentinel's modified flag on ExitPre.
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

    check("running() names the shell's child",
        vim.tbl_contains(require("no-tmux.quitguard").running(term), "sleep"))
    local desc = table.concat(require("no-tmux.quitguard").describe(term), "\n")
    check("describe() heads with the bufnr", desc:find("^term " .. term .. ":") ~= nil)
    check("describe() has the shell's cwd", desc:find("\n  cwd: ", 1, true) ~= nil)
    check("describe() has the full command line", desc:find("running: sleep 30", 1, true) ~= nil)

    -- :Restart lists the terminal and what it runs, and only enter goes on.
    -- Headless, ask() has nobody to ask and answers false on its own; a stub
    -- captures what it would have shown
    if vim.fn.exists(":restart") == 2 then
        local quitguard = require("no-tmux.quitguard")
        check("ask() headless answers false", quitguard.ask({ "x" }, "y") == false)
        local asked, verb
        local ask = quitguard.ask
        ---@diagnostic disable-next-line: duplicate-set-field
        quitguard.ask = function(lines, v)
            asked, verb = table.concat(lines, "\n"), v
            return false
        end
        vim.cmd("Restart")
        quitguard.ask = ask
        check(":Restart asks before killing the terminal",
            asked ~= nil and asked:find("term " .. term .. ":", 1, true) ~= nil)
        check(":Restart prompt names the running command",
            asked ~= nil and asked:find("running: sleep 30", 1, true) ~= nil)
        check(":Restart is the enter verb", verb == "restart")
        check(":Restart cancelled keeps the terminal", vim.api.nvim_buf_is_valid(term))
    end

    vim.api.nvim_exec_autocmds("ExitPre", {})
    local buf = vim.g.quitguard_sentinel
    check("sentinel created", buf and vim.api.nvim_buf_is_valid(buf))
    check("sentinel armed with a busy terminal", vim.bo[buf].modified)
    check("sentinel line names the running command",
        vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:find("sleep", 1, true) ~= nil)

    -- shell gone: ExitPre must disarm
    vim.fn.jobstop(job)
    vim.wait(1000, function()
        return not pcall(vim.api.nvim_get_proc, pid)
    end)
    vim.api.nvim_exec_autocmds("ExitPre", {})
    check("sentinel disarmed with the shell gone", not vim.bo[buf].modified)

    vim.api.nvim_buf_delete(term, { force = true })
end

-- an fzf-lua picker terminal, even with fzf still alive in it, must not block
do
    local term = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(term)
    local job = vim.fn.jobstart({ "sh", "-c", "sleep 30" }, { term = true })
    vim.bo[term].filetype = "fzf"
    local pid = vim.b[term].terminal_job_pid
    check("fzf shell spawned its child", vim.wait(2000, function()
        local alive, kids = pcall(vim.api.nvim_get_proc_children, pid)
        return alive and #kids > 0
    end))

    vim.api.nvim_exec_autocmds("ExitPre", {})
    local buf = vim.g.quitguard_sentinel
    check("fzf picker does not arm the guard", buf == nil or not vim.bo[buf].modified)

    vim.fn.jobstop(job)
    vim.api.nvim_buf_delete(term, { force = true })
end

-- quitguard arms its sentinel while a litre task runs, and only then
do
    package.loaded["litre.runner"] = {
        running_tasks = function()
            return { { id = "build" } }
        end,
    }

    vim.api.nvim_exec_autocmds("ExitPre", {})
    local buf = vim.g.quitguard_sentinel
    check("sentinel created for litre task", buf and vim.api.nvim_buf_is_valid(buf))
    check("sentinel armed with a task running", vim.bo[buf].modified)
    check("sentinel line names the running task",
        vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:find("litre build", 1, true) ~= nil)

    -- the flag self-clears right after the quit attempt it blocked
    check("sentinel self-clears after the quit attempt", vim.wait(1000, function()
        return not vim.bo[buf].modified
    end))

    -- no running tasks: ExitPre must leave the sentinel unmodified
    package.loaded["litre.runner"] = {
        running_tasks = function()
            return {}
        end,
    }
    vim.api.nvim_exec_autocmds("ExitPre", {})
    check("sentinel unarmed with nothing running", not vim.bo[buf].modified)

    package.loaded["litre.runner"] = nil
end

-- SSH_AUTH_SOCK pin: setup() pins the env to ~/.ssh/ssh_auth_sock, and only
-- when that path exists. Production is a symlink kept fresh by the bashrc
-- login hook; a plain file stats the same, so it stands in here.
do
    local saved_home = vim.env.HOME
    local saved_sock = vim.env.SSH_AUTH_SOCK

    local home = vim.fn.tempname()
    vim.fn.mkdir(home .. "/.ssh", "p")
    vim.env.HOME = home
    vim.env.SSH_AUTH_SOCK = "/run/original-agent.sock"

    require("no-tmux.server").setup()
    check("SSH_AUTH_SOCK untouched while ~/.ssh/ssh_auth_sock is absent",
        vim.env.SSH_AUTH_SOCK == "/run/original-agent.sock")

    local pin = home .. "/.ssh/ssh_auth_sock"
    vim.fn.writefile({}, pin)
    require("no-tmux.server").setup()
    check("SSH_AUTH_SOCK pinned once ~/.ssh/ssh_auth_sock exists", vim.env.SSH_AUTH_SOCK == pin)

    -- the symlink dangles whenever the session that made its target has
    -- ended; the pin must still happen -- the next login repoints it
    vim.fn.delete(pin)
    vim.uv.fs_symlink(home .. "/gone-agent.sock", pin)
    vim.env.SSH_AUTH_SOCK = "/run/original-agent.sock"
    require("no-tmux.server").setup()
    check("SSH_AUTH_SOCK pinned while the symlink dangles", vim.env.SSH_AUTH_SOCK == pin)

    vim.env.HOME = saved_home
    vim.env.SSH_AUTH_SOCK = saved_sock
    vim.fn.delete(home, "rf")
end

-- :Connect: warns when the socket dir holds nothing else, and labels decode
-- % back to /. run.sh sandboxes XDG_CACHE_HOME, so the real servers are
-- never listed here. Self-exclusion and the actual hop need live servers --
-- that is e2e.sh territory.
if vim.fn.exists(":connect") == 2 then
    local dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "servers")

    local notified
    local saved_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, _level, _opts)
        notified = msg
    end
    vim.cmd("Connect")
    vim.notify = saved_notify
    check(":Connect warns with no other servers", notified == "no other servers")

    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({}, vim.fs.joinpath(dir, "%data%project%x"))
    local items
    local saved_select = vim.ui.select
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(list, _, on_choice)
        items = list
        on_choice(nil) -- cancel: hopping needs a live socket
    end
    vim.cmd("Connect")
    vim.ui.select = saved_select
    check(":Connect lists the socket", items ~= nil and #items == 1)
    check(":Connect decodes % to / in the label",
        items ~= nil and items[1] ~= nil and items[1].label == "/data/project/x")
end

-- The fzf-pin server source: pins render first with their chars and a
-- liveness marker, free-char pinning is guarded, unpin round-trips the store.
-- The sibling checkout is the dependency, like lazy.nvim loads it for real.
-- run.sh sandboxes XDG_STATE_HOME, so the real pins are never touched.
do
    vim.opt.rtp:prepend(vim.fn.expand("~/personal/fzf-pin.nvim"))
    local store = require("fzf-pin.store")
    local source = require("no-tmux.server").source

    local dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "servers")
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({}, vim.fs.joinpath(dir, "%data%project%x"))

    store.save("servers", { e = "/data/project/gone" })
    local items = source.list()
    check("source: pin listed first with its char",
        items[1] ~= nil and items[1].char == "e")
    check("source: dead pin marked down",
        items[1] ~= nil and items[1].label == "/data/project/gone  (down)")
    check("source: live socket listed after the pins",
        items[2] ~= nil and items[2].char == nil and items[2].label == "/data/project/x")

    store.save("servers", { e = "/data/project/x" })
    items = source.list()
    check("source: a pinned live server appears once, keyed",
        #items == 1 and items[1].char == "e" and items[1].label == "/data/project/x")

    -- under --clean this instance's socket is not in the servers dir, so
    -- pinning must refuse instead of storing a garbage label
    local notified
    local saved_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, _level, _opts)
        notified = msg
    end
    source.pin("a")
    vim.notify = saved_notify
    check("source: pin refused outside a no-tmux socket",
        notified ~= nil and notified:find("nothing to pin") ~= nil)
    check("source: refused pin stored nothing", store.load("servers").a == nil)

    -- activating a down pin starts its server -- but never when the project
    -- directory itself is gone; spawning is e2e territory, the guard is not
    notified = nil
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, _level, _opts)
        notified = msg
    end
    source.activate({ data = "/data/project/gone" })
    vim.notify = saved_notify
    check("source: activate refuses to start when the project dir is gone",
        notified ~= nil and notified:find("directory gone") ~= nil)

    check("source: unpin removes the char",
        source.unpin({ char = "e" }) == nil and store.load("servers").e == nil)
    check("source: unpin on an unpinned entry is a no-op",
        source.unpin({ label = "/data/project/x" }) == nil)
end

-- The :q/:qa habit block. setup() above ran outside a server (v:servername is
-- not in the servers dir), so it must have installed nothing -- then install
-- it by hand and check the three behaviours. The bang paths really quit and
-- so cannot be exercised here; they are covered live (see CLAUDE.md).
do
    check("habit not installed outside an nt server", vim.api.nvim_get_commands({}).NtQ == nil)

    require("no-tmux.habit").setup()
    local cmds2 = vim.api.nvim_get_commands({})
    check("habit: NtQ registered", cmds2.NtQ ~= nil)
    check("habit: NtQa registered", cmds2.NtQa ~= nil)
    check("habit: q abbreviated", vim.api.nvim_exec2("cabbrev q", { output = true }).output:find("NtQ") ~= nil)
    check("habit: qa abbreviated", vim.api.nvim_exec2("cabbrev qa", { output = true }).output:find("NtQa") ~= nil)

    check("habit: :qa nags instead of quitting",
        vim.trim(vim.api.nvim_exec2("NtQa", { output = true }).output) == "habit")

    -- :q closes a split as always; it only nags when it would end the session
    vim.cmd("split")
    local before = #vim.api.nvim_tabpage_list_wins(0)
    vim.cmd("NtQ")
    check("habit: :q still closes a split", #vim.api.nvim_tabpage_list_wins(0) == before - 1)
    check("habit: :q nags on the last window",
        vim.trim(vim.api.nvim_exec2("NtQ", { output = true }).output) == "habit")
end

if failed > 0 then
    print(("%d checks failed"):format(failed))
    os.exit(1)
end
print("spec: all passed")

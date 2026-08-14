-- Per-project server support: SSH_AUTH_SOCK pinning, :Restart with layout,
-- and hopping the UI between servers (:Connect / :FzfConnect).
local M = {}

local function servers_dir()
    return vim.fs.joinpath(vim.fn.stdpath("cache"), "servers")
end

-- socket names are the project path, / encoded as %
local function decode(name)
    return (name:gsub("%%", "/"))
end
local function encode(label)
    return (label:gsub("/", "%%"))
end

local function other_servers()
    local servers = {}
    for name in vim.fs.dir(servers_dir()) do
        local path = vim.fs.joinpath(servers_dir(), name)
        if path ~= vim.v.servername then
            table.insert(servers, { path = path, label = decode(name) })
        end
    end
    return servers
end

-- nil when this instance's socket does not live in the servers dir (a server
-- started outside `nt` has no label to pin)
local function current_label()
    local name = vim.v.servername or ""
    if vim.fs.dirname(name) ~= servers_dir() then
        return nil
    end
    return decode(vim.fs.basename(name))
end

-- true only in a server `nt` started, which is the one place where quitting is
-- the wrong reflex (habit.lua) -- a throwaway `nvim file.txt` is not one
function M.is_nt_server()
    return current_label() ~= nil
end

-- One UI per server (tmux attach -d): detach whatever is attached to the
-- target before swinging ours there -- nvim sizes the shared grid to the
-- smallest attached UI, so a stale client clamps every later one. The
-- detached client exits 0 like :detach (measured live).
local function detach_uis(path)
    local connected, chan = pcall(vim.fn.sockconnect, "pipe", path, { rpc = true })
    if not connected or chan == 0 then
        return
    end
    pcall(vim.rpcrequest, chan, "nvim_exec_lua",
        "for _, ui in ipairs(vim.api.nvim_list_uis()) do vim.fn.chanclose(ui.chan) end", {})
    pcall(vim.fn.chanclose, chan)
end

-- :connect %-expands its argument, and every socket name contains % --
-- fnameescape or the hop dies with E499 (verified live).
local function hop(path)
    detach_uis(path)
    vim.cmd("connect " .. vim.fn.fnameescape(path))
end

-- poll cond every 100ms until it holds (-> ok) or tries run out (-> fail);
-- cond runs on the uv thread, so libuv only in there
local function poll(tries, cond, ok, fail)
    local timer = assert(vim.uv.new_timer())
    timer:start(100, 100, function()
        if cond() then
            timer:close()
            vim.schedule(ok)
        else
            tries = tries - 1
            if tries <= 0 then
                timer:close()
                vim.schedule(fail)
            end
        end
    end)
end

-- A pinned server with no socket: start it the way `nt` would -- detached,
-- `env -u NVIM` (the flatten-guest trap, same as restart_other), cwd = the
-- label, which is the project path -- then hop once the socket appears.
local function start_and_hop(label, path)
    if vim.fn.isdirectory(label) == 0 then
        vim.notify(label .. ": directory gone, cannot start", vim.log.levels.WARN)
        return
    end
    local cmd = { "env", "-u", "NVIM", "nvim", "--headless", "--listen", path }
    local spawned, job = pcall(vim.fn.jobstart, cmd, { cwd = label, detach = true })
    if not spawned or job <= 0 then
        return vim.notify(label .. ": server did not spawn", vim.log.levels.WARN)
    end
    vim.notify("starting server for " .. label)
    poll(50, function()
        return vim.uv.fs_stat(path) ~= nil
    end, function()
        hop(path)
    end, function()
        vim.notify(label .. ": server did not come up", vim.log.levels.WARN)
    end)
end

-- Sent over RPC to the server being restarted. Self-contained on purpose:
-- the target is still running whatever plugin version it loaded at startup,
-- so nothing here may call into no-tmux on that side.
local SAVE_AND_DESCRIBE = [[
    local file = ...
    local saved = vim.o.sessionoptions
    vim.opt.sessionoptions:remove("terminal")
    vim.cmd("mksession! " .. vim.fn.fnameescape(file))
    vim.o.sessionoptions = saved
    return { argv = vim.v.argv, cwd = vim.fn.getcwd() }
]]

-- Restart a server this UI is not attached to. :restart itself is out: with
-- no UI to handle the "restart" event it leaves a dangling server process
-- (:h :restart). So by hand, the way `nt` would: save its session over RPC,
-- :qall it (quitguard may refuse -- then it is skipped), respawn its own
-- argv in its own cwd, and source the session back. done(nil) on success,
-- done(reason) otherwise.
function M.restart_other(s, done)
    local connected, chan = pcall(vim.fn.sockconnect, "pipe", s.path, { rpc = true })
    if not connected or chan == 0 then
        return done(s.label .. ": dead socket, skipped")
    end
    local sess = vim.fs.joinpath(vim.fn.stdpath("state"),
        "restart-session-" .. encode(s.label) .. ".vim")
    local saved, info = pcall(vim.rpcrequest, chan, "nvim_exec_lua", SAVE_AND_DESCRIBE, { sess })
    if not saved then
        pcall(vim.fn.chanclose, chan)
        return done(s.label .. ": session save failed, skipped")
    end
    -- notify, not request: on a clean quit the reply channel dies with the server.
    -- g:quitguard_auto keeps the guard non-interactive: a busy target with a UI
    -- attached elsewhere must refuse and be skipped, not pop a prompt over there
    vim.rpcnotify(chan, "nvim_exec_lua",
        [[vim.g.quitguard_auto = 1; pcall(vim.cmd, "qall"); vim.g.quitguard_auto = nil]], {})
    poll(30, function()
        return not vim.uv.fs_stat(s.path)
    end, function()
        -- jobstart sets $NVIM in the job's env, and a respawn that sees it
        -- becomes a flatten guest and dies before its socket appears (the
        -- nt.fish trap, measured live) -- jobstart cannot unset a var, so
        -- strip it with an env(1) wrapper instead
        local cmd = vim.list_extend({ "env", "-u", "NVIM" }, info.argv)
        local spawned, job = pcall(vim.fn.jobstart, cmd, { cwd = info.cwd, detach = true })
        if not spawned or job <= 0 then
            return done(s.label .. ": did not respawn")
        end
        poll(100, function()
            return vim.uv.fs_stat(s.path) ~= nil
        end, function()
            local reachable, chan2 = pcall(vim.fn.sockconnect, "pipe", s.path, { rpc = true })
            if not reachable or chan2 == 0 then
                return done(s.label .. ": respawned but unreachable")
            end
            -- the session name is label-derived and contains % -- fnameescape
            -- or :source dies with E499, same trap as :connect
            vim.rpcnotify(chan2, "nvim_command", "source " .. vim.fn.fnameescape(sess))
            pcall(vim.fn.chanclose, chan2)
            done(nil)
        end, function()
            done(s.label .. ": did not come back up")
        end)
    end, function()
        pcall(vim.fn.chanclose, chan)
        done(s.label .. ": still running (quitguard blocking?), skipped")
    end)
end

-- The server list as an fzf-pin source: pins first (chars persisted globally
-- by project label -- sockets churn on restarts, labels do not), then the
-- other live servers. A free char pins the current server, ctrl-x unpins.
M.source = {
    prompt = "servers> ",
    list = function()
        local pins = require("fzf-pin.store").load("servers")
        local live = {}
        for _, s in ipairs(other_servers()) do
            live[s.label] = true
        end
        local cur = current_label()
        local chars = vim.tbl_keys(pins)
        table.sort(chars)
        local items, pinned = {}, {}
        for _, c in ipairs(chars) do
            local label = pins[c]
            pinned[label] = true
            local state = label == cur and "  (this)"
                or not live[label] and "  (down)" or ""
            table.insert(items, { label = label .. state, char = c, data = label })
        end
        for _, s in ipairs(other_servers()) do
            if not pinned[s.label] then
                table.insert(items, { label = s.label, data = s.label })
            end
        end
        return items
    end,
    activate = function(item)
        if item.data == current_label() then
            return
        end
        local path = vim.fs.joinpath(servers_dir(), encode(item.data))
        if not vim.uv.fs_stat(path) then
            start_and_hop(item.data, path)
            return
        end
        hop(path)
    end,
    pin = function(char)
        local store = require("fzf-pin.store")
        local cur = current_label()
        if not cur then
            vim.notify("current server is not a no-tmux socket -- nothing to pin",
                vim.log.levels.WARN)
            return
        end
        local pins = store.load("servers")
        for c, label in pairs(pins) do
            if label == cur then
                vim.notify("already pinned on " .. c .. " (ctrl-x it to move)",
                    vim.log.levels.WARN)
                return
            end
        end
        pins[char] = cur
        store.save("servers", pins)
        vim.notify(("pinned %s to %s"):format(cur, char))
    end,
    unpin = function(item)
        if not item.char then
            return
        end
        local store = require("fzf-pin.store")
        local pins = store.load("servers")
        pins[item.char] = nil
        store.save("servers", pins)
        return true
    end,
}

function M.setup()
    -- The bashrc login hook repoints ~/.ssh/ssh_auth_sock at every ssh login;
    -- pinning the env to that stable path keeps ssh -A working in every
    -- terminal buffer however old the server is (tmux did this with
    -- set-environment -g). lstat, not stat: the symlink dangles whenever the
    -- session that created its /tmp/ssh-*/agent.* target has ended, and a
    -- server started in that window must still pin -- the next login makes
    -- it valid. Only a box without the symlink at all skips the pin.
    local auth_sock = vim.fs.normalize("~/.ssh/ssh_auth_sock")
    if vim.uv.fs_lstat(auth_sock) then
        vim.env.SSH_AUTH_SOCK = auth_sock
    end

    -- 'shell' is seeded from $SHELL, inherited from whatever spawned this
    -- server -- and a respawn chain that once passed through a bash
    -- environment (a :terminal running Claude Code, a restart_other jobstart)
    -- leaks bash into every :term from then on. Pin both to fish, the way
    -- tmux's default-shell did; $SHELL too so respawns inherit the fix.
    local fish = vim.fn.exepath("fish")
    if fish ~= "" then
        vim.env.SHELL = fish
        vim.o.shell = fish
    end

    -- :restart with the layout preserved: plain :restart forgets everything,
    -- so save a session first and source it in the new server. Terminal
    -- buffers are kept out of the session -- restoring them would respawn
    -- their jobs, and under the litre model terminals are disposable anyway.
    if vim.fn.exists(":restart") == 2 then
        vim.api.nvim_create_user_command("Restart", function()
            local file = vim.fs.joinpath(vim.fn.stdpath("state"), "restart-session.vim")
            local saved = vim.o.sessionoptions
            vim.opt.sessionoptions:remove("terminal")
            vim.cmd("mksession! " .. vim.fn.fnameescape(file))
            vim.o.sessionoptions = saved
            vim.cmd("restart source " .. vim.fn.fnameescape(file))
        end, {})

        -- :Restart for the whole fleet: the other servers first (in
        -- parallel), this one last -- its restart tears the UI down, so it
        -- must not cut the timers driving the others. If anything was
        -- skipped, this server stays up so the report stays readable.
        vim.api.nvim_create_user_command("RestartAll", function()
            local servers = other_servers()
            if #servers == 0 then
                vim.cmd("Restart")
                return
            end
            local pending, skipped = #servers, {}
            local function done(reason)
                if reason then
                    table.insert(skipped, reason)
                end
                pending = pending - 1
                if pending > 0 then
                    return
                end
                if #skipped == 0 then
                    vim.cmd("Restart")
                    return
                end
                vim.notify("RestartAll:\n" .. table.concat(skipped, "\n")
                    .. "\nthis server kept alive -- :Restart it yourself",
                    vim.log.levels.WARN)
            end
            vim.notify(("RestartAll: restarting %d other servers"):format(#servers))
            for _, s in ipairs(servers) do
                M.restart_other(s, done)
            end
        end, {})
    end

    -- Hop this UI to another project's server (sockets live where `nt` puts
    -- them) -- the tmux switch-client analogue.
    if vim.fn.exists(":connect") == 2 then
        vim.api.nvim_create_user_command("Connect", function()
            local servers = other_servers()
            if #servers == 0 then
                vim.notify("no other servers", vim.log.levels.WARN)
                return
            end
            vim.ui.select(servers, {
                prompt = "connect to server",
                format_item = function(s)
                    return s.label
                end,
            }, function(s)
                if s then
                    hop(s.path)
                end
            end)
        end, {})

        vim.api.nvim_create_user_command("FzfConnect", function()
            if #M.source.list() == 0 then
                vim.notify("no other servers", vim.log.levels.WARN)
                return
            end
            require("fzf-pin").pick(M.source)
        end, {})
    end
end

return M

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

-- :connect %-expands its argument, and every socket name contains % --
-- fnameescape or the hop dies with E499 (verified live).
local function hop(path)
    vim.cmd("connect " .. vim.fn.fnameescape(path))
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
            vim.notify("no server for " .. item.data, vim.log.levels.WARN)
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

-- Per-project server support: SSH_AUTH_SOCK pinning, :Restart with layout,
-- and hopping the UI between servers (:Connect / :FzfConnect).
local M = {}

function M.setup()
    -- The bashrc login hook repoints ~/.ssh/ssh_auth_sock at every ssh login;
    -- pinning the env to that stable path keeps ssh -A working in every
    -- terminal buffer however old the server is (tmux did this with
    -- set-environment -g).
    local auth_sock = vim.fs.normalize("~/.ssh/ssh_auth_sock")
    if vim.uv.fs_stat(auth_sock) then
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

    -- Hop this UI to another project's server (sockets live where `nv` puts
    -- them) -- the tmux switch-client analogue.
    if vim.fn.exists(":connect") == 2 then
        local function other_servers()
            local dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "servers")
            local servers = {}
            for name in vim.fs.dir(dir) do
                local path = vim.fs.joinpath(dir, name)
                if path ~= vim.v.servername then
                    -- socket names are the project path, / encoded as %
                    table.insert(servers, { path = path, label = (name:gsub("%%", "/")) })
                end
            end
            return servers
        end

        -- :connect %-expands its argument, and every socket name contains % --
        -- fnameescape or the hop dies with E499 (verified live).
        local function hop(path)
            vim.cmd("connect " .. vim.fn.fnameescape(path))
        end

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
            local servers = other_servers()
            if #servers == 0 then
                vim.notify("no other servers", vim.log.levels.WARN)
                return
            end
            local by_label = {}
            local labels = {}
            for _, s in ipairs(servers) do
                by_label[s.label] = s.path
                table.insert(labels, s.label)
            end
            require("fzf-lua").fzf_exec(labels, {
                prompt = "connect> ",
                actions = {
                    default = function(selected)
                        if selected[1] then
                            hop(by_label[selected[1]])
                        end
                    end,
                },
            })
        end, {})
    end
end

return M

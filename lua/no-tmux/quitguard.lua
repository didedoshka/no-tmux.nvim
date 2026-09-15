-- A server :qa kills running jobs silently (measured against a live
-- --listen server with a real remote UI; the E948 that nvim raises in
-- script -l mode is an artifact of that mode and never appears here). That
-- covers both kinds of job: terminal shells running something, and litre
-- tasks -- vim.system processes that belong to no buffer, which litre even
-- reaps on VimLeavePre. On ExitPre -- so only a quit that would actually end
-- the session; closing a split never fires it -- this recomputes what is
-- busy and, while anything is: a real UI gets a confirm() prompt naming the
-- jobs, where "quit and kill" just lets the exit continue; "stay" (and any
-- headless instance, which cannot answer) blocks the quit instead -- a
-- hidden modified buffer makes it fail with a bare E37 (no jump, no buffer
-- name -- measured). An idle shell does not block. Whatever quit then goes
-- through is appended to stdpath("state")/killed-jobs.txt with cwd and
-- command, as a record of what to re-run. A :restart quit is exempt from all
-- of it (see the ExitPre callback for why).
local M = {}

-- the sentinel bufnr lives in vim.g so re-running setup() reuses the buffer
-- instead of leaking one per call
local function sentinel()
    local buf = vim.g.quitguard_sentinel
    if buf and vim.api.nvim_buf_is_valid(buf) then
        return buf
    end
    buf = vim.api.nvim_create_buf(false, false)
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "quitguard sentinel" })
    vim.bo[buf].modified = false
    vim.g.quitguard_sentinel = buf
    return buf
end

local function clear_sentinel()
    local buf = vim.g.quitguard_sentinel
    if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].modified = false
    end
end

-- pids of the shell's children in a terminal buffer, empty for an idle
-- shell (or a buffer whose job is gone)
local function children(buf)
    local pid = vim.b[buf].terminal_job_pid
    if not pid then
        return {}
    end
    local ok, pids = pcall(vim.api.nvim_get_proc_children, pid)
    return ok and pids or {}
end

-- what the shell in a terminal buffer is running: its children's names
function M.running(buf)
    local names = {}
    for _, pid in ipairs(children(buf)) do
        local ok, proc = pcall(vim.api.nvim_get_proc, pid)
        table.insert(names, (ok and proc and proc.name) and proc.name or tostring(pid))
    end
    return names
end

-- the full command line of a process: nvim_get_proc only knows the name,
-- /proc has the arguments (NUL-separated); empty when unreadable
local function cmdline(pid)
    local f = io.open(("/proc/%d/cmdline"):format(pid), "rb")
    if not f then
        return ""
    end
    local raw = f:read("a") or ""
    f:close()
    return (raw:gsub("%z", " "):gsub("%s+$", ""))
end

-- one terminal buffer, described for a prompt that is about to kill it:
-- title, the shell's cwd, each running command in full, and the last
-- lines on its screen -- enough to tell terminals apart. Lines are cut at
-- 80 columns so a confirm() stays readable.
function M.describe(buf)
    local function cut(line)
        line = vim.trim(line)
        return #line > 80 and (line:sub(1, 77) .. "...") or line
    end
    local title = vim.b[buf].term_title or ""
    local lines = { ("term %d: %s"):format(buf,
        title ~= "" and title or vim.api.nvim_buf_get_name(buf)) }
    local pid = vim.b[buf].terminal_job_pid
    local cwd = pid and vim.uv.fs_readlink(("/proc/%d/cwd"):format(pid))
    if cwd then
        table.insert(lines, "  cwd: " .. vim.fn.fnamemodify(cwd, ":~"))
    end
    for _, child in ipairs(children(buf)) do
        local cmd = cmdline(child)
        if cmd == "" then
            local ok, proc = pcall(vim.api.nvim_get_proc, child)
            cmd = (ok and proc and proc.name) and proc.name or tostring(child)
        end
        table.insert(lines, "  running: " .. cut(cmd))
    end
    local screen = {}
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if vim.trim(line) ~= "" then
            table.insert(screen, cut(line))
        end
    end
    for i = math.max(1, #screen - 2), #screen do
        table.insert(lines, "  | " .. screen[i])
    end
    return lines
end

-- terminal buffers whose shell is running something, with the child commands.
-- fzf-lua runs its picker in a terminal buffer (filetype "fzf") and can leave
-- one behind with a live fzf in it -- a picker is never work worth saving, so
-- it never blocks a quit (measured: leaked "Buffers" pickers blocked every :q)
local function busy_terms()
    local busy = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].buftype == "terminal" and vim.bo[buf].filetype ~= "fzf" then
            local names = M.running(buf)
            if #names > 0 then
                table.insert(busy, { buf = buf, names = names })
            end
        end
    end
    return busy
end

local function running_litre_tasks()
    -- package.loaded, not require: the guard must not be the thing that loads litre
    local runner = package.loaded["litre.runner"]
    return runner and runner.running_tasks() or {}
end

local function describe(terms, tasks)
    local parts = {}
    for _, t in ipairs(terms) do
        vim.list_extend(parts, t.names)
    end
    for _, task in ipairs(tasks) do
        table.insert(parts, "litre " .. task.id)
    end
    return table.concat(parts, ", ")
end

function M.setup()
    local group = vim.api.nvim_create_augroup("quitguard", { clear = true })

    vim.api.nvim_create_autocmd("ExitPre", {
        group = group,
        callback = function()
            -- A :restart quit must never be prompted or blocked: ex_restart has
            -- already handed the socket to the new server and told the UI to
            -- reattach *before* it runs the quit. Refusing here cancels the
            -- restart but leaves the UI's reattach order armed forever, and the
            -- next real quit kills the UI with "connection refused" (measured
            -- live, 2026-08-12). v:exitreason is "restart"/"restart!" during
            -- that quit ("quit" on a plain :qa); VimLeavePre still logs kills.
            if vim.v.exitreason == "restart" or vim.v.exitreason == "restart!" then
                clear_sentinel()
                return
            end
            local terms, tasks = busy_terms(), running_litre_tasks()
            if #terms == 0 and #tasks == 0 then
                clear_sentinel()
                return
            end
            local what = describe(terms, tasks)
            -- a UI gets a question instead of an error; "quit and kill" lets the
            -- exit continue and VimLeavePre logs the kills. Headless instances
            -- (the spec, :RestartAll's rpc :qall via g:quitguard_auto) cannot
            -- answer a prompt, so they block below and the notify -- E37 itself
            -- never says what blocked -- lands in :messages.
            if #vim.api.nvim_list_uis() > 0 and not vim.g.quitguard_auto then
                if vim.fn.confirm(("quitguard: %s running"):format(what),
                        "&stay\n&quit and kill", 1) == 2 then
                    clear_sentinel()
                    return
                end
            else
                vim.notify(("quitguard: %s running (:qa! kills it)"):format(what), vim.log.levels.WARN)
            end
            local buf = sentinel()
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { ("running: %s -- :qa! kills"):format(what) })
            -- the :// scheme keeps nvim from absolutizing the name into a path
            local name = ("quitguard://%s"):format(what:sub(1, 60))
            if vim.api.nvim_buf_get_name(buf) ~= name then
                pcall(vim.api.nvim_buf_set_name, buf, name)
            end
            vim.bo[buf].modified = true
            -- the changed-check runs synchronously inside this same command, so the
            -- flag can drop right after: no stale block on the next idle quit
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(buf) then
                    vim.bo[buf].modified = false
                end
            end)
        end,
    })

    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        callback = function()
            local terms, tasks = busy_terms(), running_litre_tasks()
            if #terms == 0 and #tasks == 0 then
                return
            end
            local lines = { os.date("%Y-%m-%d %H:%M:%S") .. " " .. vim.v.servername }
            for _, t in ipairs(terms) do
                local pid = vim.b[t.buf].terminal_job_pid
                local cwd = vim.uv.fs_readlink(("/proc/%d/cwd"):format(pid)) or "?"
                table.insert(lines, ("  term [%s]: %s"):format(cwd, table.concat(t.names, ", ")))
            end
            for _, task in ipairs(tasks) do
                table.insert(lines, "  litre " .. task.id)
            end
            local state = vim.fn.stdpath("state") --[[@as string]]
            -- a fresh box (or the e2e sandbox) has no state dir yet, and
            -- io.open "a" does not create parents -- the log would be lost
            vim.fn.mkdir(state, "p")
            local f = io.open(vim.fs.joinpath(state, "killed-jobs.txt"), "a")
            if f then
                f:write(table.concat(lines, "\n") .. "\n")
                f:close()
            end
        end,
    })
end

return M

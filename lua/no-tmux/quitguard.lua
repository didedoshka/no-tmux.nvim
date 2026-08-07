-- A server :qa kills running jobs silently (measured against a live
-- --listen server with a real remote UI; the E948 that nvim raises in
-- script -l mode is an artifact of that mode and never appears here). That
-- covers both kinds of job: terminal shells running something, and litre
-- tasks -- vim.system processes that belong to no buffer, which litre even
-- reaps on VimLeavePre. On QuitPre this recomputes what is busy and, while
-- anything is, a hidden modified buffer makes the quit fail with a bare E37
-- (no jump, no buffer name -- measured), so a notify names the jobs and the
-- :qa! override. An idle shell does not block. Whatever a forced quit then
-- kills is appended to stdpath("state")/killed-jobs.txt with cwd and
-- command, as a record of what to re-run.
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

-- terminal buffers whose shell is running something, with the child commands.
-- fzf-lua runs its picker in a terminal buffer (filetype "fzf") and can leave
-- one behind with a live fzf in it -- a picker is never work worth saving, so
-- it never blocks a quit (measured: leaked "Buffers" pickers blocked every :q)
local function busy_terms()
    local busy = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].buftype == "terminal" and vim.bo[buf].filetype ~= "fzf"
            and vim.b[buf].terminal_job_pid then
            local ok, children = pcall(vim.api.nvim_get_proc_children, vim.b[buf].terminal_job_pid)
            if ok and #children > 0 then
                local names = {}
                for _, pid in ipairs(children) do
                    local pok, proc = pcall(vim.api.nvim_get_proc, pid)
                    table.insert(names, (pok and proc and proc.name) and proc.name or tostring(pid))
                end
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

    vim.api.nvim_create_autocmd("QuitPre", {
        group = group,
        callback = function()
            local terms, tasks = busy_terms(), running_litre_tasks()
            if #terms == 0 and #tasks == 0 then
                local buf = vim.g.quitguard_sentinel
                if buf and vim.api.nvim_buf_is_valid(buf) then
                    vim.bo[buf].modified = false
                end
                return
            end
            local buf = sentinel()
            local what = describe(terms, tasks)
            -- E37 itself never says what blocked, so say it here; also fires on a
            -- mere window :q while a task runs, where it is still a true statement
            vim.notify(("quitguard: %s running (:qa! kills it)"):format(what), vim.log.levels.WARN)
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

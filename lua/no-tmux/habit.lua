-- :qa is the tmux-era reflex. In a server it kills the thing everything lives
-- in -- the terminals, the LSP clients, the whole session -- when the move is
-- now :detach, which ends the ssh with it. So both print "habit" instead,
-- matching the config's habit keys (s, S, <C-o>).
--
-- Only inside a server started by `nt`: a throwaway `nvim file.txt` in a
-- terminal tab must still quit the ordinary way.
--
-- Two things are deliberately left alone:
--   * `:q` with another window or tab open -- closing a split is most of what
--     :q is for, and there is no habit to unlearn there. It nags only when it
--     would actually end the session.
--   * the ! forms. `:qa!` is the considered override, and the one quitguard
--     tells you to reach for; a habit block that ate it would be a trap.
local M = {}

-- true when this quit would exit nvim rather than close a window. Floating
-- windows do not keep nvim alive, so they do not count.
local function last_window()
    if #vim.api.nvim_list_tabpages() > 1 then
        return false
    end
    local wins = 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_config(win).relative == "" then
            wins = wins + 1
        end
    end
    return wins <= 1
end

-- The abbreviation fires when a non-keyword char is typed, so `:q!` expands at
-- the `!` and arrives here as a bang -- hence -bang on both commands, which is
-- what keeps the override working. `:qall` is safe: `l` is a keyword char, so
-- nothing expands. Abbreviations apply to the typed cmdline only, never to
-- scripts or mappings, so a plugin's :qa still quits.
local function abbrev(lhs, rhs)
    vim.cmd(("cnoreabbrev <expr> %s (getcmdtype() == ':' && getcmdline() ==# '%s') ? '%s' : '%s'")
        :format(lhs, lhs, rhs, lhs))
end

function M.setup()
    vim.api.nvim_create_user_command("NtQ", function(a)
        if a.bang then
            vim.cmd("q!")
        elseif last_window() then
            print("habit")
        else
            vim.cmd("q")
        end
    end, { bang = true, desc = "habit: :q in a server" })

    vim.api.nvim_create_user_command("NtQa", function(a)
        if a.bang then
            vim.cmd("qa!")
        else
            print("habit")
        end
    end, { bang = true, desc = "habit: :qa in a server" })

    abbrev("q", "NtQ")
    abbrev("qa", "NtQa")
end

return M

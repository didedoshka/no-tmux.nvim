#!/usr/bin/env bash
# End-to-end against real detached headless servers, HOME and every XDG dir
# sandboxed under a mktemp tree -- offline, and the real ~/.cache/nvim/servers
# is never touched. Covers what spec.lua cannot:
#   - the SSH_AUTH_SOCK pin at server startup, and that terminal jobs
#     spawned later inherit it
#   - the pin staying out of the way when ~/.ssh/ssh_auth_sock is absent
#   - :Connect excluding the server's own socket and decoding labels
#   - quitguard against a real :qa (blocked while a terminal is busy) and
#     :qa! (kills, and logs to state/killed-jobs.txt)
# A real UI hop still needs a --remote-ui client -- see the verify skill.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
pids=()
cleanup() {
    for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null; done
    rm -rf "$tmp"
}
trap cleanup EXIT

failed=0
ok()   { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; failed=$((failed + 1)); }
# check <name> <got> <want>
check() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (got '$2', want '$3')"; fi
}

# start_server <home> <sock> -- detached headless server running the plugin.
# SSH_AUTH_SOCK comes from the caller's environment.
start_server() {
    local home="$1" sock="$2"
    mkdir -p "$(dirname "$sock")"
    HOME="$home" XDG_CACHE_HOME="$home/cache" XDG_STATE_HOME="$home/state" \
    XDG_DATA_HOME="$home/data" XDG_CONFIG_HOME="$home/config" \
        nvim --clean --headless --listen "$sock" \
            --cmd "set rtp+=$repo" +"lua require('nv').setup()" \
            >/dev/null 2>&1 &
    pids+=($!)
    for _ in $(seq 100); do
        nvim --server "$sock" --remote-expr 1 >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    echo "e2e: server $sock did not come up" >&2
    exit 1
}

rexpr() { nvim --server "$1" --remote-expr "$2" 2>/dev/null; }
# run a lua file inside the server; the file must end with `return 1`
rlua() { rexpr "$1" "luaeval('dofile(_A)', '$2')" >/dev/null; }

# --- server A: pinned agent sock, sockets dir laid out like `nv` does -------
home_a="$tmp/a"
mkdir -p "$home_a/.ssh"
touch "$home_a/.ssh/ssh_auth_sock"     # production is a symlink; stats the same
sock_a="$home_a/cache/nvim/servers/%proj%a"
export SSH_AUTH_SOCK="$tmp/stale-agent.sock"
start_server "$home_a" "$sock_a"

check "SSH_AUTH_SOCK pinned at startup" \
    "$(rexpr "$sock_a" '$SSH_AUTH_SOCK')" "$home_a/.ssh/ssh_auth_sock"

# a terminal job spawned in the server sees the pin, not the stale value
cat > "$tmp/terms.lua" <<EOF
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.fn.jobstart({ "sh", "-c", "echo \"\$SSH_AUTH_SOCK\" > '$tmp/term-env'" }, { term = true })
buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.fn.jobstart({ "sh", "-c", "sleep 30" }, { term = true })
return 1
EOF
rlua "$sock_a" "$tmp/terms.lua"
for _ in $(seq 50); do [[ -s "$tmp/term-env" ]] && break; sleep 0.1; done
check "terminal job inherits the pin" "$(cat "$tmp/term-env" 2>/dev/null)" \
    "$home_a/.ssh/ssh_auth_sock"

# --- :Connect: own socket excluded, % decoded ---------------------------------
touch "$home_a/cache/nvim/servers/%data%project%x"
cat > "$tmp/connect.lua" <<EOF
local items
vim.ui.select = function(list, _, on_choice)
    items = list
    on_choice(nil)
end
vim.cmd("Connect")
local labels = {}
for _, s in ipairs(items or {}) do
    table.insert(labels, s.label)
end
local f = assert(io.open("$tmp/connect-labels", "w"))
f:write(table.concat(labels, "\n"))
f:close()
return 1
EOF
rlua "$sock_a" "$tmp/connect.lua"
check ":Connect lists others only, decoded" \
    "$(cat "$tmp/connect-labels" 2>/dev/null)" "/data/project/x"

# --- quitguard against a real :qa ---------------------------------------------
cat > "$tmp/busy.lua" <<EOF
for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].buftype == "terminal" and vim.b[b].terminal_job_pid then
        local ok, kids = pcall(vim.api.nvim_get_proc_children, vim.b[b].terminal_job_pid)
        if ok and #kids > 0 then
            return 1
        end
    end
end
return 0
EOF
busy=0
for _ in $(seq 50); do
    [[ "$(rexpr "$sock_a" "luaeval('dofile(_A)', '$tmp/busy.lua')")" == "1" ]] && busy=1 && break
    sleep 0.1
done
check "a terminal shell is busy (sleep running)" "$busy" "1"

nvim --server "$sock_a" --remote-send ':qa<CR>' 2>/dev/null
sleep 0.5
check ":qa blocked while the terminal is busy" "$(rexpr "$sock_a" 1)" "1"

nvim --server "$sock_a" --remote-send ':qa!<CR>' 2>/dev/null
dead=0
for _ in $(seq 50); do
    rexpr "$sock_a" 1 >/dev/null 2>&1 || { dead=1; break; }
    sleep 0.1
done
check ":qa! goes through" "$dead" "1"
log="$home_a/state/nvim/killed-jobs.txt"
if [[ -f "$log" ]] && grep -q "sleep" "$log"; then
    ok ":qa! logged the killed job to killed-jobs.txt"
else
    fail ":qa! logged the killed job to killed-jobs.txt (log: $(cat "$log" 2>/dev/null))"
fi

# --- server B: no ~/.ssh/ssh_auth_sock -> env left alone -----------------------
home_b="$tmp/b"
mkdir -p "$home_b"
sock_b="$home_b/cache/nvim/servers/%proj%b"
export SSH_AUTH_SOCK="$tmp/original-agent.sock"
start_server "$home_b" "$sock_b"
check "SSH_AUTH_SOCK untouched without the symlink" \
    "$(rexpr "$sock_b" '$SSH_AUTH_SOCK')" "$tmp/original-agent.sock"
nvim --server "$sock_b" --remote-send ':qa!<CR>' 2>/dev/null

if (( failed > 0 )); then
    echo "$failed e2e checks failed"
    exit 1
fi
echo "e2e: all passed"

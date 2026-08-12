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
#   - quitguard letting a :restart quit through unprompted (a refusal would
#     poison the UI's reattach order -- see the ExitPre comment)
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
            --cmd "set rtp+=$repo" +"lua require('no-tmux').setup()" \
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

# --- server A: pinned agent sock, sockets dir laid out like `nt` does -------
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

# --- server R: a :restart quit is never guarded --------------------------------
# ex_restart hands the socket to the respawned server before it quits, so a
# blocked quit strands the UI on a cancelled restart. The guard must let it
# through even with a busy terminal. Headless :restart respawns the server on
# the same socket (same argv) -- that respawn is not in $pids, kill it by hand.
home_r="$tmp/r"
mkdir -p "$home_r"
sock_r="$home_r/cache/nvim/servers/%proj%r"
start_server "$home_r" "$sock_r"
if [[ "$(rexpr "$sock_r" 'exists(":restart")')" != "2" ]]; then
    ok "no :restart on this nvim -- restart guard exemption skipped"
    nvim --server "$sock_r" --remote-send ':qa!<CR>' 2>/dev/null
else
    pid_r="$(rexpr "$sock_r" 'getpid()')"
    cat > "$tmp/busy-term.lua" <<EOF
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.fn.jobstart({ "sh", "-c", "sleep 30" }, { term = true })
return 1
EOF
    rlua "$sock_r" "$tmp/busy-term.lua"
    busy=0
    for _ in $(seq 50); do
        [[ "$(rexpr "$sock_r" "luaeval('dofile(_A)', '$tmp/busy.lua')")" == "1" ]] && busy=1 && break
        sleep 0.1
    done
    check "server R terminal is busy" "$busy" "1"
    rexpr "$sock_r" 'execute("restart")' >/dev/null 2>&1
    dead=0
    for _ in $(seq 50); do
        kill -0 "$pid_r" 2>/dev/null || { dead=1; break; }
        sleep 0.1
    done
    check ":restart quit goes through despite the busy terminal" "$dead" "1"
    log_r="$home_r/state/nvim/killed-jobs.txt"
    if [[ -f "$log_r" ]] && grep -q "sleep" "$log_r"; then
        ok ":restart kill still logged to killed-jobs.txt"
    else
        fail ":restart kill still logged to killed-jobs.txt (log: $(cat "$log_r" 2>/dev/null))"
    fi
    pkill -f -- "--listen $sock_r" 2>/dev/null
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

# --- server C: dangling symlink at startup ------------------------------------
# The real ~/.ssh/ssh_auth_sock is a symlink into /tmp/ssh-*/agent.*, and sshd
# removes that target when its session ends. A server started in that window
# must still pin: the next ssh login repoints the symlink and the pin becomes
# valid -- skipping it would freeze the stale inherited value in forever.
home_c="$tmp/c"
mkdir -p "$home_c/.ssh"
ln -s "$tmp/gone-session-agent.sock" "$home_c/.ssh/ssh_auth_sock"
sock_c="$home_c/cache/nvim/servers/%proj%c"
export SSH_AUTH_SOCK="$tmp/stale-agent.sock"
start_server "$home_c" "$sock_c"

check "SSH_AUTH_SOCK pinned while the symlink dangles" \
    "$(rexpr "$sock_c" '$SSH_AUTH_SOCK')" "$home_c/.ssh/ssh_auth_sock"

# "next ssh login": the hook repoints the symlink; a terminal job spawned now
# must reach the fresh agent through the pin
touch "$tmp/fresh-agent.sock"
ln -sf "$tmp/fresh-agent.sock" "$home_c/.ssh/ssh_auth_sock"
cat > "$tmp/term-c.lua" <<EOF
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.fn.jobstart({ "sh", "-c", "readlink -f \"\$SSH_AUTH_SOCK\" > '$tmp/term-env-c'" }, { term = true })
return 1
EOF
rlua "$sock_c" "$tmp/term-c.lua"
for _ in $(seq 50); do [[ -s "$tmp/term-env-c" ]] && break; sleep 0.1; done
check "terminal job reaches the repointed agent" \
    "$(cat "$tmp/term-env-c" 2>/dev/null)" "$(readlink -f "$tmp/fresh-agent.sock")"
nvim --server "$sock_c" --remote-send ':qa!<CR>' 2>/dev/null

# --- restart_other: a live server restarted from another one -------------------
# D (initiator) and E (target) share a home so D's :Connect machinery sees E's
# socket. E gets a two-window session; D saves it over RPC, quits E, respawns
# it (E's own --clean argv, so no config involved) and sources the session
# back. The done callback reports into a file.
home_d="$tmp/d"
mkdir -p "$home_d"
sock_d="$home_d/cache/nvim/servers/%proj%d"
sock_e="$home_d/cache/nvim/servers/%proj%e"
start_server "$home_d" "$sock_d"
start_server "$home_d" "$sock_e"

cat > "$tmp/layout.lua" <<EOF
vim.cmd("edit $tmp/one.txt")
vim.cmd("split $tmp/two.txt")
return 1
EOF
rlua "$sock_e" "$tmp/layout.lua"

cat > "$tmp/restart-e.lua" <<EOF
require("no-tmux.server").restart_other(
    { path = "$sock_e", label = "/proj/e" },
    function(reason)
        local f = assert(io.open("$tmp/restart-result", "w"))
        f:write(reason or "ok")
        f:close()
    end)
return 1
EOF
rlua "$sock_d" "$tmp/restart-e.lua"
for _ in $(seq 200); do [[ -s "$tmp/restart-result" ]] && break; sleep 0.1; done
check "restart_other reports success" "$(cat "$tmp/restart-result" 2>/dev/null)" "ok"
check "restarted server is reachable" "$(rexpr "$sock_e" 1)" "1"
# the source arrives as an rpcnotify -- give the fresh server a beat
layout=""
for _ in $(seq 50); do
    layout="$(rexpr "$sock_e" "len(nvim_list_wins())")"
    [[ "$layout" == "2" ]] && break
    sleep 0.1
done
check "session restored: two windows" "$layout" "2"
check "session restored: split buffer" \
    "$(rexpr "$sock_e" "fnamemodify(bufname(winbufnr(1)), ':t')")" "two.txt"

# the respawned E is not in our pids list -- shut it down explicitly
nvim --server "$sock_e" --remote-send ':qa!<CR>' 2>/dev/null
nvim --server "$sock_d" --remote-send ':qa!<CR>' 2>/dev/null

if (( failed > 0 )); then
    echo "$failed e2e checks failed"
    exit 1
fi
echo "e2e: all passed"

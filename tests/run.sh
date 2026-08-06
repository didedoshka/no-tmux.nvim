#!/usr/bin/env bash
# Offline checks for nv: static analysis + the spec. No network, no live
# servers -- safe anywhere. There is no standalone lua on this box:
# `nvim --clean -l` is the Lua runtime.
#
#   tests/run.sh          both offline tiers
#   tests/run.sh spec     just the spec
#   tests/run.sh check    just lua-language-server
#   tests/run.sh e2e      live detached headless servers (tests/e2e.sh) --
#                         still offline and sandboxed, but slower, so not
#                         part of "all" (the edit hook runs "all")
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
what="${1:-all}"
rc=0

if [[ "$what" == "all" || "$what" == "check" ]]; then
    if command -v lua-language-server >/dev/null 2>&1; then
        echo "== lua-language-server --check"
        # must point at the repo root or .luarc.json is not found and every
        # `vim` is an undefined global
        out="$(cd "$repo" && timeout 300 lua-language-server --check "$repo" \
            --checklevel=Warning 2>&1)"
        if grep -q "no problems found" <<<"$out"; then
            echo "  ok    no problems"
        else
            echo "$out" | sed -e 's/^/  /'
            rc=1
        fi
    else
        echo "== lua-language-server not installed -- skipping static check"
    fi
fi

if [[ "$what" == "all" || "$what" == "spec" ]]; then
    echo "== spec (nvim --clean)"
    # sandboxed cache and state: the spec fabricates sockets in
    # stdpath("cache")/servers and pins through the fzf-pin store in
    # stdpath("state") -- it must never see (or write) the real ones
    cache="$(mktemp -d)"
    XDG_CACHE_HOME="$cache" XDG_STATE_HOME="$cache/state" \
        timeout 120 nvim --clean --headless -l "$repo"/tests/spec.lua || rc=1
    rm -rf "$cache"
fi

if [[ "$what" == "e2e" ]]; then
    echo "== e2e (live headless servers)"
    timeout 120 "$repo"/tests/e2e.sh || rc=1
fi

exit $rc

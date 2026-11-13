#!/usr/bin/env bash
# Live check 1 (stop 1, every 5 min): `gh` answers inside 10 s through the shim on PATH. A shim that loops on itself or hangs is red.
# shellcheck source=tests/live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
limit=${JG_LIVE_GH_S:-10}
read -ra cmd <<< "${JG_LIVE_GH_CMD:-gh --version}"
out=$(timeout "$limit" "${cmd[@]}" 2>&1); rc=$?
[ "$rc" -ne 124 ] || live_red "gh gave no answer in ${limit}s"
[ "$rc" -eq 0 ] || live_red "gh exited $rc: $(printf '%s' "$out" | head -n 1 | cut -c1-120)"
live_pass "gh answered inside ${limit}s"

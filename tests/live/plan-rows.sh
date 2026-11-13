#!/usr/bin/env bash
# Live check 5 (stop 4, at filing): a plan's rows are valid: label, edges, files. `bd swarm validate <epic>` is the whole check.
# Usage: plan-rows.sh <epic-id>
# shellcheck source=tests/live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
epic=${1:?usage: plan-rows.sh <epic-id>}
read -ra cmd <<< "${JG_LIVE_VALIDATE_CMD:-bd swarm validate}"
out=$(timeout "${JG_LIVE_PLAN_S:-30}" "${cmd[@]}" "$epic" 2>&1); rc=$?
[ "$rc" -eq 0 ] || live_red "$epic did not validate (exit $rc): $(printf '%s' "$out" | head -n 1 | cut -c1-120)"
live_pass "$epic rows validate"

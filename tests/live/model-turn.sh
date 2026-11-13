#!/usr/bin/env bash
# Live check 3 (stop 2, every 60 min and before a pair's first lane): one short turn on each account and model pair lanes use.
# Pairs: config/live-pairs, one `<account-config-dir> <model>` per line (# comments allowed). This is the one check that costs a model
# turn; the default turn is `claude -p` and a lab passes a Haiku model. JG_LIVE_TURN_CMD `<account> <model>` replaces it.
# shellcheck source=tests/live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
limit=${JG_LIVE_TURN_S:-60}; file=${JG_LIVE_PAIRS:-$CONFIG/live-pairs}; n=0; bad=''
[ -f "$file" ] || live_pass "no pairs listed in $file"
while read -r acct model _; do
  case $acct in ''|'#'*) continue ;; esac
  n=$((n + 1))
  if [ -n "${JG_LIVE_TURN_CMD:-}" ]; then turn() { timeout "$limit" "$JG_LIVE_TURN_CMD" "$acct" "$model" >/dev/null 2>&1; }
  else turn() { CLAUDE_CONFIG_DIR=$acct timeout "$limit" claude -p --model "$model" 'Reply with the word ok.' >/dev/null 2>&1; }; fi
  turn || bad="$bad ${acct##*/}/$model"
done < "$file"
[ -z "$bad" ] || live_red "no answer inside ${limit}s from:$bad"
live_pass "$n pair(s) answered a turn"

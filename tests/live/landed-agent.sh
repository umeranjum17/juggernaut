#!/usr/bin/env bash
# Live check 9 (stop 8, every 1 min): a landed lane has no agent after 10 min. A lane has landed when core/trunk-landing wrote a
# `landed` row for it under data/jg-trunk-landing/<id>.<head>.state; its agent is alive when bin/jg-crew-state.sh reports a state.
# shellcheck source=tests/live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
limit=${JG_LIVE_LANDED_S:-600}; now=$(live_now); n=0; stuck=''
alive() { local s; s=$(${JG_LIVE_AGENT_CMD:-"$LIVE_ROOT/bin/jg-crew-state.sh"} "$1" 2>/dev/null | head -n 1); case $s in ''|'state: unknown'*|'state: gone'*) return 1 ;; esac; }
for f in "$DATA"/jg-trunk-landing/*.state; do
  [ -e "$f" ] || continue
  grep -q '^landed' "$f" 2>/dev/null || continue
  id=$(basename "$f"); id=${id%.*.state}; [ -e "$STATE/$id.meta" ] || continue
  n=$((n + 1)); age=$((now - $(live_mtime "$f")))
  [ "$age" -le "$limit" ] || ! alive "$id" || stuck="$stuck $id(${age}s)"
done
[ -z "$stuck" ] || live_red "landed lane still has an agent after ${limit}s:$stuck"
live_pass "$n landed lane(s) with a record, none held by an agent"

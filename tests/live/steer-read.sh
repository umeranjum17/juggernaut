#!/usr/bin/env bash
# Live check 6 (stop 5, every 15 min): a steer is read inside 5 min. A message still in a state/*.inbox folder (not moved to handled/)
# after JG_LIVE_STEER_S (default 300) was not read. JG_LIVE_INBOXES overrides the folder list (the test inbox).
# shellcheck source=tests/live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
limit=${JG_LIVE_STEER_S:-300}; now=$(live_now); n=0; late=''
for box in ${JG_LIVE_INBOXES:-"$STATE"/*.inbox}; do
  for msg in "$box"/*.msg; do
    [ -e "$msg" ] || continue
    n=$((n + 1)); age=$((now - $(live_mtime "$msg")))
    [ "$age" -le "$limit" ] || late="$late $(basename "$box")/$(basename "$msg")(${age}s)"
  done
done
[ -z "$late" ] || live_red "steer unread past ${limit}s:$late"
live_pass "$n waiting steer(s), none older than ${limit}s"

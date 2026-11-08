#!/usr/bin/env bash
# call.sh <task-id> - print the captain-call state word of one task, for core/machines/tables/captain-call.tsv.
# Every answer comes from bin/jg-captain-hold.sh (diverged, open, answered); this file holds none of
# its rules. It prints nothing and exits 1 when the owner cannot tell, so the engine reports no state.
#   diverged  the owner's `diverged` report names the task
#   open      `open` exits 0
#   answered  `answered` exits 0
#   none      the task is no open captain call and has no recorded answer
set -u
id=${1:-}
[ -n "$id" ] || { echo "usage: call.sh <task-id>" >&2; exit 2; }
hold=${JG_CAPTAIN_HOLD:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/bin/jg-captain-hold.sh}

report=$("$hold" diverged 2>/dev/null) || exit 1
if printf '%s\n' "$report" | cut -f1 | grep -Fx -- "$id" >/dev/null; then
  echo diverged
  exit 0
fi
"$hold" open "$id" --distinguish-absent >/dev/null 2>&1
case $? in
  0) echo open ;;
  1)
    "$hold" answered "$id" >/dev/null 2>&1
    case $? in
      0) echo answered ;;
      1) echo none ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac

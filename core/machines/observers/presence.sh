#!/usr/bin/env bash
# presence.sh - report-only observer of the presence machine (core/machines/tables/presence.tsv): one word per home.
#
# Usage: presence.sh [<home-name>]   print present, quiet, away or returning (the id names the home; this home is read)
# Records read, never written:
#   quiet      state/.afk exists and its first line is exactly quiet (bin/jg-wake-lib.sh jg_afk_mode)
#   away       state/.afk exists with any other content
#   returning  no state/.afk and the return gate state/.afk-return-catchup is still open
#   present    none of those
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); root=$(cd "$here/../../.." && pwd -P)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$root}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
if [ -e "$STATE/.afk" ]; then
  # shellcheck source=bin/jg-wake-lib.sh
  . "$root/bin/jg-wake-lib.sh"
  jg_afk_mode "$STATE"
elif [ -e "$STATE/.afk-return-catchup" ]; then echo returning
else echo present; fi

#!/usr/bin/env bash
# account.sh - report-only observer of the account machine (core/machines/tables/account.tsv): one word per account of the pool.
#
# Usage: account.sh <provider>.<account id>   print available, in-use, limited, signed-out or retired (provider: claude or codex)
# Records read, never written (the command only reads: it writes no record and runs no move):
#   state/<provider>-accounts.json          the quota reader's last reading (core/claude-accounts/bin/claude-accounts-quota.sh): the roster, each
#                                           account's windows (five_hour, seven_day, each with `left`, percent remaining) and its `problem`
#   state/<provider>-accounts-rested/<id>   the picker's rest file (core/claude-accounts/bin/claude-accounts-pick rest): the epoch it lasts until
#   state/account-assignments.json          the picker's recent leases: [{provider, id, at}], each one live for 300 s (JG_ACCOUNT_POOL_ASSIGNMENT_SECONDS)
# The word, the first line that holds:
#   no account in the reading   retired       (no reading file at all: no-reading, which is no state of the table, so `jg-machine.sh show` reports it)
#   problem names a sign-in     signed-out    (the picker's own test: sign-in, login, unauthenticated, not authenticated, no credentials)
#   rested until a future epoch,
#   or a window with 0 left     limited
#   a live lease                in-use
#   none of those               available
set -u
export LC_ALL=C
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); root=$(cd "$here/../../.." && pwd -P)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$root}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
arg=${1:-}; [[ $arg =~ ^(claude|codex)\.(.+)$ ]] || { echo "usage: account.sh <claude|codex>.<account id>" >&2; exit 2; }
tool=${BASH_REMATCH[1]}; id=${BASH_REMATCH[2]}
reading=$STATE/$tool-accounts.json
[ -s "$reading" ] || { echo no-reading; exit 0; }
now=$(date +%s)
jq -r --arg id "$id" --arg tool "$tool" --argjson now "$now" --argjson ttl "${JG_ACCOUNT_POOL_ASSIGNMENT_SECONDS:-300}" \
  --arg rest "$(cat "$STATE/$tool-accounts-rested/$id" 2>/dev/null || echo 0)" \
  --slurpfile leases <(cat "$STATE/account-assignments.json" 2>/dev/null || echo '[]') '
  (first(.accounts[]? | select(.id == $id)) // null) as $a
  | if $a == null then "retired"
    elif (($a.problem // "") | test("sign-?in|log ?in|unauthenticated|not authenticated|no credentials"; "i")) then "signed-out"
    elif (($rest | tonumber? // 0) > $now) or ([$a.five_hour, $a.seven_day] | any(. != null and .left == 0)) then "limited"
    elif ([$leases[0][]? | select(.provider == $tool and .id == $id and .at > $now - $ttl)] | length) > 0 then "in-use"
    else "available" end' "$reading" 2>/dev/null || echo no-reading

#!/usr/bin/env bash
# lead-asks.sh <lead-status-file> [<now-epoch>] [<min-age-seconds>] - how many asks a lead has had open
# to Main for longer than <min-age-seconds> (default 7200: the pulse's asks>2h).
#
# The status file is the lead's channel in Main's home (<main>/state/<lead>.status). An ask counts only when
#   - it is still open by the shared decision fold, bin/jg-classify.sh own-open-decisions: a resolved or
#     captain-held line for its key, a working or paused line stating the key, or a done or failed line
#     naming it closes it, the same rule the wake drain's OPEN DECISIONS section uses;
#   - the lead raised it for Main: own-open-decisions already leaves out a relayed captain hold and the keys
#     a supervisor library owns (pending-reply-, waiting-timer-, remote-reply-continuity-);
#   - it carries its own [key=]: an unkeyed needs-decision or blocked line (key "default") is not an ask Main
#     can answer by key with bin/jg-send.sh --resolve-key.
# Its age runs from the newest line that opened the key, at the [at=] stamp in force on that line (its own,
# else the nearest earlier one); a key opened before any stamp counts as old.
#
# Prints the count; a missing status file prints 0. A classifier that cannot run exits 2 printing nothing,
# so the pulse shows "?" rather than a wrong count. Exits 2 on a usage error.
set -uo pipefail

[ "$#" -ge 1 ] && [ "$#" -le 3 ] || { echo 'usage: lead-asks.sh <lead-status-file> [<now-epoch>] [<min-age-seconds>]' >&2; exit 2; }
file=$1 now=${2:-$(date +%s)} age=${3:-7200}
case "$now$age" in '' | *[!0-9]*) echo "lead-asks: now and min-age must be whole seconds (got '$now' '$age')" >&2; exit 2 ;; esac
classify="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/bin/jg-classify.sh"

[ -f "$file" ] || { echo 0; exit 0; }
open=$("$classify" own-open-decisions "$file") || exit 2
keys=$(printf '%s\n' "$open" | cut -f1 | grep -vx -e default -e '') || { echo 0; exit 0; }

# Every line that may open a decision, newest first, with the stamp in force on it.
openers=$(awk '
  match($0, /\[at=[0-9]+\]/) { stamp = substr($0, RSTART + 4, RLENGTH - 5) }
  /^[[:space:]]*(needs-decision|blocked)/ { print (stamp == "" ? 0 : stamp) "\t" $0 }
' "$file" | tac)

count=0
while IFS= read -r key; do
  while IFS=$'\t' read -r stamp line; do
    case "$line" in *"[key=$key]"*) ;; *) continue ;; esac
    case "$("$classify" verb "$line")" in needs-decision | blocked) ;; *) continue ;; esac
    [ "$("$classify" key default "$line")" = "$key" ] || continue
    [ $((now - stamp)) -le "$age" ] || count=$((count + 1))
    break
  done <<<"$openers"
done <<<"$keys"
echo "$count"

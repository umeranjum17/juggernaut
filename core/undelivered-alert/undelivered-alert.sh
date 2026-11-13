#!/usr/bin/env bash
# undelivered-alert watcher check: wake Main when a captain message was refused and never delivered.
# Usage: undelivered-alert.sh check <jg-home>
#
# The captain channel appends one row to <home>/state/captain-channel-undelivered.jsonl for each message
# it could not deliver (the voice check refused it, or the gateway was down). Nothing read that file, so a
# refused real report never reached the captain and nobody knew. This check counts the rows; when the count
# is higher than at the last run it raises the undelivered alert, whose wake names the newest row's kind, key and reason, so Main can re-word the message and send it through the normal path. It sends nothing itself.
# Rows may hold raw newlines, so a row is counted by its leading {"at": and never decoded as one line.
# The first run only records the count, so rows already in the file raise no alert.
# The last count lives in <home>/data/jg-undelivered-alert/count. Nothing is printed when nothing rose.
set -u
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: undelivered-alert.sh check <jg-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
ROWS=$FMH/state/captain-channel-undelivered.jsonl
MEM=$FMH/data/jg-undelivered-alert
umask 077
[ -f "$ROWS" ] || exit 0
now=$(grep -c '^{"at":' "$ROWS" 2>/dev/null) || now=0
mkdir -p "$MEM" || exit 0
if [ ! -f "$MEM/count" ]; then printf '%s\n' "$now" > "$MEM/count"; exit 0; fi
was=$(cat "$MEM/count" 2>/dev/null); case $was in ''|*[!0-9]*) was=0 ;; esac
if [ "$now" -lt "$was" ]; then printf '%s\n' "$now" > "$MEM/count"; exit 0; fi # file was rotated
[ "$now" -gt "$was" ] || exit 0
# The newest row: from the last line that opens a row to the end, newlines flattened.
last=$(awk '/^\{"at":/ { row = $0; next } { row = row " " $0 } END { print row }' "$ROWS")
field() { printf '%s' "$last" | sed -n "s/.*\"$1\":\"\\(\\([^\"\\\\]\\|\\\\.\\)*\\)\".*/\\1/p" | head -n 1; }
# error comes before event in a row, so take the first match of each; kind and key sit inside event.
reason=$(printf '%s' "$last" | sed -n 's/^{"at":[0-9]*,"target":"[^"]*","error":"\(\([^"\\]\|\\.\)*\)".*/\1/p' | cut -c1-200)
kind=$(field kind); key=$(field key)
text=$(printf 'undelivered-alert: %s captain message(s) not delivered; newest: kind=%s key=%s reason=%s. Re-word and send it through the normal path.' \
  "$((now - was))" "${kind:-unknown}" "${key:-unknown}" "${reason:-unknown}")
# Raise the undelivered alert (bin/jg-alert.sh); its holder reads the wake `--deliver` appends. The count moves only once it is raised.
ALERT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../bin" && pwd -P)/jg-alert.sh
JG_STATE_OVERRIDE=$FMH/state "$ALERT" raise undelivered "captain-message-$now" --note "$text" --deliver || exit 1
printf '%s\n' "$now" > "$MEM/count"

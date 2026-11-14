#!/usr/bin/env bash
# readings.sh - one reading for each record of one machine in one home, with its age and whether it is fresh, stale or unknown.
# It reads the machine's lister and observer (records.tsv, core/machines/tables) and writes nothing.
#
# Usage: readings.sh <home> <machine> [--now <epoch>]
# One line for each record, tab separated: machine, id, state, observed_at, age, freshness.
#   observed_at  when the record's source last changed, as its lister reports it (empty when the source holds no time)
#   age          seconds from observed_at to now (empty when observed_at is empty)
#   freshness    fresh   the age is within the machine's lifetime (records.tsv, column 3)
#                stale   the age is longer than that
#                unknown the source holds no time, the time is in the future, or the machine, the home or its lister cannot be read
#   state        the observer's word; a word the machine's table does not have, and no word at all, read unknown
#                (the account observer's `no-reading` is one: there is no quota reading to name a state from)
# A home that is missing, or a machine with no lister, reads as one line with id `-`: never as no lines, because no lines
# would read as a quiet machine. A machine whose source is readable and holds no record prints no line.
# Exit: 0 read, 2 usage.
set -u
export LC_ALL=C
# shellcheck source=core/fleet-status/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
home=${1:-} m=${2:-} now=$(date +%s)
[ -n "$home" ] && [ -n "$m" ] || { echo "usage: readings.sh <home> <machine> [--now <epoch>]" >&2; exit 2; }
if [ "${3:-}" = --now ]; then now=${4:-}; [[ $now =~ ^[0-9]+$ ]] || { echo "usage: readings.sh <home> <machine> [--now <epoch>]" >&2; exit 2; }; fi
unreadable() { printf '%s\t-\tunknown\t\t\tunknown\n' "$m"; exit 0; }

home=$(cd "$home" 2>/dev/null && pwd -P) || unreadable
tbl=$home/core/machines/tables/$m.tsv
[ -d "$home/state" ] && [ -f "$tbl" ] || unreadable
fs_env "$home"
lister=$(fs_record "$m" 2); life=$(fs_record "$m" 3)
obs=$(awk -F'\t' '$1 == "observer" { print $2; exit }' "$tbl")
[ -n "$lister" ] && [ -n "$obs" ] && [[ $life =~ ^[0-9]+$ ]] || unreadable
states=$(awk -F'\t' '$1 == "state" && $3 != "composite" { print $2 }' "$tbl")

list=$(bash -c "$lister" 2>/dev/null) || unreadable
while IFS=$'\t' read -r id epoch; do
  [ -n "$id" ] || continue
  word=$(bash -c "$obs" _ "$id" 2>/dev/null | head -1)
  grep -qxF -- "$word" <<< "$states" || word=unknown
  age='' fresh=unknown
  if [[ $epoch =~ ^[0-9]+$ ]] && [ "$epoch" -le "$now" ]; then
    age=$((now - epoch)); fresh=fresh; [ "$age" -le "$life" ] || fresh=stale
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$m" "$id" "$word" "$epoch" "$age" "$fresh"
done <<< "$list"
exit 0

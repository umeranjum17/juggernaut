#!/usr/bin/env bash
# squad-lead.sh - report-only observer of the Squad Lead home machine (core/machines/tables/squad-lead.tsv): one word per home.
#
# Usage: squad-lead.sh <squad-lead-id>   print provisioned, idle, working, down, parked or retired; print nothing for an unknown id
# Records read, never written:
#   retired      no line in data/squad_leads.md and a state/.squad-lead-retired-<id> record (the retirement record; no writer yet)
#   parked       the id is listed in config/parked-homes (core/parked-homes reader)
#   provisioned  a registry line and no state/<id>.meta: the session has not answered yet
#   down         the last row of state/.squad-lead-relaunch-<id> is attempt or failed: the session did not answer and is being brought back
#   working      the home's own state/ holds the record of a live lane of its own (a *.meta that is not a squad_lead)
#   idle         every other registered home
# The command only reads: it moves no home and changes no record.
set -u
id=${1:-}; [ -n "$id" ] || exit 0
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); root=$(cd "$here/../../.." && pwd -P)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$root}}; export JG_HOME
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}; DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}
# shellcheck source=bin/jg-parked-homes-lib.sh
. "$root/bin/jg-parked-homes-lib.sh"
line=$(grep -E "^- ${id//./\\.} - " "$DATA/squad_leads.md" 2>/dev/null | head -1)
if [ -z "$line" ]; then [ -e "$STATE/.squad-lead-retired-$id" ] && echo retired; exit 0; fi
if jg_parked_home "$id" 2>/dev/null; then echo parked; exit 0; fi
[ -f "$STATE/$id.meta" ] || { echo provisioned; exit 0; }
last=$(tail -n 1 "$STATE/.squad-lead-relaunch-$id" 2>/dev/null | cut -f2)
case $last in attempt|failed) echo down; exit 0;; esac
home=${line##*(home: }; home=${home%%;*}
for m in "$home"/state/*.meta; do
  [ -f "$m" ] || continue
  grep -q '^kind=squad_lead$' "$m" || { echo working; exit 0; }
done
echo idle

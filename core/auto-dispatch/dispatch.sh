#!/usr/bin/env bash
# auto-dispatch watcher check: every beat, write down which tickets this home would start by itself. Watch only: it starts nothing.
# Usage: dispatch.sh check <jg-home>
#
# Free lanes are config/lane-target minus the ship and Recon lanes still working (the count bin/jg-fleet-heartbeat.sh makes);
# a home with no lane target has none. The candidates are the tickets `bin/jg-backlog.sh ready --spawnable` lists, plus every
# ticket that holds an approval record. A candidate is judged in this order, and the first reason that fits is the one written:
#   1. no approval record  state/dispatch-approved/<id>, written by `bin/jg-backlog.sh approve-dispatch` (a worker is refused
#      there); a line typed into a ticket body is never read, so it cannot approve anything;
#   2. a captain decision is open and linked to it (`bin/jg-captain-hold.sh blocking`; an answer that cannot be established also stops it);
#   3. it is not in the spawnable list (held, taken by a lane, closed, or its project is not this home's);
#   4. no brief  data/<id>/brief.md is missing or empty;
#   5. the approval record has no route (harness, model, effort);
#   6. no free lane is left for it.
# A ticket that passes all six is a "would start" row, in list order, as many as there are free lanes. The check writes no
# brief, picks no route and spawns nothing; the lead still starts the work.
# Output: the one file data/auto-dispatch/rows.tsv, one row per verdict CHANGE of a ticket:
#   <epoch><TAB><id><TAB>would start|skipped<TAB><route, or why>
# A beat that finds every ticket with the same verdict as its last row writes nothing. The check prints nothing, so it wakes no one.
# JG_AUTO_DISPATCH_BACKLOG and JG_AUTO_DISPATCH_HOLD name the backlog and captain-hold commands (tests point them at stand-ins).
set -u
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: dispatch.sh check <jg-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
STATE=${JG_STATE_OVERRIDE:-$FMH/state}
DATA=${JG_DATA_OVERRIDE:-$FMH/data}
CONFIG=${JG_CONFIG_OVERRIDE:-$FMH/config}
BACKLOG=${JG_AUTO_DISPATCH_BACKLOG:-$FMH/bin/jg-backlog.sh}
HOLD=${JG_AUTO_DISPATCH_HOLD:-$FMH/bin/jg-captain-hold.sh}
APPROVED=$STATE/dispatch-approved
ROWS=$DATA/auto-dispatch/rows.tsv
umask 077
mkdir -p "$DATA/auto-dispatch" || exit 0
export JG_HOME=$FMH

# free_lanes: the target minus the working ship and Recon lanes; 0 when no target is set.
free_lanes() {
  local target working=0 meta kind last
  target=$(awk 'NF { print; exit }' "$CONFIG/lane-target" 2>/dev/null)
  case "$target" in ''|*[!0-9]*|0) echo 0; return ;; esac
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(sed -n 's/^kind=//p' "$meta" | head -1)
    case "${kind:-ship}" in ship|scout) ;; *) continue ;; esac
    last=$(grep -E '^(working|paused|blocked|needs-decision|done|failed)[ :[]' "${meta%.meta}.status" 2>/dev/null | tail -1)
    case "$last" in paused*|blocked*|needs-decision*|done*|failed*) ;; *) working=$((working + 1)) ;; esac
  done
  [ "$working" -lt "$target" ] && echo $((target - working)) || echo 0
}

# approved_field <id> <field>: the field's value in the id's approval record.
approved_field() { sed -n "s/^$2=//p" "$APPROVED/$1" 2>/dev/null | tail -n 1; }

# verdict <id>: prints "route<TAB>..." when the ticket passes reasons 1 to 5, else "why<TAB>...".
verdict() {
  local id=$1 rc route
  [ -f "$APPROVED/$id" ] || { printf 'why\tno approval record\n'; return; }
  "$HOLD" blocking "$id" >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) printf 'why\tan open decision is linked to it\n'; return ;;
    1) ;;
    *) printf 'why\tits open decisions could not be read\n'; return ;;
  esac
  grep -qx -- "$id" "$SPAWNABLE_IDS" || { printf 'why\tnot spawnable now (held, taken, closed, or not this home'"'"'s project)\n'; return; }
  [ -s "$DATA/$id/brief.md" ] || { printf 'why\tno brief\n'; return; }
  route="$(approved_field "$id" harness) $(approved_field "$id" model) $(approved_field "$id" effort)"
  case "$route" in ' '*|*'  '*|*' ') printf 'why\tthe approval record has no route\n'; return ;; esac
  printf 'route\t%s\n' "$route"
}

# last_verdict <id>: the "<kind><TAB><detail>" of the id's newest row ("would start" or "skipped").
last_verdict() { awk -F'\t' -v id="$1" '$2 == id { v = $3 "\t" $4 } END { if (v != "") print v }' "$ROWS" 2>/dev/null; }

tmp=$(mktemp -d) || exit 0
trap 'rm -rf -- "$tmp"' EXIT
SPAWNABLE_IDS=$tmp/spawnable
"$BACKLOG" ready --spawnable > "$tmp/out" 2>/dev/null || exit 0   # the store could not answer: write nothing this beat
awk -F'\t' 'NF >= 2 { print $1 }' "$tmp/out" > "$SPAWNABLE_IDS"
{ cat "$SPAWNABLE_IDS"; for f in "$APPROVED"/*; do [ -f "$f" ] && basename "$f"; done; } 2>/dev/null | sort -u > "$tmp/candidates"

free=$(free_lanes)
now=$(date +%s)
started=0
# List order is the store's; approved tickets the list lacks come last, and they never start.
{ grep -Fx -f "$SPAWNABLE_IDS" "$tmp/candidates" 2>/dev/null; grep -Fvx -f "$SPAWNABLE_IDS" "$tmp/candidates" 2>/dev/null; } > "$tmp/ordered"
while IFS= read -r id; do
  [ -n "$id" ] || continue
  v=$(verdict "$id")
  case "$v" in
    route$'\t'*)
      if [ "$started" -lt "$free" ]; then started=$((started + 1)); row="would start"$'\t'"${v#route$'\t'}"
      else row="skipped"$'\t'"no free lane left for it"; fi ;;
    *) row="skipped"$'\t'"${v#why$'\t'}" ;;
  esac
  [ "$(last_verdict "$id")" = "$row" ] || printf '%s\t%s\t%s\n' "$now" "$id" "$row" >> "$ROWS"
done < "$tmp/ordered"
exit 0

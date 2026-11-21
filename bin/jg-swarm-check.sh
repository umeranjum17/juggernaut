#!/usr/bin/env bash
# jg-swarm-check.sh - one line of swarm progress, one wake when a swarm ends or waits, and the dispatch switch put back.
# Usage: jg-swarm-check.sh status [<plan>] [--short]
#        jg-swarm-check.sh check <jg-home>
#
# Reads the records `bin/jg-swarm.sh start` and `bin/jg-swarm-arm.sh` write: data/swarm/<plan>/swarm.json (Main),
# plan.json (the derived plan) and arm.json (each owner home). It changes no backlog row.
# status prints `<plan>: <d>/<n> landed, <w> working, <q> queued (<k> wait for the owner), started <h>h<mm>m ago`
# (--short: `<plan> <d>/<n> landed, <w> working, <k> wait for the owner`), or `no swarm is running`.
# check, in Main, for each running swarm prints each of these once (a stamp under data/swarm/<plan>/ holds the counts):
#   `swarm <plan>: all <n> slices landed in <h>h<mm>m`   (swarm.json state becomes `finished`)
#   `swarm <plan>: all runnable slices landed; <k> wait for the owner: <row>[, <row>...]`
#   `swarm <plan>: no slice moved for <m> min; open: <row> (<reason>)[; ...]`   (only while a slice is open and none is in flight)
# check, in a home with an armed arm.json whose rows are all done, puts config/auto-dispatch and config/lane-target back
# to their `*_before` values, but only when no other arm.json of the home is armed and the file still holds what the arm
# wrote, and prints `swarm <plan>: <owner> restored its dispatch switch to <value>` once. A slice waits for the owner
# while its word row in Main is an open decision (jg-captain-hold.sh open exits 0). A failed slice stays open and is
# never skipped. A home that cannot be read is named on stderr and skipped.
# Test hook: JG_SWARM_NOW (the clock). Setting: config/swarm-stall-minutes (default 30).
set -u
export LC_ALL=C
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
umask 077
usage() { echo "usage: jg-swarm-check.sh status [<plan>] [--short] | check <jg-home>" >&2; exit 2; }
now() { printf '%s' "${JG_SWARM_NOW:-$(date +%s)}"; }
hm() { printf '%dh%02dm' $(($1 / 3600)) $(($1 % 3600 / 60)); }

declare -A ST OKH
# in_home <home> <script> <args...>: run one of that home's scripts against that home's own store and files.
in_home() {
  local h=$1 s=$2 b=$1/bin
  shift 2
  [ -x "$b/$s" ] || b=$SELF
  env -u JG_STATE_OVERRIDE -u JG_DATA_OVERRIDE -u JG_CONFIG_OVERRIDE JG_HOME="$h" "$b/$s" "$@"
}
# load_home <home>: read every row state of the home once (`list --all` rows: two spaces, id, state). 1 = unreadable.
load_home() {
  local h=$1 out id state
  [ -z "${OKH[$h]:-}" ] || return "$((1 - OKH[$h]))"
  if out=$(in_home "$h" jg-backlog.sh list --all 2> /dev/null) && [ -n "$out" ]; then
    while IFS=, read -r id state _; do ST["$h|$id"]=$state; done < <(printf '%s\n' "$out" | sed -n 's/^  \([^ -].*\)$/\1/p')
    OKH[$h]=1
    return 0
  fi
  echo "jg-swarm-check: cannot read the backlog of $h" >&2
  OKH[$h]=0
  return 1
}
state_of() { printf '%s' "${ST[$1|$2]:-queued}"; }

# evaluate <plan dir>: sets N D W Q K SIG, OPEN (rows), WAITING (rows), ALLSTUCK and ROW_HOME[row]. 1 = a home is unreadable.
evaluate() {
  local pf=$1/plan.json main sid row owner word deps h s d
  declare -gA ROW_HOME=() SLICE_ROW=() DEPS=() STUCK=()
  N=0 D=0 W=0 Q=0 K=0 OPEN=() WAITING=() ALLSTUCK=1
  main=$(jq -r '.main_home' "$pf") || return 1
  while IFS=$'\t' read -r sid row owner word deps; do
    h=$(jq -r --arg o "$owner" '.owner_homes[$o] // .main_home' "$pf")
    load_home "$h" || return 1
    N=$((N + 1)); ROW_HOME[$row]=$h; SLICE_ROW[$sid]=$row; DEPS[$row]=$deps
    s=$(state_of "$h" "$row")
    case $s in
      "done") D=$((D + 1)) ;;
      in_flight) W=$((W + 1)); OPEN+=("$row") ;;
      *) Q=$((Q + 1)); OPEN+=("$row")
        if [ -n "$word" ] && in_home "$main" jg-captain-hold.sh open "$word" > /dev/null 2>&1; then
          K=$((K + 1)); STUCK[$row]=1; WAITING+=("$row")
        fi ;;
    esac
  done < <(jq -r '.slices[] | [.id, (.row // ""), .owner_home, (.word_row // ""), ((.depends_on // []) | join(","))] | @tsv' "$pf")
  d=1
  while [ "$d" = 1 ]; do # a slice behind a slice that waits for the owner waits too
    d=0
    for row in "${OPEN[@]}"; do
      [ -z "${STUCK[$row]:-}" ] || continue
      for sid in ${DEPS[$row]//,/ }; do
        [ -n "${STUCK[${SLICE_ROW[$sid]:-}]:-}" ] && { STUCK[$row]=1; d=1; break; }
      done
    done
  done
  for row in "${OPEN[@]}"; do [ -n "${STUCK[$row]:-}" ] || ALLSTUCK=0; done
  SIG="$D $W $Q $K"
  return 0
}

running_plans() { # <data dir> [<plan>]: plan dirs whose swarm.json is running
  local f
  for f in "$1"/swarm/${2:-*}/swarm.json; do
    [ -f "$f" ] && [ "$(jq -r '.state' "$f" 2> /dev/null)" = running ] && dirname "$f"
  done
}

cmd_status() {
  local plan='' short=0 a dir p started n=0 home
  for a in "$@"; do case $a in --short) short=1 ;; -*) usage ;; *) plan=$a ;; esac; done
  home=${JG_HOME:-$(cd "$SELF/.." && pwd -P)}
  while read -r dir; do
    [ -n "$dir" ] || continue
    evaluate "$dir" || continue
    p=$(basename "$dir"); started=$(jq -r '.started_at' "$dir/swarm.json"); n=$((n + 1))
    if [ "$short" = 1 ]; then printf '%s %s/%s landed, %s working, %s wait for the owner\n' "$p" "$D" "$N" "$W" "$K"
    else printf '%s: %s/%s landed, %s working, %s queued (%s wait for the owner), started %s ago\n' "$p" "$D" "$N" "$W" "$Q" "$K" "$(hm $(($(now) - started)))"; fi
  done < <(running_plans "${JG_DATA_OVERRIDE:-$home/data}" "$plan")
  [ "$n" -gt 0 ] || echo "no swarm is running"
}

once() { # <stamp> <signature> <line>: print the line unless the stamp already holds the signature
  [ "$(cat "$1" 2> /dev/null)" = "$2" ] && return 0
  printf '%s\n' "$2" > "$1" && printf '%s\n' "$3"
}

reason_of() { # <row>: the row's latest reason in its home's rows.tsv
  awk -F'\t' -v id="$1" '$2 == id { r = $4 } END { print r }' "${ROW_HOME[$1]}/data/auto-dispatch/rows.tsv" 2> /dev/null
}

check_plan() { # <plan dir> <home>
  local dir=$1 home=$2 p t last sig m mins row list sep='' started
  p=$(basename "$dir"); t=$(now); started=$(jq -r '.started_at' "$dir/swarm.json")
  evaluate "$dir" || return 0
  if [ "$D" = "$N" ] && [ "$N" -gt 0 ]; then
    printf '%s\n' "$SIG" > "$dir/finished" && jq '.state = "finished"' "$dir/swarm.json" > "$dir/swarm.json.new" && mv "$dir/swarm.json.new" "$dir/swarm.json" \
      && printf 'swarm %s: all %s slices landed in %s\n' "$p" "$N" "$(hm $((t - started)))"
    return 0
  fi
  last=$t sig=''
  [ ! -f "$dir/last-change" ] || read -r last sig < "$dir/last-change" || true
  if [ "$sig" != "$SIG" ]; then printf '%s\t%s\n' "$t" "$SIG" > "$dir/last-change"; last=$t; fi
  if [ "$W" = 0 ] && [ "${#OPEN[@]}" -gt 0 ] && [ "$ALLSTUCK" = 1 ] && [ "$K" -gt 0 ]; then
    list=$(printf '%s, ' "${WAITING[@]}")
    once "$dir/owner-wait" "$SIG" "swarm $p: all runnable slices landed; $K wait for the owner: ${list%, }"
    return 0
  fi
  mins=$(cat "$home/config/swarm-stall-minutes" 2> /dev/null); case $mins in '' | *[!0-9]*) mins=30 ;; esac
  if [ "$W" = 0 ] && [ "${#OPEN[@]}" -gt 0 ] && [ $((t - last)) -ge $((mins * 60)) ]; then
    m=$(((t - last) / 60)); list=''
    for row in "${OPEN[@]}"; do list+="$sep$row ($(reason_of "$row" | sed 's/^$/no dispatch row/'))"; sep='; '; done
    once "$dir/stall" "$SIG" "swarm $p: no slice moved for $m min; open: $list"
  fi
}

# restore_file <file> <wrote> <before>: put <before> back (or remove the file) when the file still holds <wrote>. 0 = restored.
restore_file() {
  local w
  [ -f "$1" ] && [ -n "$2" ] && [ "$2" != null ] || return 1
  read -r w _ < "$1" || true
  [ "$w" = "$2" ] || return 1
  if [ "$3" = absent ]; then rm -f -- "$1"; else printf '%s\n' "$3" > "$1"; fi
}

check_arm() { # <arm.json> <home>
  local f=$1 home=$2 p owner row other o alldone=1 sw before
  [ "$(jq -r '.state' "$f" 2> /dev/null)" = armed ] || return 0
  load_home "$home" || return 0
  [ "$(jq '.rows | length' "$f")" -gt 0 ] || return 0
  while read -r row; do [ "$(state_of "$home" "$row")" = "done" ] || alldone=0; done < <(jq -r '.rows[]' "$f")
  [ "$alldone" = 1 ] || return 0
  p=$(jq -r '.plan' "$f"); owner=$(jq -r '.home' "$f"); sw=0
  for other in "$home"/data/swarm/*/arm.json; do
    [ "$other" != "$f" ] && [ "$(jq -r '.state' "$other" 2> /dev/null)" = armed ] && sw=1
  done
  if [ "$sw" = 0 ]; then
    before=$(jq -r '.switch_before' "$f")
    restore_file "$home/config/auto-dispatch" "$(jq -r '.switch_wrote' "$f")" "$before" \
      && printf 'swarm %s: %s restored its dispatch switch to %s\n' "$p" "$owner" "$before"
    restore_file "$home/config/lane-target" "$(jq -r '.lane_target_wrote' "$f")" "$(jq -r '.lane_target_before' "$f")"
  fi
  o=$(jq '.state = "finished"' "$f") && printf '%s\n' "$o" > "$f.new" && mv "$f.new" "$f"
}

cmd_check() {
  local home dir f
  [ "$#" -eq 1 ] && [ -d "$1" ] || usage
  home=$(cd "$1" && pwd -P)
  while read -r dir; do [ -n "$dir" ] && check_plan "$dir" "$home"; done < <(running_plans "$home/data")
  for f in "$home"/data/swarm/*/arm.json; do [ -f "$f" ] && check_arm "$f" "$home"; done
  return 0
}

case "${1:-}" in
  status) shift; cmd_status "$@" ;;
  check) shift; cmd_check "$@" ;;
  *) usage ;;
esac

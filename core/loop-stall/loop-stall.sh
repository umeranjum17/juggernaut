#!/usr/bin/env bash
# loop-stall.sh - a Blitz plan or a Goal with ready work that makes no progress for 10 minutes raises a P1 that only progress clears.
# Usage: loop-stall.sh tick <jg-home>
#
# Blitz and core/goal-loop advance with no model turn, so a loop that stops advancing has nobody to notice it. The delivery tick
# (bin/jg-delivery-tick.sh) runs this with no model awake. Two read-only feeds say what is ready, and this script holds the clock and the alert:
#   Blitz  `bin/jg-swarm-check.sh ready`          a running plan with a slice it could start and none in flight; its signature is the plan's counts
#   Goal   `core/goal-loop/goal-loop.sh state`    a Goal whose current step is `next` (open, nobody has taken it); its signature is that step
# A candidate whose signature held for JG_LOOP_STALL_SECS (default 600) raises one `fleet-blocked` P1 (bin/jg-alert.sh, rung 2, the way the
# nothing-lands alert of core/trunk-landing does), keyed fleet-blocked--blitz-<plan>-stalled or fleet-blocked--goal-<goal>-stalled. A live alert
# climbs on each later tick. An acknowledgement, a drained wake or a repeat never closes it: only progress does, and the resolve names it as its
# proof. Progress is a changed signature (a slice started or landed, the step taken or replaced), or the loop no longer having ready work
# (finished, stopped for the owner, its step taken). A feed that cannot be read changes nothing: unknown is never progress.
# Records: <data>/loop-stall/<kind>--<subject>.tsv holds `<since><TAB><signature>`. Test hooks: JG_LOOP_STALL_SECS, JG_LOOP_STALL_NOW.
set -u
export LC_ALL=C
{ [ "$#" -eq 2 ] && [ "$1" = tick ] && [ -d "$2" ]; } || { sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
H=$(cd "$2" && pwd -P)
STATE=${JG_STATE_OVERRIDE:-$H/state}
DATA=${JG_DATA_OVERRIDE:-$H/data}/loop-stall
ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
AFTER=${JG_LOOP_STALL_SECS:-600}
case $AFTER in '' | *[!0-9]* | 0*) echo "loop-stall: JG_LOOP_STALL_SECS must be positive decimal seconds" >&2; exit 2 ;; esac
NOW=${JG_LOOP_STALL_NOW:-$(date +%s)}
umask 077
mkdir -p "$DATA" || exit 1
alert() { JG_HOME=$H JG_STATE_OVERRIDE=$STATE bash "$ROOT/bin/jg-alert.sh" "$@"; }
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._\n-' '-'; }
live() { case $(alert word "$1" 2>/dev/null) in '' | resolved) return 1 ;; *) return 0 ;; esac; }

# resolve_progress <kind> <subject> <what moved>: the loop moved, so its alert (if live) closes with that as proof and its clock is dropped.
resolve_progress() {
  local key=fleet-blocked--$1-$2-stalled
  if live "$key"; then
    alert resolve "$key" --proof "source:progress-$3" > /dev/null || { echo "loop-stall: could not resolve $key" >&2; return 1; }
  fi
  rm -f -- "$DATA/$1--$2.tsv"
}

# hold <kind> <subject> <signature> <note>: one ready, unmoved candidate; start or keep its clock, and raise or climb the alert once it is due.
hold() {
  local kind=$1 subject=$2 sig=$3 note=$4 rec since='' old='' key held
  rec=$DATA/$kind--$subject.tsv
  key=fleet-blocked--$kind-$subject-stalled
  [ ! -f "$rec" ] || IFS=$'\t' read -r since old < "$rec" || since=
  case $since in '' | *[!0-9]*) since='' ;; esac
  if [ -z "$since" ] || [ "$old" != "$sig" ]; then
    [ -z "$since" ] || resolve_progress "$kind" "$subject" moved || return 0
    printf '%s\t%s\n' "$NOW" "$sig" > "$rec"
    return 0
  fi
  held=$((NOW - since))
  [ "$held" -ge "$AFTER" ] || return 0
  if live "$key"; then
    { alert climb "$key" 2> /dev/null || true; } | alert deliver > /dev/null
  else
    alert raise fleet-blocked "$kind-$subject-stalled" --rung 2 --deliver \
      --note "$kind $subject has ready work and has not moved for $((held / 60)) min: $note" > /dev/null \
      || echo "loop-stall: the stall alert for $kind $subject was not raised" >&2
  fi
}

# sweep <kind> <candidate subjects, one per line> <subjects that could not be read>: every record of the kind not named has no ready work.
sweep() {
  local kind=$1 cands=$2 unread=$3 rec s
  for rec in "$DATA/$kind"--*.tsv; do
    [ -f "$rec" ] || continue
    s=${rec##*/}; s=${s#"$kind"--}; s=${s%.tsv}
    printf '%s\n%s\n' "$cands" "$unread" | grep -Fxq -- "$s" || resolve_progress "$kind" "$s" ready-work-gone
  done
  # A live alert with no record (the record was lost) is closed by the same rule, never left to stand on nothing.
  while IFS= read -r s; do
    s=${s#fleet-blocked--"$kind"-}; s=${s%-stalled}
    printf '%s\n%s\n' "$cands" "$unread" | grep -Fxq -- "$s" || resolve_progress "$kind" "$s" ready-work-gone
  done < <(alert list 2> /dev/null | grep -E "^fleet-blocked--$kind-.+-stalled\$")
}

tick_blitz() {
  local out plan sig rows cands='' unread=''
  out=$(bash "$ROOT/bin/jg-swarm-check.sh" ready "$H" 2> /dev/null) || return 0
  while IFS=$'\t' read -r plan sig rows; do
    [ -n "$plan" ] || continue
    plan=$(slug "$plan")
    if [ "$sig" = unread ]; then unread+="$plan"$'\n'; continue; fi
    cands+="$plan"$'\n'
    hold blitz "$plan" "$sig" "open $rows"
  done <<< "$out"
  sweep blitz "$cands" "$unread"
}

tick_goal() {
  local out id st step ask cands='' _r
  out=$(bash "$ROOT/core/goal-loop/goal-loop.sh" state "$H" 2> /dev/null) || return 0
  while IFS=$'\t' read -r id st step ask _r; do
    [ "$st" = next ] || continue
    id=$(slug "$id"); cands+="$id"$'\n'
    hold goal "$id" "$step" "its $step step ($ask) waits to be taken"
  done <<< "${out//$'\t\t'/$'\t-\t'}"
  sweep goal "$cands" ""
}

tick_blitz
tick_goal
exit 0

#!/usr/bin/env bash
# goal-loop watcher check: pick the next step of every open Goal with no model, and wake the lead for it.
# Usage: goal-loop.sh check <jg-home>     one wake line per Goal whose next step is new, nothing otherwise
#        goal-loop.sh state <jg-home>     one line per open Goal: <goal id> <TAB> <state> <TAB> <step> <TAB> <ask>
#
# A Goal is a Beads epic (bin/jg-goal.sh). The check reads every Goal row once, through `jg-goal.sh rows`,
# and reduces each open Goal to one state:
#   finished  every step is closed
#   stopped   a row is on_hold or blocked; the stop is the owner's or a real blocker's, never retried here
#   waiting   the current step is taken (in progress); nothing to raise
#   next      the current step is open and nobody has taken it; the lead is woken to run it
# The steps are ship, merged, released, running and proven, in that order; the first step not closed is current.
# An open `fix` step (added when a proof fails) is current before them. The lead runs ship and fix; the check
# itself owns proven: it starts the Goal's proof detached (proof-run.sh), reads the result on a later pass, and
# closes the step only when the proof exits 0 from an unchanged finish line (jg-goal.sh prove). It never wakes
# the lead for proven. A failed proof adds a fix step, and a repeated failure or a changed finish line stops the Goal.
# The check is level-triggered: a wake rings once for a Goal and step, again only after JG_GOAL_RESURFACE_SECS
# (1800) while the step is still open, and a Goal that leaves `next` forgets its record, so the same step
# rings at once if it comes back. Records sit in <home>/data/jg-goal-loop/, never in state/.
# A home with no Goal store configured is silent. A store that cannot be read raises one wake line per
# reason; the wrapper's own refusal text is the reason, and no other bd is tried.
# A stop gets one message (jg-goal.sh notice) and a finish gets one message and closes the epic (jg-goal.sh finish).
# Each message is keyed on the epic before it is printed, so a second pass or a restart prints nothing twice.
# A stopped Goal costs no wake after its message. Closing the stop row (jg-goal.sh resume) is the whole resume.
# Reads are bounded with timeout. The only writes are those two, each a short guarded row update, and each is
# recorded before it is acted on, so a cut write is repeated safely on the next pass.
set -u
case "${1:-}" in check|state) ;; *) echo "usage: goal-loop.sh check|state <jg-home>" >&2; exit 2 ;; esac
[ "$#" -eq 2 ] && [ -d "$2/state" ] || { echo "usage: goal-loop.sh check|state <jg-home>" >&2; exit 2; }
verb=$1
HOME_DIR=$(cd "$2" && pwd -P)
GOAL=${JG_GOAL_BIN:-$HOME_DIR/bin/jg-goal.sh}
DATA=$HOME_DIR/data/jg-goal-loop
RESURFACE=${JG_GOAL_RESURFACE_SECS:-1800}
RUNNER=${JG_GOAL_PROOF_RUN:-$(dirname "${BASH_SOURCE[0]}")/proof-run.sh}
PROOF_SECS=${JG_GOAL_PROOF_SECS:-900}
case $RESURFACE in ''|*[!0-9]*) RESURFACE=1800 ;; esac
now=$(date +%s)
umask 077

[ -n "${GOAL_BEADS_DIR:-}" ] || [ -s "$HOME_DIR/config/goal-beads-dir" ] || exit 0
mkdir -p "$DATA"

err=$DATA/.read.err
if ! rows=$(JG_HOME=$HOME_DIR timeout 20 "$GOAL" rows 2>"$err"); then
  reason=$(grep -m1 . "$err" | cut -c1-200)
  [ "$verb" = check ] || { echo "goal-loop: ${reason:-the Goal store could not be read}" >&2; exit 1; }
  sig=$(printf '%s' "${reason:-unread}" | cksum | cut -d' ' -f1)
  [ "$(cat "$DATA/store-refused" 2>/dev/null)" = "$sig" ] || {
    printf '%s\n' "$sig" > "$DATA/store-refused"
    echo "goal-loop: the Goal store could not be read - ${reason:-no reason given}; no Goal moves until it can"
  }
  exit 0
fi
rm -f "$DATA/store-refused"

# One reduction for every Goal: <id> TAB <state> TAB <step or stop row> TAB <ask> TAB <message already sent>.
states=$(jq -r '
  def rank: ["ship","merged","released","running","proven"];
  . as $all
  | $all[] | select(.issue_type == "epic" and .status != "closed") | . as $e
  | [$all[] | select(.parent == $e.id)] as $kids
  | ($kids | map(select(.status == "on_hold" or .status == "blocked")) | first) as $hold
  | ($kids | map(select(.metadata.kind as $k | rank | index($k))) | sort_by(.metadata.kind as $k | rank | index($k))
     | map(select(.status != "closed")) | first) as $cur
  | ($e.metadata.goal.ask // $e.title | gsub("[\\t\\n]"; " ")) as $ask
  | ($e.metadata // {}) as $m | ("sent_goal_" + ($e.id | gsub("[^A-Za-z0-9]"; "_")) + "_") as $sk
  | (($kids | map(select(.metadata.kind == "fix" and .status != "closed")) | first) // $cur) as $cur
  | (if $hold then ["stopped", $hold.id]
     elif $cur == null then ["finished", ""]
     elif $cur.status == "open" then ["next", $cur.metadata.kind]
     else ["waiting", $cur.metadata.kind] end) as $r
  | (if $r[0] == "stopped" then $m | has($sk + "stop_" + ($r[1] | gsub("[^A-Za-z0-9]"; "_")))
     elif $r[0] == "finished" then $m | has($sk + "finish") else false end) as $sent
  | [$e.id, $r[0], $r[1], $ask, (if $sent then "sent" else "new" end)] | @tsv' <<< "$rows" 2>/dev/null) || { echo "goal-loop: the Goal rows were not readable JSON" >&2; exit 1; }
[ "$verb" = check ] || { [ -z "$states" ] || printf '%s\n' "$states"; exit 0; }

# Run one write verb of jg-goal.sh and print its message. A write that fails rings once per reason.
announce() {  # <goal id> <verb> <args...>
  local id=$1 out sig
  shift
  out=$(JG_HOME=$HOME_DIR timeout 25 "$GOAL" "$@" 2>&1 < /dev/null)
  case $? in  # 3 is a verb that made a stop instead of acting
    0) [ -z "$out" ] || echo "goal-loop: $out"; rm -f "$DATA/write-failed"; return 0 ;;
    3) rm -f "$DATA/write-failed"; return 3 ;;
  esac
  sig=$(printf '%s' "$id $out" | cksum | cut -d' ' -f1)
  [ "$(cat "$DATA/write-failed" 2>/dev/null)" = "$sig" ] && return 1
  printf '%s\n' "$sig" > "$DATA/write-failed"
  echo "goal-loop: $id: jg-goal.sh $1 failed - $(printf '%s' "$out" | grep -m1 . | cut -c1-200); it is tried again on the next pass"
  return 1
}

# The proven step belongs to the check: start the proof once (detached), then read its exit on a later pass.
proof_tick() {  # <goal id> <state>
  local id=$1 dir=$HOME_DIR/data/goals/$1 argv=() code
  if [ "$2" = next ]; then
    [ -x "$RUNNER" ] || { echo "goal-loop: $id: the proof runner is missing ($RUNNER)"; return 0; }
    announce "$id" proof-start "$id" || return 0
    mapfile -t argv < <(jq -r '.proof[]' "$dir/finish.json" 2>/dev/null)
    [ "${#argv[@]}" -gt 0 ] || return 0
    if command -v setsid >/dev/null 2>&1; then setsid -f "$RUNNER" "$dir" "$HOME_DIR" "$PROOF_SECS" "${argv[@]}" >/dev/null 2>&1 < /dev/null
    else nohup "$RUNNER" "$dir" "$HOME_DIR" "$PROOF_SECS" "${argv[@]}" >/dev/null 2>&1 < /dev/null & fi
  elif [ -f "$dir/proof.exit" ]; then
    code=$(cat "$dir/proof.exit")
    if [ "$code" = 0 ]; then announce "$id" prove "$id"; else announce "$id" proof-failed "$id" "$code"; fi
  elif [ -f "$dir/proof.pid" ] && ! kill -0 "$(cat "$dir/proof.pid")" 2>/dev/null; then
    announce "$id" proof-failed "$id" lost
  fi
  return 0
}

seen=' '
while IFS=$'\t' read -r id st step ask sent; do
  [ -n "$id" ] || continue
  seen="$seen$id "
  rec=$DATA/$id.next
  [ "$st" != stopped ] || [ "$sent" = sent ] || announce "$id" notice "$id" "$step"
  [ "$st" != finished ] || announce "$id" finish "$id"
  if [ "$step" = proven ] && { [ "$st" = next ] || [ "$st" = waiting ]; }; then proof_tick "$id" "$st"; rm -f "$rec"; continue; fi
  if [ "$st" != next ]; then rm -f "$rec"; continue; fi
  if [ -f "$rec" ]; then
    read -r last_step last_at < "$rec"
    [ "$last_step" != "$step" ] || [ $((now - ${last_at:-0})) -ge "$RESURFACE" ] || continue
  fi
  printf '%s %s\n' "$step" "$now" > "$rec"
  echo "goal-loop: $id is ready for its $step step ($ask) - run it, then close its $step row; bin/jg-goal.sh show $id lists the steps"
done <<< "${states//$'\t\t'/$'\t-\t'}"
for rec in "$DATA"/*.next; do  # a Goal that is closed or cancelled leaves its record behind
  [ -e "$rec" ] || continue
  name=${rec##*/}
  case "$seen" in *" ${name%.next} "*) ;; *) rm -f "$rec" ;; esac
done
exit 0

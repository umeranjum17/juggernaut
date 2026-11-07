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
# The check is level-triggered: a wake rings once for a Goal and step, again only after JG_GOAL_RESURFACE_SECS
# (1800) while the step is still open, and a Goal that leaves `next` forgets its record, so the same step
# rings at once if it comes back. Records sit in <home>/data/jg-goal-loop/, never in state/.
# A home with no Goal store configured is silent. A store that cannot be read raises one wake line per
# reason; the wrapper's own refusal text is the reason, and no other bd is tried.
# Every read is bounded with timeout, so the watcher's kill cannot cut a write: the check only reads Beads.
set -u
case "${1:-}" in check|state) ;; *) echo "usage: goal-loop.sh check|state <jg-home>" >&2; exit 2 ;; esac
[ "$#" -eq 2 ] && [ -d "$2/state" ] || { echo "usage: goal-loop.sh check|state <jg-home>" >&2; exit 2; }
verb=$1
HOME_DIR=$(cd "$2" && pwd -P)
GOAL=${JG_GOAL_BIN:-$HOME_DIR/bin/jg-goal.sh}
DATA=$HOME_DIR/data/jg-goal-loop
RESURFACE=${JG_GOAL_RESURFACE_SECS:-1800}
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

# One reduction for every Goal: <id> TAB <state> TAB <step or stop row> TAB <ask>.
states=$(jq -r '
  def rank: ["ship","merged","released","running","proven"];
  . as $all
  | $all[] | select(.issue_type == "epic" and .status != "closed") | . as $e
  | [$all[] | select(.parent == $e.id)] as $kids
  | ($kids | map(select(.status == "on_hold" or .status == "blocked")) | first) as $hold
  | ($kids | map(select(.metadata.kind as $k | rank | index($k))) | sort_by(.metadata.kind as $k | rank | index($k))
     | map(select(.status != "closed")) | first) as $cur
  | ($e.metadata.goal.ask // $e.title | gsub("[\\t\\n]"; " ")) as $ask
  | (if $hold then ["stopped", $hold.id]
     elif $cur == null then ["finished", ""]
     elif $cur.status == "open" then ["next", $cur.metadata.kind]
     else ["waiting", $cur.metadata.kind] end) as $r
  | [$e.id, $r[0], $r[1], $ask] | @tsv' <<< "$rows" 2>/dev/null) || { echo "goal-loop: the Goal rows were not readable JSON" >&2; exit 1; }
[ "$verb" = check ] || { [ -z "$states" ] || printf '%s\n' "$states"; exit 0; }

seen=' '
while IFS=$'\t' read -r id st step ask; do
  [ -n "$id" ] || continue
  seen="$seen$id "
  rec=$DATA/$id.next
  if [ "$st" != next ]; then rm -f "$rec"; continue; fi
  if [ -f "$rec" ]; then
    read -r last_step last_at < "$rec"
    [ "$last_step" != "$step" ] || [ $((now - ${last_at:-0})) -ge "$RESURFACE" ] || continue
  fi
  printf '%s %s\n' "$step" "$now" > "$rec"
  echo "goal-loop: $id is ready for its $step step ($ask) - run it, then close its $step row; bin/jg-goal.sh show $id lists the steps"
done <<< "$states"
for rec in "$DATA"/*.next; do  # a Goal that is closed or cancelled leaves its record behind
  [ -e "$rec" ] || continue
  name=${rec##*/}
  case "$seen" in *" ${name%.next} "*) ;; *) rm -f "$rec" ;; esac
done
exit 0

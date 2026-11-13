#!/usr/bin/env bash
# End a running landing through the landing check's own path: the one command behind `bin/jg-trunk.sh cancel`.
# Usage: cancel.sh <jg-home> <task-id> <reason>
#
# The landing run that holds <task-id> (a single `run` or the `runbatch` stack the lane is in) is a detached job that leads its own
# process group (core/trunk-landing/trunk-landing.sh starts it with setsid). The command:
#   1. finds the run from the lane's `running <epoch> <pid>` state line, and refuses when there is none or the pid is not a landing run;
#   2. stops that process group (TERM, then KILL after JG_TRUNK_CANCEL_GRACE seconds, default 10), so the gate under it ends too;
#   3. clears the run's state: the running line of every lane of the run, the locks the run's processes held (the run, the landing,
#      the lane, the gate mark, the front and the project lock), and the front record;
#   4. records why: one row in data/jg-trunk-landing/cancelled.tsv and one outbox line for Overwatch;
#   5. starts the next ready lane (`trunk-landing.sh next`), so the queue moves on with no raw kill.
# A run whose owner is already gone (a state line and locks nothing holds) gets steps 3 to 5. Nothing is forced: a lane that was
# landed stays landed, and a lane that was not stays on its branch and is tried again by the check.
set -u
[ "$#" -eq 3 ] || { echo "usage: cancel.sh <jg-home> <task-id> <reason>" >&2; exit 2; }
[ -d "$1/state" ] || { echo "error: $1 has no state directory" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P); ID=$2; REASON=$3
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "error: invalid task id" >&2; exit 2; }
[ -n "$REASON" ] || { echo "error: a cancel records why: give a reason" >&2; exit 2; }
STATE=$FMH/state; MEM=$FMH/data/jg-trunk-landing
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/jg-wake-lib.sh
. "$FMH/bin/jg-wake-lib.sh"

# The lane's running state line: `running <epoch> <pid>` in <task>.<head>.state. Prints "<head> <pid>".
head=; pid=
for f in "$MEM/$ID".*.state; do
  [ -f "$f" ] || continue
  rest=${f#"$MEM/$ID."}; h=${rest%.state}
  [[ $h =~ ^[0-9a-f]{40,64}$ ]] || continue  # an admission record (<task>.<head>.<context>.state) is not a landing
  read -r phase _ p < "$f" || :
  [ "$phase" = running ] || continue
  head=$h; pid=${p:-}; break
done
[ -n "$head" ] || { echo "REFUSED: no landing is running for $ID (no running state in $MEM); nothing to cancel" >&2; exit 1; }
if [ -z "$pid" ]; then pid=$(cat "$STATE/.trunk-run-$ID-$head.lock/pid" 2>/dev/null || true); fi

killed=
if jg_pid_alive "$pid"; then
  # Never signal a group that is not a landing run's own: the pid must still be a trunk-landing job leading its group.
  args=$(ps -o args= -p "$pid" 2>/dev/null || true); pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  case $args in *trunk-landing.sh*) ;; *) echo "REFUSED: pid $pid is not a landing run ($args); it was not signalled" >&2; exit 1 ;; esac
  [ "$pgid" = "$pid" ] || { echo "REFUSED: landing run $pid does not lead its own process group (group $pgid); it was not signalled" >&2; exit 1; }
  killed=$(ps -o pid= -g "$pgid" 2>/dev/null | tr -d ' ' | paste -sd' ' -)
  kill -TERM -- "-$pgid" 2>/dev/null || :
  for _ in $(seq 1 $(( ${JG_TRUNK_CANCEL_GRACE:-10} * 10 ))); do
    pgrep -g "$pgid" >/dev/null 2>&1 || break
    sleep 0.1
  done
  if pgrep -g "$pgid" >/dev/null 2>&1; then
    kill -KILL -- "-$pgid" 2>/dev/null || :
    for _ in $(seq 1 50); do pgrep -g "$pgid" >/dev/null 2>&1 || break; sleep 0.1; done
  fi
  ! pgrep -g "$pgid" >/dev/null 2>&1 || { echo "error: landing run $pid (group $pgid) is still alive after KILL; its state and locks were left" >&2; exit 1; }
fi

# The run's lanes: every lane whose running line names this pid (a stack), or this lane alone when it never published one.
lanes=$ID
if [ -n "$pid" ]; then
  for f in "$MEM"/*.state; do
    [ -f "$f" ] || continue
    read -r phase _ p < "$f" || :
    [ "$phase" = running ] && [ "${p:-}" = "$pid" ] || continue
    b=${f##*/}; b=${b%.state}; l=${b%%.*}
    case " $lanes " in *" $l "*) ;; *) lanes="$lanes $l" ;; esac
  done
fi
for l in $lanes; do
  for f in "$MEM/$l".*.state; do
    [ -f "$f" ] || continue
    case $(cat "$f" 2>/dev/null) in running*) ;; *) continue ;; esac
    rest=${f#"$MEM/$l."}; rest=${rest%.state}
    # A lane still on its branch waits (the landing check's own backoff, so the lane it was holding back goes first); an admission
    # record or a lane already cleaned up leaves nothing behind.
    if [[ $rest =~ ^[0-9a-f]{40,64}$ && -f "$STATE/$l.meta" ]]; then printf 'wait cancelled by Overwatch: %s\n' "$REASON" > "$f"; else rm -f -- "$f"; fi
  done
done

# The locks the stopped processes held. A lock whose recorded holder is one of them (or a dead pid we were handed) is removed.
for lock in "$STATE"/.*.lock; do
  [ -d "$lock" ] || continue
  held=$(cat "$lock/pid" 2>/dev/null || true)
  [ -n "$held" ] || continue
  case " $killed $pid " in *" $held "*) ;; *) continue ;; esac
  jg_pid_alive "$held" && continue
  jg_lock_remove_path "$lock" || rm -rf -- "$lock"
done
# A front record names a gate that is running: the stopped run's own exit may have let its lock go first, so the record goes when no
# live process holds the project's front lock.
for rec in "$STATE"/trunk-front-*; do
  [ -f "$rec" ] || continue
  held=$(cat "$STATE/.${rec##*/}.lock/pid" 2>/dev/null || true)
  jg_pid_alive "$held" || rm -f -- "$rec"
done

mkdir -p "$MEM"
printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$lanes" "$head" "${pid:-none}" "$REASON" >> "$MEM/cancelled.tsv"
jg_lock_acquire_wait "$MEM/.outbox.lock"
printf 'trunk-landing: cancelled the landing run of %s (stopped process group %s, state and locks cleared): %s\n' "${lanes// /, }" "${pid:-none}" "$REASON" >> "$MEM/outbox"
jg_lock_release "$MEM/.outbox.lock"
printf 'cancelled the landing run of %s (pid %s): %s\n' "${lanes// /, }" "${pid:-none}" "$REASON"
"$SELF_DIR/trunk-landing.sh" next "$FMH" >/dev/null 2>&1 || :
exit 0

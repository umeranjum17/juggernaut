#!/usr/bin/env bash
# cleanup-retry.sh - a landed lane is cleaned up in the same step that landed it (sourced by trunk-landing.sh).
#
# Machine 20 (delivering), state `landed`, with machine 10 (cleanup) as its last step. The landing check calls `lane_cleanup` at the
# lane's own `landed` line, while the lander still runs for the rest of a stack. One attempt runs bin/jg-teardown.sh, never forced. The
# attempt ends in one of three ways, by the table below (cleanup_attempt_class):
#   cleaned   teardown succeeded.                                  state `landed cleaned up`
#   time      the refusal only needs time: a lock held, a copy allocation or a lifecycle action in progress, or a read past its bound
#             (check-failed). The lane is tried again at 15 s, 1, 2 and 5 minutes by a detached job (`trunk-landing.sh cleanup`), so the
#             stack's later lanes are never held back. State `landed cleanup waits: <why>`; when the ladder ends, the last reason is final.
#   final     any other refusal. Its reason is one word of the closed list core/machines/cleanup-reason.states, and one alert goes to the
#             outbox. State `landed cleanup refused, nothing was forced: reason: <word>`.
# Needs from the caller: STATE, MEM, FMH, SELF, and jg-wake-lib.sh (jg_lock_acquire_wait).

CLEANUP_LADDER_DEFAULT="15 60 120 300"

# The delays of the retry ladder, in seconds. A test may shorten them (JG_TEST_SEAM=1 and JG_CLEANUP_LADDER).
cleanup_ladder() {
  if [ "${JG_TEST_SEAM:-}" = 1 ] && [ -n "${JG_CLEANUP_LADDER:-}" ]; then printf '%s\n' "$JG_CLEANUP_LADDER"; else printf '%s\n' "$CLEANUP_LADDER_DEFAULT"; fi
}

# The class of one teardown refusal text: `time` or `final <reason>`. The reason is read from the text's `reason: <word>` and is kept only
# when it is a word of the closed list; any other text is `check-failed`, the list's word for a check that could not run.
cleanup_refusal_class() {  # <teardown output>
  local text=$1 reason
  case $text in
    *'slot allocation or return is in progress'*|*'lifecycle action is already running'*|*'liveness check is in progress'*|*'timed out'*) echo time; return 0 ;;
  esac
  reason=$(printf '%s\n' "$text" | sed -n 's/.*reason: \([a-z-]*\).*/\1/p' | tail -n 1)
  [ -n "$reason" ] && grep -q "^$reason	" "${SELF%/*}/../machines/cleanup-reason.states" 2>/dev/null || reason=check-failed
  # check-failed is the safety check itself failing to read, which is time-bound.
  if [ "$reason" = check-failed ]; then echo time; else printf 'final %s\n' "$reason"; fi
}

# One attempt. Prints `cleaned`, `time <why>` or `final <reason>`; the lane's state file is the caller's to write.
cleanup_attempt() {  # <task-id>
  local out
  out=$(JG_HOME="$FMH" "$FMH/bin/jg-teardown.sh" "$1" 2>&1) && { echo cleaned; return 0; }
  case $(cleanup_refusal_class "$out") in
    time) printf 'time %s\n' "$(printf '%s' "$out" | tail -n 1 | cut -c1-200)" ;;
    *) cleanup_refusal_class "$out" ;;
  esac
}

cleanup_outbox() {  # <line>
  jg_lock_acquire_wait "$MEM/.outbox.lock"; printf 'trunk-landing: %s\n' "$1" >> "$MEM/outbox"; jg_lock_release "$MEM/.outbox.lock"
}

# Write the state of an attempt for the heads the lane has had, and tell Overwatch about a final one. Prints the state text.
cleanup_record() {  # <task-id> <result from cleanup_attempt> <head>...
  local id=$1 res=$2 text h; shift 2
  case $res in
    cleaned) text='cleaned up' ;;
    time*) text="cleanup waits for time, retried at 15 s, 1, 2 and 5 minutes: ${res#time }" ;;
    final*) text="cleanup refused, nothing was forced: reason: ${res#final }" ;;
  esac
  for h in "$@"; do [ -z "$h" ] || printf 'landed %s\n' "$text" > "$MEM/$id.$h.state"; done
  printf '%s\n' "$text"
}

# Called at a lane's landed line. First attempt now; a refusal that needs time starts the detached ladder. Prints the state text.
lane_cleanup() {  # <task-id> <head> [<head now on the branch>]
  local id=$1 head=$2 now=${3:-} res text
  res=$(cleanup_attempt "$id")
  text=$(cleanup_record "$id" "$res" "$head" "$now")
  case $res in
    time*) setsid nohup "$SELF" cleanup "$FMH" "$id" "$head" "$now" >/dev/null 2>&1 < /dev/null & ;;
    final*) cleanup_outbox "ALERT: $id landed but its cleanup is refused, reason: ${res#final }; the lane's copy stays until the cause is fixed" ;;
  esac
  printf '%s\n' "$text"
}

# The detached ladder (`trunk-landing.sh cleanup <home> <id> <head> [<now>]`): waits each delay, tries again, stops at the first
# cleaned or final result, and makes the last reason final when the ladder ends.
cleanup_ladder_run() {  # <task-id> <head> [<head now>]
  local id=$1 head=$2 now=${3:-} delay res n=0
  jg_lock_try_acquire "$STATE/.trunk-cleanup-$id.lock" || return 0
  trap 'jg_lock_release "$STATE/.trunk-cleanup-$id.lock"' EXIT
  for delay in $(cleanup_ladder); do
    n=$((n + 1)); sleep "$delay"
    [ -f "$STATE/$id.meta" ] || { cleanup_record "$id" cleaned "$head" "$now" >/dev/null; return 0; }  # cleaned by another path
    res=$(cleanup_attempt "$id")
    case $res in
      cleaned) cleanup_record "$id" "$res" "$head" "$now" >/dev/null; cleanup_outbox "$id: cleaned up on retry $n"; return 0 ;;
      final*) cleanup_record "$id" "$res" "$head" "$now" >/dev/null; cleanup_outbox "ALERT: $id landed but its cleanup is refused, reason: ${res#final }; the lane's copy stays until the cause is fixed"; return 0 ;;
      *) cleanup_record "$id" "$res" "$head" "$now" >/dev/null ;;
    esac
  done
  cleanup_record "$id" "final check-failed" "$head" "$now" >/dev/null
  cleanup_outbox "ALERT: $id landed but its cleanup is still refused after the retries (${res#time }), reason: check-failed; the lane's copy stays until the cause is fixed"
}

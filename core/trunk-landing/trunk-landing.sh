#!/usr/bin/env bash
# trunk-landing watcher check: land a task into the local trunk by itself once its worker reports done.
# Usage: trunk-landing.sh check <jg-home>
#        trunk-landing.sh next <jg-home>                      (what a finished landing starts: the next ready lane, silently)
#        trunk-landing.sh run <jg-home> <task-id> <head>      (what `check` starts in the background)
#        trunk-landing.sh runbatch <jg-home> <task-id>@<head>...     (what `check` starts when 2 or more lanes are queued: one stack)
#        trunk-landing.sh live <jg-home> <project>                   (what a tick starts under a go-live waiver: the batched live step)
#        trunk-landing.sh nightly <jg-home> <project>                (what a tick starts once a day from nightly-hour: bin/jg-trunk.sh nightly, the whole suite on the tip through the same verify)
#        trunk-landing.sh verify <jg-home> <project>                 (what a tick starts while the trunk tip is above the green pin: bin/jg-trunk.sh verify, one at a time)
#        trunk-landing.sh publish <jg-home> <project>                (what a tick starts under a release waiver: bin/jg-trunk.sh publish, the green pin or a candidate after a red)
#
# For each state/<task>.meta in the home with a local-style mode (the table row `local` or its old words) whose project is registered local-trunk and has a trunk
# (state/trunk-tip-<project>, made by bin/jg-trunk.sh init), whose ship branch is not on the trunk yet and whose
# state/<task>.status ends with a `done` line, `check` starts `bin/jg-trunk.sh land <task>` detached and records
# the outcome in <home>/data/jg-trunk-landing/<task>.<head>.state. The worker's done is the signal, and the lane's whole proof must be there at its head (completion
# receipt, approved merge-card evidence, sealed done-done run: `jg-trunk.sh proof`) before a landing starts; a lane without it is
# reported once and left, and lands on its own once the proof is complete. The owner signature is never waited for. The lander rebases the lane's
# commit onto the trunk tip by itself, so a moved trunk is never a refusal. Lanes land oldest done first, and a
# finished landing starts the next at once (`next`), so three lanes ready together land in order with no human or lead step. While one
# lane gates on the trunk tip a second may start, gated on top of the first one's commit (at most the window W of gates at once, default 2: the
# second lands right behind the first, or is gated again on the tip when the first does not land; bin/jg-trunk.sh owns it). The number
# of gates the check keeps is the window W of core/trunk-landing/window.sh: it grows by one on a landing, halves on a red gate, and is
# capped by gate-slots and the host's heavy slots; bin/jg-trunk.sh chains that many gates in order.
# When 2 or more lanes are ready, the check stacks up to batch-max (5) of them, oldest done first, into one `bin/jg-trunk.sh land-batch`:
# one gate over the stack, one trunk move, and only a lane that conflicts or causes a red is returned (reported once, like any refusal).
# A single ready lane keeps the path above. A landing runs no whole-suite test and never moves the green pin. Every tick starts the
# line's verify (`verify`, detached, one at a time) whenever the trunk tip is above the pin; a green verify moves the pin to the tip, a
# red is traced to its commit and reverted, and `line-red` is raised (bin/jg-trunk.sh verify). A red never stops a landing; once the
# trunk has had no green commit for no-green-alarm-minutes (15) and no verify is running, `bin/jg-trunk.sh green-alarm`, run every
# minute, raises one alarm to Overwatch.
# The check never goes live on its own authority: that stays the captain's word
# (jg-trunk.sh live), EXCEPT for a project with a line in config/trunk-live-waiver (jg-trunk.sh waiver). For it every tick
# also starts `live` (a detached job, never blocking a landing), which runs `bin/jg-trunk.sh autolive` and reports a go-live,
# a failed move, a hold or a home still behind the last go-live after 10 minutes (bin/jg-trunk-live-lag.sh) in the outbox: the homes move once the trunk has been quiet for live-quiet-minutes (20) or the
# oldest landing not yet live is live-cap-minutes (60) old, whichever is first. Only the green pin goes live, so a red suite never does.
# A landed task resumes the lanes whose blocker says `waits-for: <task>`: one steer each, the blocker closed in the same send.
# A landed task is then cleaned up with bin/jg-teardown.sh, never forced: a refusal is reported and the worktree stays.
# bin/jg-delivery-tick.sh runs this check, from the watcher's fast tick and from the host sentinel's minute tick, so a worker's done
# starts the landing within seconds in a supervised home and within a minute when no model or watcher runs; the outcome
# line of a landing already cleaned up (its record is gone) comes from data/jg-trunk-landing/outbox.
# A sweep prints one line per outcome, once: `landed ... cleaned up`, or `not landed: <reason>`. A refusal that only needs time
# (away mode, a decision still open on linked work) is retried each sweep without repeating the line, and by the start a
# finished landing chains (`next`) after its backoff, so a steady queue of new lanes never starves it (core/trunk-landing/verdict.sh).
# Other refusals (a conflict, a second commit, a failing check) are final for the lane's head; core/trunk-landing/verdict.sh owns
# that rule for both paths, including that a conflict holds only while the trunk tip it was judged on stands and that a refusal caused by the environment (a hook the lander may not replace) is asked of the lander again after ten minutes. Per-attempt logs are
# retained. A lane fixes the refusal and reports a new head. bin/jg-trunk.sh owns every refusal and names the conflicting paths.
# A refusal the worker fixes (an incomplete proof, a final refusal) also reaches that lane's worker by itself and never sits silent:
# core/trunk-landing/refusal-reach.sh steers the worker with the refusal text, repeats the steer while the head is unchanged, and
# raises one alert when nobody acted within ten minutes.
set -u
case "${1:-}" in
  check|next) [ "$#" -eq 2 ] || { echo "usage: trunk-landing.sh check|next <jg-home>" >&2; exit 2; } ;;
  runbatch) [ "$#" -ge 4 ] || { echo "usage: trunk-landing.sh runbatch <jg-home> <task-id>@<head> <task-id>@<head>..." >&2; exit 2; } ;;
  run) [ "$#" -eq 4 ] || { echo "usage: trunk-landing.sh run <jg-home> <task-id> <head>" >&2; exit 2; } ;;
  verify) [ "$#" -eq 3 ] || { echo "usage: trunk-landing.sh verify <jg-home> <project>" >&2; exit 2; } ;;
  nightly) [ "$#" -eq 3 ] || { echo "usage: trunk-landing.sh nightly <jg-home> <project>" >&2; exit 2; } ;;
  publish) [ "$#" -eq 3 ] || { echo "usage: trunk-landing.sh publish <jg-home> <project>" >&2; exit 2; } ;;
  live) [ "$#" -eq 3 ] || { echo "usage: trunk-landing.sh live <jg-home> <project>" >&2; exit 2; } ;;
  *) echo "usage: trunk-landing.sh check|next <jg-home> | runbatch <jg-home> <task-id>@<head>... | run <jg-home> <task-id> <head> | live <jg-home> <project> | verify <jg-home> <project> | nightly <jg-home> <project> | publish <jg-home> <project>" >&2; exit 2 ;;
esac
[ -d "$2/state" ] || { echo "trunk-landing: $2 has no state directory" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
STATE=$FMH/state
DATA_DIR=$FMH/data
MEM=$FMH/data/jg-trunk-landing
export JG_HOME=$FMH JG_STATE_OVERRIDE=$FMH/state JG_CONFIG_OVERRIDE=$FMH/config
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")
umask 077
mkdir -p "$MEM" || exit 0
# shellcheck source=bin/jg-wake-lib.sh
. "$FMH/bin/jg-wake-lib.sh"
# shellcheck source=core/trunk-landing/refusal-reach.sh
. "$(dirname "${BASH_SOURCE[0]}")/refusal-reach.sh"
# shellcheck source=core/trunk-landing/queue-why.sh
. "$(dirname "${BASH_SOURCE[0]}")/queue-why.sh"
# shellcheck source=core/trunk-landing/window.sh
. "$(dirname "${BASH_SOURCE[0]}")/window.sh"
# A detached job (run, runbatch, live: each started with setsid) outlives whoever started it. Under a test
# (JG_TEST_SEAM=1) it names itself in the suite's registry, so the suite's cleanup stops its process group even after
# the fixture home is gone (tests/lib.sh jg_test_reap_detached).
case $1 in
  run|runbatch|live|publish|verify|nightly)
    if [ "${JG_TEST_SEAM:-}" = 1 ] && [ -n "${JG_TEST_DETACHED_REGISTRY:-}" ]; then
      printf '%s %s\n' "$$" "$(jg_pid_identity "$$" 2>/dev/null)" >> "$JG_TEST_DETACHED_REGISTRY" 2>/dev/null || :
    fi
    ;;
esac
# shellcheck source=core/trunk-landing/verdict.sh
. "$(dirname "${BASH_SOURCE[0]}")/verdict.sh"
mval() { sed -n "s/^$2=//p" "$1" | tail -n 1; }
# One five-minute deadline belongs to the whole landing attempt, lint and tests together (a test seam shortens it).
landing_deadline() {
  local seconds=300
  if [ "${JG_TEST_SEAM:-}" = 1 ] && [[ ${JG_TRUNK_TEST_GATE_SECONDS:-} =~ ^[1-9][0-9]*$ ]]; then seconds=$JG_TRUNK_TEST_GATE_SECONDS; fi
  printf '%s\n' "$(( $(date +%s) + seconds ))"
}

# A landed ticket resumes the lanes that wait for it, at once and with no owner turn: each gets one steer and its
# `waits-for: <ticket>` blocker is resolved in the same send (core/wait-timers/bin/jg-wait-actions-lib.sh owns the rule).
# A failure goes to data/jg-trunk-landing/resume.log and leaves the blocker open, which the ladder's waits-for row takes.
resume_waiters() {  # <landed task id>
  local lib=${BASH_SOURCE[0]%/*}/../wait-timers/bin/jg-wait-actions-lib.sh
  # shellcheck disable=SC2016 # the child shell expands its own positional parameters
  STATE=$FMH/state _JG_WAIT_TIMER_DIR=$FMH/bin bash -c '. "$1/bin/jg-classify-lib.sh" && . "$2" && jg_wait_waits_for_resume "$3"' \
    jg-resume "$FMH" "$lib" "$1" 2>>"$MEM/resume.log" || :
}

# The batched live step for one project (bin/jg-trunk.sh autolive decides; this reports what is worth a line: a go-live, a
# failed move, or a new hold). One at a time per project: a tick that finds the last one still running does nothing.
if [ "$1" = live ]; then
  pn=$3; proj=$FMH/projects/$pn; lrc=0; live=; lag=
  [[ $pn =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [ -d "$proj" ] || exit 2
  jg_lock_try_acquire "$STATE/.trunk-autolive-$pn.lock" || exit 0
  trap 'jg_lock_release "$STATE/.trunk-autolive-$pn.lock"' EXIT
  # A home that stays behind the last go-live for over 10 minutes is reported once per set of homes (the line holds no age).
  lag=$(JG_HOME="$FMH" "$FMH/bin/jg-trunk-live-lag.sh" "$proj" 2>/dev/null | tail -n 1) || :
  if [ -z "$lag" ]; then rm -f "$MEM/.live-lag-$pn"
  elif [ "$(cat "$MEM/.live-lag-$pn" 2>/dev/null)" != "$lag" ]; then
    printf '%s\n' "$lag" > "$MEM/.live-lag-$pn"
    jg_lock_acquire_wait "$MEM/.outbox.lock"; printf 'trunk-landing: %s: %s\n' "$pn" "$lag" >> "$MEM/outbox"; jg_lock_release "$MEM/.outbox.lock"
  fi
  live=$(JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" autolive "$proj" 2>&1) || lrc=$?
  live=$(printf '%s\n' "$live" | tail -n 1 | cut -c1-300); live=${live#autolive: }
  case $live in
    '') live="NOT live: the live step printed nothing (exit $lrc)" ;;
    waiting:*|"already live"*|"not live: it needs"*) exit 0 ;;
    live\ at*) ;;
    *) live="NOT live: $live" ;;
  esac
  jg_lock_acquire_wait "$MEM/.outbox.lock"
  printf 'trunk-landing: %s: %s\n' "$pn" "$live" >> "$MEM/outbox"
  jg_lock_release "$MEM/.outbox.lock"
  exit 0
fi

# The publish step for one project (bin/jg-trunk.sh publish decides; this reports a push or a refusal worth a line). One at a time
# per project: a tick that finds the last one still running does nothing.
if [ "$1" = publish ]; then
  pn=$3; proj=$FMH/projects/$pn; prc=0; pub=; out=
  [[ $pn =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [ -d "$proj" ] || exit 2
  jg_lock_try_acquire "$STATE/.trunk-publish-$pn.lock" || exit 0
  trap 'jg_lock_release "$STATE/.trunk-publish-$pn.lock"' EXIT
  out=$(JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" publish "$proj" 2>&1) || prc=$?
  if [ "$prc" -ne 0 ]; then pub="NOT published: $(printf '%s\n' "$out" | grep -v '^$' | tail -n 1 | cut -c1-300)"
  else pub=$(printf '%s\n' "$out" | grep -E '^released ' | tail -n 1 | cut -c1-300); [ -n "$pub" ] || exit 0; fi
  jg_lock_acquire_wait "$MEM/.outbox.lock"
  printf 'trunk-landing: %s: %s\n' "$pn" "$pub" >> "$MEM/outbox"
  jg_lock_release "$MEM/.outbox.lock"
  exit 0
fi

# The line's verify for one project (bin/jg-trunk.sh verify decides and reports; a red raises line-red there). One at a time per project:
# a tick that finds the last one still running does nothing. A run that is green or already reported prints nothing.
if [ "$1" = verify ]; then
  pn=$3; proj=$FMH/projects/$pn
  [[ $pn =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [ -d "$proj" ] || exit 2
  jg_lock_try_acquire "$STATE/.trunk-autoverify-$pn.lock" || exit 0
  trap 'jg_lock_release "$STATE/.trunk-autoverify-$pn.lock"' EXIT
  JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" verify-due "$proj" >/dev/null 2>&1 || exit 0
  JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" verify "$proj" >"$MEM/verify-$pn.log" 2>&1 || :
  exit 0
fi

# The nightly whole run for one project (bin/jg-trunk.sh nightly writes the day's report; nightly-due says whether it is time). One at a
# time per project, and it shares the verify's slot, so it never runs beside a verify.
if [ "$1" = nightly ]; then
  pn=$3; proj=$FMH/projects/$pn
  [[ $pn =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [ -d "$proj" ] || exit 2
  jg_lock_try_acquire "$STATE/.trunk-autonightly-$pn.lock" || exit 0
  trap 'jg_lock_release "$STATE/.trunk-autonightly-$pn.lock"' EXIT
  JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" nightly-due "$proj" >/dev/null 2>&1 || exit 0
  JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" nightly "$proj" >"$MEM/nightly-$pn.log" 2>&1 || :
  exit 0
fi

# A stack of lanes: one `land-batch` run, then each lane's outcome is read from its own line, the same as a single landing's.
if [ "$1" = runbatch ]; then
  shift 2; arg=; locked=; out=; rc=0
  for arg in "$@"; do [[ ${arg%%@*} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && ${arg#*@} =~ ^[0-9a-f]{40,64}$ ]] || exit 2; done
  trap 'for arg in $locked; do jg_lock_release "$STATE/.trunk-run-${arg%%@*}-${arg#*@}.lock"; done' EXIT
  for arg in "$@"; do
    jg_lock_try_acquire "$STATE/.trunk-run-${arg%%@*}-${arg#*@}.lock" || { for cleanup_arg in "$@"; do rm -f -- "$MEM/${cleanup_arg%%@*}.${cleanup_arg#*@}.state"; done; exit 0; }
    locked="$locked $arg"
  done
  for arg in "$@"; do printf 'running %s %s\n' "$(date +%s)" "$$" > "$MEM/${arg%%@*}.${arg#*@}.state"; done
  pn=$(basename "$(mval "$STATE/${1%%@*}.meta" project)")
  out=$(JG_TRUNK_GATE_DEADLINE="$(landing_deadline)" JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" land-batch "$@" 2>&1) || rc=$?
  tip=$(verdict_tip "$pn")  # a lane the stack returned was judged on top of the stack's lanes that landed
  for arg in "$@"; do
    id=${arg%%@*}; head=${arg#*@}; proj=$(mval "$STATE/$id.meta" project); lane_mode=$(mval "$STATE/$id.meta" mode)
    request_log=$(mktemp "$MEM/$id.$head.request-XXXXXX.log") || exit 1
    printf '%s\n' "$out" > "$request_log"; printf '%s\n' "$out" > "$MEM/$id.$head.log"
    if printf '%s\n' "$out" | grep -q "^landed $id " || printf '%s\n' "$out" | grep -q "^already landed $id "; then
      br=$(mval "$STATE/$id.meta" branch); br=${br:-fm/$id}
      now=$(git -C "$proj" rev-parse --verify --quiet "refs/heads/$br^{commit}" 2>/dev/null) || now=
      res=$(JG_HOME="$FMH" "$FMH/bin/jg-teardown.sh" "$id" 2>&1) && res='cleaned up' || res="cleanup refused, nothing was forced: $(printf '%s' "$res" | tail -n 1 | cut -c1-200)"
      printf 'landed %s\n' "$res" > "$MEM/$id.$head.state"; rm -f -- "$STATE/$id.land-next"
      window_move "$pn" landed >/dev/null || :
      [ -z "$now" ] || [ "$now" = "$head" ] || printf 'landed %s\n' "$res" > "$MEM/$id.$now.state"
      resume_waiters "$id"
      jg_lock_acquire_wait "$MEM/.outbox.lock"
      printf 'trunk-landing: landed %s (%s) on the local trunk in one stack with its queue (not live yet: live follows the answer given at gated, the captain'"'"'s word or the project'"'"'s waiver, and its quiet window); %s\n' "$id" "$lane_mode" "$res" >> "$MEM/outbox"
      jg_lock_release "$MEM/.outbox.lock"
      continue
    fi
    why=$(printf '%s\n' "$out" | grep -E "^returned $id: " | tail -n 1 | sed "s/^returned $id: //")
    [ -n "$why" ] || why=$(printf '%s\n' "$out" | grep -E '^(REFUSED|error|IN_PROGRESS):' | tail -n 1)
    why=$(printf '%s' "${why:-landing failed; see $request_log}" | cut -c1-300)
    if printf '%s\n' "$out" | grep -q "^refusal-class $id: env-wait$"; then
      printf 'env-wait %s\n' "$why" > "$MEM/$id.$head.state"
    else
      verdict_record "$id" "$head" "" "$tip" "$out" "$why"
      line=$(cat "$MEM/$id.$head.state")
      if [[ $line == final* ]]; then
        br=$(mval "$STATE/$id.meta" branch); br=${br:-fm/$id}
        lane_refusal_reach "$id" "$head" "$proj" "$br" "$(verdict_reason "${line#final }")" final
      fi
    fi
  done
  ! window_is_red "$out" || window_move "$pn" red >/dev/null || :
  "$SELF" next "$FMH" >/dev/null 2>&1 || :
  exit 0
fi

if [ "$1" = run ]; then
  id=$3; head=$4; out=; rc=0; why=; res=; now=
  [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $head =~ ^[0-9a-f]{40,64}$ ]] || exit 2
  run_lock=$STATE/.trunk-run-$id-$head.lock
  jg_lock_try_acquire "$run_lock" || exit 0
  trap 'jg_lock_release "$run_lock"' EXIT
  # A run started from a check that read the lane before an earlier run landed it (the lane's head moved by the rebase, so the lock of the
  # old head does not hold it back) finds the lane cleaned up: landing it again would only write a refusal for a lane with no record.
  [ -f "$STATE/$id.meta" ] || exit 0
  printf 'running %s %s\n' "$(date +%s)" "$$" > "$MEM/$id.$head.state"
  tip=$(verdict_tip "$(basename "$(mval "$STATE/$id.meta" project)")")
  out=$(JG_TRUNK_GATE_DEADLINE="$(landing_deadline)" JG_HOME="$FMH" JG_TRUNK_RUN_HELD_BY="$$" JG_TRUNK_EXPECT_HEAD="$head" "$FMH/bin/jg-trunk.sh" land "$id" 2>&1) || rc=$?
  request_log=$(mktemp "$MEM/$id.$head.request-XXXXXX.log") || exit 1
  printf '%s\n' "$out" > "$request_log"
  printf '%s\n' "$out" > "$MEM/$id.$head.log"
  if [ "$rc" -eq 0 ]; then
    JG_HOME="$FMH" "$FMH/bin/jg-machine-shadow.sh" landing "$id.$head" landed || true  # shadow report of the move (jg-machine-shadow.sh)
    proj=$(mval "$STATE/$id.meta" project); lane_mode=$(mval "$STATE/$id.meta" mode)
    # The lander rebased the lane, so its branch is now at the landed commit: the same verdict stands for that head.
    br=$(mval "$STATE/$id.meta" branch); br=${br:-fm/$id}
    now=$(git -C "$proj" rev-parse --verify --quiet "refs/heads/$br^{commit}" 2>/dev/null) || now=
    out=$(JG_HOME="$FMH" "$FMH/bin/jg-teardown.sh" "$id" 2>&1) && out='cleaned up' || out="cleanup refused, nothing was forced: $(printf '%s' "$out" | tail -n 1 | cut -c1-200)"
    printf 'landed %s\n' "$out" > "$MEM/$id.$head.state"; rm -f -- "$STATE/$id.land-next"
    window_move "$(basename "$proj")" landed >/dev/null || :
    [ -z "$now" ] || [ "$now" = "$head" ] || printf 'landed %s\n' "$out" > "$MEM/$id.$now.state"
    resume_waiters "$id"
    jg_lock_acquire_wait "$MEM/.outbox.lock"
    printf 'trunk-landing: landed %s (%s) on the local trunk (not live yet: live follows the answer given at gated, the captain'"'"'s word or the project'"'"'s waiver, and its quiet window); %s\n' "$id" "$lane_mode" "$out" >> "$MEM/outbox"
    jg_lock_release "$MEM/.outbox.lock"
    "$SELF" next "$FMH" >/dev/null 2>&1 || :
    exit 0
  fi
  why=$(printf '%s\n' "$out" | grep -E '^(REFUSED|error|IN_PROGRESS):' | tail -n 1 | cut -c1-300)
  # The lander rebased the lane, so its branch may now be at another head: the same verdict stands for that head.
  br=$(mval "$STATE/$id.meta" branch); br=${br:-fm/$id}
  now=$(git -C "$(mval "$STATE/$id.meta" project)" rev-parse --verify --quiet "refs/heads/$br^{commit}" 2>/dev/null) || now=
  if printf '%s\n' "$out" | grep -q "^refusal-class $id: env-wait$"; then
    printf 'env-wait %s\n' "${why:-environment unavailable; see $request_log}" > "$MEM/$id.$head.state"
  else
    verdict_record "$id" "$head" "$now" "$tip" "$out" "${why:-landing failed; see $request_log}"
    line=$(cat "$MEM/$id.$head.state")
    if [[ $line == final* ]]; then
      proj=$(mval "$STATE/$id.meta" project)
      lane_refusal_reach "$id" "${now:-$head}" "$proj" "$br" "$(verdict_reason "${line#final }")" final
    fi
  fi
  ! window_is_red "$out" || window_move "$(basename "$(mval "$STATE/$id.meta" project)")" red >/dev/null || :
  [ "$rc" -ne 75 ] || exit 0  # another run holds this landing; its own end starts the next one
  "$SELF" next "$FMH" >/dev/null 2>&1 || :
  exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0
export JG_HOME=$FMH JG_CONFIG_OVERRIDE=$FMH/config
# shellcheck source=bin/jg-trunk-policy-lib.sh disable=SC1091
. "$FMH/bin/jg-trunk-policy-lib.sh"
QUIET=; [ "$1" != next ] || QUIET=1
# A policy number, or its default when the home's value is not a whole number.
polnum() { local v; v=$(jg_trunk_policy "$1" "$2"); case $v in ''|*[!0-9]*) v=$3 ;; esac; printf '%s\n' "$v"; }
if [ -z "$QUIET" ] && jg_lock_try_acquire "$MEM/.outbox.lock"; then
  if [ -s "$MEM/outbox" ]; then mv -f -- "$MEM/outbox" "$MEM/outbox.$$" && cat "$MEM/outbox.$$" && rm -f -- "$MEM/outbox.$$"; fi
  jg_lock_release "$MEM/.outbox.lock"
fi
# The landing's temporary output (request and launch logs) and the leftovers of a task with no record are removed
# (core/tmp-reaper/records.sh landing, at most every 10 minutes and silent).
[ -n "$QUIET" ] || [ ! -x "${SELF%/*}/../tmp-reaper/records.sh" ] || "${SELF%/*}/../tmp-reaper/records.sh" landing "$FMH" >/dev/null 2>&1 || :
# Only a project registered local-trunk is ever touched; no-mistakes, direct-PR and local-only projects keep their own rules.
# shellcheck source=bin/jg-delivery-style.sh disable=SC1091
. "$FMH/bin/jg-delivery-style.sh"
local_trunk() { jg_delivery_style_is "$(JG_HOME="$FMH" "$FMH/bin/jg-project-mode.sh" --raw "$(basename "$1")" 2>/dev/null | cut -d' ' -f1)" trunk && echo yes || echo no; }
# Initialize only registered projects without a recorded trunk; init itself refuses an existing branch.
for proj in "$FMH"/projects/*; do
  [ -d "$proj" ] && [ "$(local_trunk "$proj")" = yes ] || continue
  pn=$(basename "$proj"); [ ! -e "$STATE/trunk-tip-$pn" ] || continue
  # An unborn repository has nothing to initialize; invalid repositories still reach init and report their error.
  if git -C "$proj" rev-parse --git-dir >/dev/null 2>&1 && commits=$(git -C "$proj" rev-list --all --max-count=1 2>/dev/null) && [ -z "$commits" ]; then continue; fi
  jg_lock_try_acquire "$STATE/.trunk-init-$pn.lock" || continue
  if [ ! -e "$STATE/trunk-tip-$pn" ]; then
    init_out=$(JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" init "$proj" 2>&1) || { [ -n "$QUIET" ] || printf 'trunk-landing: %s\n' "$init_out"; }
  fi
  jg_lock_release "$STATE/.trunk-init-$pn.lock"
done
# Once a project's release PR has merged, cut its next trunk version (bin/jg-trunk.sh rollover) and clean the old trunk
# up unforced (retire); looked at every 5 minutes.
for tip in "$STATE"/trunk-tip-*; do
  [ -z "$QUIET" ] || break
  [ -f "$tip" ] || continue
  pn=${tip##*/trunk-tip-}; proj=$FMH/projects/$pn
  [ -d "$proj" ] && [ -s "$DATA_DIR/trunk-releases.tsv" ] && [ "$(local_trunk "$proj")" = yes ] || continue
  [ ! -e "$MEM/.rollover-$pn" ] || [ -n "$(find "$MEM/.rollover-$pn" -mmin +4 2>/dev/null)" ] || continue
  : > "$MEM/.rollover-$pn"
  JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" rollover "$proj" 2>/dev/null | sed 's/^/trunk-landing: /'
  # An old trunk kept for unlanded work is looked at again; a changed listing is reported, an unchanged one is not.
  out=$(JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" retire "$proj" 2>/dev/null | sed 's/^/trunk-landing: /')
  if [ "$out" != "$(cat "$MEM/.retire-$pn" 2>/dev/null)" ]; then printf '%s\n' "$out" > "$MEM/.retire-$pn"; [ -z "$out" ] || printf '%s\n' "$out"; fi
done
# A trunk with no green commit for no-green-alarm-minutes raises one alarm to Overwatch (bin/jg-trunk.sh green-alarm owns the rule and
# raises it once per green pin); looked at every minute.
for tip in "$STATE"/trunk-tip-*; do
  [ -z "$QUIET" ] || break
  [ -f "$tip" ] || continue
  pn=${tip##*/trunk-tip-}; proj=$FMH/projects/$pn
  [ -d "$proj" ] && [ "$(local_trunk "$proj")" = yes ] || continue
  [ ! -e "$MEM/.green-alarm-$pn" ] || [ -n "$(find "$MEM/.green-alarm-$pn" -mmin +0 2>/dev/null)" ] || continue
  : > "$MEM/.green-alarm-$pn"
  JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" reconcile "$proj" >/dev/null 2>&1 || :
  JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" green-alarm "$proj" >/dev/null 2>&1 || :
done
# Every tick starts the line's verify while a trunk's tip is above its green pin (detached, so it never holds a landing back; the job
# itself keeps one verify at a time and skips a tip a verify already ended red on). Nothing is printed: a red raises line-red.
for tip in "$STATE"/trunk-tip-*; do
  [ -z "$QUIET" ] || break
  [ -f "$tip" ] || continue
  pn=${tip##*/trunk-tip-}
  [ "$(cat "$tip" 2>/dev/null)" != "$(cat "$STATE/trunk-green-$pn" 2>/dev/null)" ] || continue
  [ -d "$FMH/projects/$pn" ] && [ "$(local_trunk "$FMH/projects/$pn")" = yes ] || continue
  setsid nohup "$SELF" verify "$FMH" "$pn" >/dev/null 2>&1 < /dev/null &
done
# Every tick offers the nightly whole run to each local-trunk project: only a project whose `nightly-due` says it is time gets a detached
# job (which asks again under its lock).
for tip in "$STATE"/trunk-tip-*; do
  [ -z "$QUIET" ] || break
  [ -f "$tip" ] || continue
  pn=${tip##*/trunk-tip-}
  [ -d "$FMH/projects/$pn" ] && [ "$(local_trunk "$FMH/projects/$pn")" = yes ] || continue
  # Ask first: a tick that is not due starts no process at all, so the nightly job costs every other tick nothing.
  JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" nightly-due "$FMH/projects/$pn" >/dev/null 2>&1 || continue
  setsid nohup "$SELF" nightly "$FMH" "$pn" >/dev/null 2>&1 < /dev/null &
done
# Under a go-live waiver every tick starts the batched live step (detached, so it never holds a landing back).
for tip in "$STATE"/trunk-tip-*; do
  [ -z "$QUIET" ] || break
  [ -f "$tip" ] || continue
  pn=${tip##*/trunk-tip-}
  awk -v p="$pn" '$1 == p { f = 1 } END { exit !f }' "$FMH/config/trunk-live-waiver" 2>/dev/null || jg_trunk_gated_any "$FMH/data/trunk-gated.tsv" "$pn" || continue
  [ -d "$FMH/projects/$pn" ] && [ "$(local_trunk "$FMH/projects/$pn")" = yes ] || continue
  setsid nohup "$SELF" live "$FMH" "$pn" >/dev/null 2>&1 < /dev/null &
done
# Under a release waiver every tick starts the publish step (detached, so it never holds a landing back; at most once a minute).
for tip in "$STATE"/trunk-tip-*; do
  [ -z "$QUIET" ] || break
  [ -f "$tip" ] || continue
  pn=${tip##*/trunk-tip-}
  awk -v p="$pn" '$1 == p { f = 1 } END { exit !f }' "$FMH/config/trunk-release-waiver" 2>/dev/null || jg_trunk_gated_any "$FMH/data/trunk-gated.tsv" "$pn" || continue
  [ -d "$FMH/projects/$pn" ] && [ "$(local_trunk "$FMH/projects/$pn")" = yes ] || continue
  [ ! -e "$MEM/.publish-$pn" ] || [ -n "$(find "$MEM/.publish-$pn" -mmin +0 2>/dev/null)" ] || continue
  : > "$MEM/.publish-$pn"
  setsid nohup "$SELF" publish "$FMH" "$pn" >/dev/null 2>&1 < /dev/null &
done
report() {
  local reason=${3%%; full log:*}
  [ -z "$QUIET" ] || return 0
  [ "$(cat "$MEM/$1.reported" 2>/dev/null)" = "$reason" ] || { echo "trunk-landing: $2"; printf '%s\n' "$reason" > "$MEM/$1.reported"; }
}
# Whether a `running <epoch> [<pid>]` state line is a live landing: its owner is alive, or it was just started and has not
# published its owner yet.
run_alive() {
  local _w ep pid
  read -r _w ep pid <<<"$1"
  if [ -n "${pid:-}" ]; then jg_pid_alive "$pid"; else [ $(( $(date +%s) - ${ep:-0} )) -lt 120 ]; fi
}
# The landings in progress: a lane's own `<task>.<head>.state` counts; the lander's admission records
# (`<task>.<head>.<context>.state`) are not landings. Prints how many are running.
running_count() {
  local f l n=0
  for f in "$MEM"/*.state; do
    [ -f "$f" ] || continue
    ! printf '%s' "${f##*/}" | grep -Eq '\.[0-9a-f]{40,64}\.[0-9a-f]{40,64}\.state$' || continue
    l=$(cat "$f" 2>/dev/null || true)
    case $l in running*) run_alive "$l" && n=$((n + 1)) ;; esac
  done
  printf '%s\n' "$n"
}
# The chain of gates: while single landings of one project gate in its chain (they hold its front positions, bin/jg-trunk.sh) and the
# highest live position is under the window W (core/trunk-landing/window.sh), the next lane of that project may start; it is gated on top
# of the commit one position below. Prints the project when that slot is free and every landing running now is in that chain.
second_slot_project() {
  local lock pn top k pid
  for lock in "$STATE"/.trunk-front-*.lock; do
    [ -d "$lock" ] || continue
    pn=${lock##*/.trunk-front-}; pn=${pn%.lock}
    case $pn in *@*) continue ;; esac  # a deeper position of a chain is found through the front below
    top=0
    for k in $(seq 1 64); do
      lock="$STATE/.trunk-front-$pn"; [ "$k" -le 1 ] || lock="$lock@$k"
      pid=$(cat "$lock.lock/pid" 2>/dev/null || true)
      [ -n "$pid" ] && jg_pid_alive "$pid" && top=$k
    done
    [ "$top" -ge 1 ] && [ "$top" -eq "$running" ] || continue
    [ "$top" -lt "$(window_size "$pn")" ] || continue  # the window, not the policy alone, says how many gates may run
    printf '%s\n' "$pn"; return 0
  done
  return 1
}
# Every ready lane waits because every gate slot is in use: record that at this decision (core/trunk-landing/queue-why.sh).
slots_full() { local at id head; while read -r at id head _; do [ -z "$id" ] || queue_why_wait "$MEM" "$id" "$head" 'slot full'; done <<< "$cands"; }
# The cause a late start names when nothing was ahead of the lane: the project's verify holds its slot, or the host load is at its cpu count.
start_cause() {
  local pn=$1 m="$STATE/.trunk-verify-$1.lock" load cpus
  if [ -e "$m" ] && ! { jg_lock_try_acquire "$m" && jg_lock_release "$m"; }; then echo 'verify running'; return; fi
  read -r load _ < /proc/loadavg 2>/dev/null || return 0; cpus=$(nproc 2>/dev/null || echo 1)
  awk -v l="${load:-0}" -v c="$cpus" 'BEGIN { exit !(l >= c) }' && echo 'host load' || :
}
# The worker's own ready report: the last line of its status file is `done [at=<epoch>]: ...`. Prints the epoch of that report.
ready_at() {
  local line; line=$(tail -n 1 "$STATE/$1.status" 2>/dev/null || true)
  case $line in done\ *|done:*) printf '%s\n' "$(printf '%s' "$line" | sed -n 's/^done[^[]*\[at=\([0-9]*\)\].*/\1/p')" | grep . || echo 0 ;; *) return 1 ;; esac
}
cands=
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  # Compatibility is read-only and applies only to registered local-trunk projects below.
  jg_delivery_style_is "$(mval "$meta" mode)" local || continue
  proj=$(mval "$meta" project); [ -d "$proj" ] || continue
  [ -e "$STATE/trunk-tip-$(basename "$proj")" ] || continue
  [ "$(local_trunk "$proj")" = yes ] || continue
  branch=$(mval "$meta" branch); branch=${branch:-fm/$id}
  head=$(git -C "$proj" rev-parse --verify --quiet "refs/heads/$branch^{commit}") || continue
  # Old heads cannot be admitted again; retain their final records outside the active set.
  for stale in "$MEM/$id".*.state; do
    [ -f "$stale" ] || continue
    rest=${stale#"$MEM/$id."}; oldhead=${rest%%.*}
    [[ $oldhead =~ ^[0-9a-f]{40,64}$ ]] || continue
    [ "$oldhead" != "$head" ] || continue
    case $(cat "$stale" 2>/dev/null) in final*) mkdir -p "$MEM/retired" && mv -n -- "$stale" "$MEM/retired/" ;; esac
  done
  st=$MEM/$id.$head.state; line=$(cat "$st" 2>/dev/null || true)
  case $line in
    landed*) continue ;;
    final*) if ! verdict_holds "$id" "$head" "$line" "$(basename "$proj")"; then
      mkdir -p "$MEM/retired" && mv -n -- "$st" "$MEM/retired/"
      line=
    fi ;;
  esac
  at=$(ready_at "$id") || continue
  # The merge switch of the style `local` (docs/trunk-flow.md): a lane of mode `local` lands by itself with yolo on, or once the lead
  # recorded merge=approved; with yolo off it waits for that word. A record with an old word is read as before.
  if [ "$(mval "$meta" mode)" = local ] && [ "$(mval "$meta" yolo)" != on ] && [ "$(mval "$meta" merge)" != approved ]; then
    report "$id.$head" "$id waits for the captain's word to land (yolo is off)" "waits for the captain's word: yolo is off and merge=approved is not recorded"
    continue
  fi
  # A landing starts only on a head whose whole proof is there: receipt, approved merge-card evidence and a sealed done-done run.
  if gaps=$(JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" proof "$id" 2>&1); then :; else
    [ -z "$QUIET" ] || continue
    gaps=$(printf '%s' "$gaps" | tr '\n' ';')
    report "$id.$head" "$id waits to land: its proof is incomplete: ${gaps:0:300}" "proof inputs are incomplete: ${gaps:0:300}"
    lane_refusal_reach "$id" "$head" "$proj" "$branch" "proof inputs are incomplete: $gaps"
    continue
  fi
  case $line in
    running*) run_alive "$line" && continue ;;
    final*)  # a verdict that no longer holds (a conflict judged on a tip that is gone) is judged again, with no report and no steer
      if verdict_holds "$id" "$head" "$line" "$(basename "$proj")"; then
        why=$(verdict_reason "${line#final }")
        report "$id.$head" "$id not landed: ${line#final }" "$why"; lane_refusal_reach "$id" "$head" "$proj" "$branch" "$why" final; continue
      fi
      mkdir -p "$MEM/retired" && mv -n -- "$st" "$MEM/retired/" ;;
    env-wait*) verdict_due "$st" || continue ;;
    retry*) verdict_due "$st" || continue ;;
    wait*) [ -z "$QUIET" ] || verdict_due "$st" || continue; report "$id.$head" "$id waits to land: ${line#wait }" "${line#wait }" ;;
  esac
  [ -n "$QUIET" ] || queue_seen "$MEM" "$id" "$head"
  # <epoch done> <task> <head> <project> <1, or 0 for a lane marked `land-next`> <1, or 0 for a lane once returned for a conflict>
  cands="$cands$at $id $head $(basename "$proj") $([ -e "$STATE/$id.land-next" ] && echo 0 || echo 1) $( { verdict_returned "$id" || grep -Eq "^final.*$VERDICT_CONFLICT_RE" "$MEM/retired/$id".*.state 2>/dev/null; } && echo 0 || echo 1)"$'\n'
done
# A flush request (`jg-trunk.sh flush`) ends once its project has no ready lane left.
for f in "$STATE"/trunk-flush-*; do
  [ -f "$f" ] || continue
  printf '%s' "$cands" | awk -v p="${f##*/trunk-flush-}" '$4 == p { f = 1 } END { exit !f }' || rm -f -- "$f"
done
# Oldest done first, a lane once returned for a conflict ahead of the rest. A landing already running holds the rest back; its end starts the next one (`next`).
[ -n "$cands" ] || exit 0
if ! mkdir "$MEM/.start" 2>/dev/null; then
  [ -n "$(find "$MEM/.start" -mmin +1 2>/dev/null)" ] || exit 0
  rmdir "$MEM/.start" 2>/dev/null; mkdir "$MEM/.start" 2>/dev/null || exit 0
fi
# Lanes land one at a time, except that more may gate on top of the one ahead (second_slot_project): at most W gates at once.
only_pn=; running=$(running_count)
if [ "$running" -ge 1 ]; then only_pn=$(second_slot_project) || { slots_full; rmdir "$MEM/.start" 2>/dev/null; exit 0; }; fi
if [ "$running" -lt 1 ] || [ -n "$only_pn" ]; then
  # The flush rule (bin/jg-trunk-policy-lib.sh): a project's ready lanes wait until flush-at-ready of them are ready, or the oldest has
  # waited flush-after-minutes, or `jg-trunk.sh flush` was run; then they all land (up to batch-max, oldest done first; the rest follow
  # at once). A lane marked `land-next` goes first and lands at once, with or without the others. One project per stack.
  now=$(date +%s); ready=(); id=; head=
  while read -r pn; do
    [ -n "$pn" ] || continue
    [ -z "$only_pn" ] || [ "$pn" = "$only_pn" ] || continue
    list=$(printf '%s' "$cands" | awk -v p="$pn" '$4 == p' | sort -k5,5n -k6,6n -k1,1n -k2,2)
    oldest=$(printf '%s\n' "$list" | sort -n -k1,1 | head -n 1 | cut -d' ' -f1)
    at_ready=$(polnum flush-at-ready "$pn" 3); after=$(polnum flush-after-minutes "$pn" 20)
    if [ -e "$STATE/trunk-flush-$pn" ] || [ "$(printf '%s\n' "$list" | grep -c .)" -ge "$at_ready" ] || [ $(( now - ${oldest:-0} )) -ge $(( after * 60 )) ]; then :; else
      list=$(printf '%s\n' "$list" | awk '$5 == 0')
    fi
    [ -n "$list" ] || continue
    take=$(jg_trunk_policy batch-max "$pn"); [ -z "$only_pn" ] || take=1  # the second slot is one lane, never a stack
    batch=$(printf '%s\n' "$list" | head -n "$take" | awk '{ printf "%s%s@%s", (NR > 1 ? " " : ""), $2, $3 }')
    read -r -a ready <<< "$batch"; break
  done < <(printf '%s' "$cands" | sort -n -k1,1 | awk '!seen[$4]++ { print $4 }')
  [ "${#ready[@]}" -gt 0 ] || { rmdir "$MEM/.start" 2>/dev/null; exit 0; }
  # A batch has no per-lane admission key; recheck environment waits singly so an unchanged fact never reruns its gate.
  normal=(); env_first=
  for arg in "${ready[@]}"; do
    case $(cat "$MEM/${arg%%@*}.${arg#*@}.state" 2>/dev/null) in
      env-wait*) [ -n "$env_first" ] || env_first=$arg ;;
      *) normal+=("$arg") ;;
    esac
  done
  if [ "${#normal[@]}" -gt 0 ]; then ready=("${normal[@]}"); else ready=("$env_first"); fi
  # Name why each lane did not start at its done line (core/trunk-landing/queue-why.sh); core/trunk-latency reads it.
  stack=(); for arg in "${ready[@]}"; do stack+=("${arg%%@*}"); done
  for arg in "${ready[@]}"; do
    QUEUE_WHY_CAUSE=$(start_cause "$(printf '%s' "$cands" | awk -v t="${arg%%@*}" '$2 == t { print $4; exit }')") \
    queue_why_record "$MEM" "${arg%%@*}" "${arg#*@}" "$(printf '%s' "$cands" | awk -v t="${arg%%@*}" '$2 == t { print $1; exit }')" "$now" "${stack[@]}"
  done
  if [ "${#ready[@]}" -ge 2 ]; then
    for arg in "${ready[@]}"; do printf 'running %s\n' "$(date +%s)" > "$MEM/${arg%%@*}.${arg#*@}.state"; done
    launch_log=$(mktemp "$MEM/batch.launch-XXXXXX.log") || exit 1
    setsid nohup "$SELF" runbatch "$FMH" "${ready[@]}" >"$launch_log" 2>&1 < /dev/null &
    id=${ready[0]%%@*}; head=${ready[0]#*@}
  else
  id=${ready[0]%%@*}; head=${ready[0]#*@}
  # The pick above read the state some time ago: a run that landed this head since has written `landed`, and a running mark written over
  # it would make the lane look unlanded for good. Read it once more right before the write.
  case $(cat "$MEM/$id.$head.state" 2>/dev/null) in landed*) rmdir "$MEM/.start" 2>/dev/null; exit 0 ;; esac
  printf 'running %s\n' "$(date +%s)" > "$MEM/$id.$head.state"
  launch_log=$(mktemp "$MEM/$id.$head.launch-XXXXXX.log") || exit 1
  setsid nohup "$SELF" run "$FMH" "$id" "$head" >"$launch_log" 2>&1 < /dev/null &
  fi
  launch_pid=$!
  # The outer watcher stops a completed check's process group. Do not return until the child has detached and
  # published ownership of this attempt.
  for _ in {1..100}; do
    line=$(cat "$MEM/$id.$head.state" 2>/dev/null || true)
    read -r phase _ owner_pid <<<"$line"
    [ "$phase" = running ] && [ -z "${owner_pid:-}" ] || break
    kill -0 "$launch_pid" 2>/dev/null || break
    sleep 0.01
  done
fi
rmdir "$MEM/.start" 2>/dev/null
exit 0

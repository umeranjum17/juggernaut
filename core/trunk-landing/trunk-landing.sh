#!/usr/bin/env bash
# trunk-landing watcher check: land a task into the local trunk by itself once its worker reports done.
# Usage: trunk-landing.sh check <jg-home>
#        trunk-landing.sh next <jg-home>                      (what a finished landing starts: the next ready lane, silently)
#        trunk-landing.sh run <jg-home> <task-id> <head>      (what `check` starts in the background)
#        trunk-landing.sh runbatch <jg-home> <task-id>@<head>...     (what `check` starts when 2 or more lanes are queued: one stack)
#        trunk-landing.sh post <jg-home> <task-id> <head> <commit>   (what a landing starts: the post-landing suite)
#        trunk-landing.sh live <jg-home> <project>                   (what a tick starts under a go-live waiver: the batched live step)
#
# For each state/<task>.meta in the home with mode=local-trunk (or legacy local-only) whose project is registered local-trunk and has a trunk
# (state/trunk-tip-<project>, made by bin/jg-trunk.sh init), whose ship branch is not on the trunk yet and whose
# state/<task>.status ends with a `done` line, `check` starts `bin/jg-trunk.sh land <task>` detached and records
# the outcome in <home>/data/jg-trunk-landing/<task>.<head>.state. The worker's done is the signal, and the lane's whole proof must be there at its head (completion
# receipt, approved merge-card evidence, sealed done-done run: `jg-trunk.sh proof`) before a landing starts; a lane without it is
# reported once and left, and lands on its own once the proof is complete. The owner signature is never waited for. The lander rebases the lane's
# commit onto the trunk tip by itself, so a moved trunk is never a refusal. Lanes land one at a time, oldest done first, and a
# finished landing starts the next at once (`next`), so three lanes ready together land in order with no human or lead step.
# When 2 or more lanes are ready, the check stacks up to batch-max (5) of them, oldest done first, into one `bin/jg-trunk.sh land-batch`:
# one gate over the stack, one trunk move, and only a lane that conflicts or causes a red is returned (reported once, like any refusal).
# A single ready lane keeps the path above. After a landing `bin/jg-trunk.sh verify` runs the whole suite at that commit apart from the next landing and reverts the
# commit by itself if it caused a red, then verifies the reverted tip so the green pin can follow it. A red never stops a landing; once the
# trunk has had no green commit for no-green-alarm-minutes (15), `bin/jg-trunk.sh green-alarm`, run every minute, raises one alarm to Overwatch.
# The check never goes live on its own authority: that stays the captain's word
# (jg-trunk.sh live), EXCEPT for a project with a line in config/trunk-live-waiver (jg-trunk.sh waiver). For it every tick
# also starts `live` (a detached job, never blocking a landing), which runs `bin/jg-trunk.sh autolive` and reports a go-live,
# a failed move, a hold or a home still behind the last go-live after 10 minutes (bin/jg-trunk-live-lag.sh) in the outbox: the homes move once the trunk has been quiet for live-quiet-minutes (20) or the
# oldest landing not yet live is live-cap-minutes (60) old, whichever is first. Only the green pin goes live, so a red suite never does.
# A landed task is then cleaned up with bin/jg-teardown.sh, never forced: a refusal is reported and the worktree stays.
# bin/jg-delivery-tick.sh runs this check, from the watcher's fast tick and from the host sentinel's minute tick, so a worker's done
# starts the landing within seconds in a supervised home and within a minute when no model or watcher runs; the outcome
# line of a landing already cleaned up (its record is gone) comes from data/jg-trunk-landing/outbox.
# A sweep prints one line per outcome, once: `landed ... cleaned up`, or `not landed: <reason>`. A refusal that only needs time
# (away mode, a decision still open on linked work) is retried each sweep without repeating the line, and by the start a
# finished landing chains (`next`) after its backoff, so a steady queue of new lanes never starves it (core/trunk-landing/verdict.sh).
# Other refusals (a conflict, a second commit, a failing check) are final for the lane's head; core/trunk-landing/verdict.sh owns
# that rule for both paths, including that a conflict holds only while the trunk tip it was judged on stands. Per-attempt logs are
# retained. A lane fixes the refusal and reports a new head. bin/jg-trunk.sh owns every refusal and names the conflicting paths.
# A refusal the worker fixes (an incomplete proof, a final refusal) also reaches that lane's worker by itself and never sits silent:
# core/trunk-landing/refusal-reach.sh steers the worker with the refusal text, repeats the steer while the head is unchanged, and
# raises one alert when nobody acted within ten minutes.
set -u
case "${1:-}" in
  check|next) [ "$#" -eq 2 ] || { echo "usage: trunk-landing.sh check|next <jg-home>" >&2; exit 2; } ;;
  runbatch) [ "$#" -ge 4 ] || { echo "usage: trunk-landing.sh runbatch <jg-home> <task-id>@<head> <task-id>@<head>..." >&2; exit 2; } ;;
  run) [ "$#" -eq 4 ] || { echo "usage: trunk-landing.sh run <jg-home> <task-id> <head>" >&2; exit 2; } ;;
  live) [ "$#" -eq 3 ] || { echo "usage: trunk-landing.sh live <jg-home> <project>" >&2; exit 2; } ;;
  post) [ "$#" -eq 5 ] || { echo "usage: trunk-landing.sh post <jg-home> <task-id> <head> <commit>" >&2; exit 2; } ;;
  *) echo "usage: trunk-landing.sh check|next <jg-home> | runbatch <jg-home> <task-id>@<head>... | run <jg-home> <task-id> <head> | post <jg-home> <task-id> <head> <commit> | live <jg-home> <project>" >&2; exit 2 ;;
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
# A detached job (run, runbatch, post, live: each started with setsid) outlives whoever started it. Under a test
# (JG_TEST_SEAM=1) it names itself in the suite's registry, so the suite's cleanup stops its process group even after
# the fixture home is gone (tests/lib.sh jg_test_reap_detached).
case $1 in
  run|runbatch|post|live)
    if [ "${JG_TEST_SEAM:-}" = 1 ] && [ -n "${JG_TEST_DETACHED_REGISTRY:-}" ]; then
      printf '%s %s\n' "$$" "$(jg_pid_identity "$$" 2>/dev/null)" >> "$JG_TEST_DETACHED_REGISTRY" 2>/dev/null || :
    fi
    ;;
esac
# shellcheck source=core/trunk-landing/verdict.sh
. "$(dirname "${BASH_SOURCE[0]}")/verdict.sh"
mval() { sed -n "s/^$2=//p" "$1" | tail -n 1; }
# The project a landed commit went into, from the landing's own row: teardown removes the lane's record (state/<id>.meta)
# right after the landing, so the jobs that follow a landing must never read the project from it.
landed_project() {  # <commit>
  local pn; pn=$(awk -F'\t' -v c="$1" '$3 == c { p = $2 } END { print p }' "$DATA_DIR/trunk-landings.tsv" 2>/dev/null)
  [[ $pn =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && printf '%s\n' "$FMH/projects/$pn"
}

# The post-landing job: the whole suite at the landed commit (bin/jg-trunk.sh verify). A commit it reverted leaves a tip no suite has
# judged, so that tip is verified at once and the green pin, and live, can follow it. A suite that did not pass is reported with the
# verify's own last line; the live step is not its business, so a landing never waits on a go-live.
if [ "$1" = post ]; then
  id=$3; head=$4; cand=$5; proj=; vrc=0; vlog=$MEM/$3.$4.verify.log
  [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $head =~ ^[0-9a-f]{40,64}$ && $cand =~ ^[0-9a-f]{40,64}$ ]] && proj=$(landed_project "$cand") && [ -d "$proj" ] || exit 2
  JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" verify "$proj" "$cand" >"$vlog" 2>&1 || vrc=$?
  [ "$vrc" -ne 0 ] || exit 0
  # A home removed while its suite ran has no outbox to report to; waiting on its lock would never end.
  [ -d "$MEM" ] || exit 0
  why=$(grep -E '^(reverted |verify: )' "$vlog" | tail -n 1 | cut -c1-300)
  jg_lock_acquire_wait "$MEM/.outbox.lock"
  printf 'trunk-landing: %s: the whole suite did not pass at %s: %s (%s)\n' "$id" "${cand:0:12}" "${why:-it is not live, and every home stays on the last green commit}" "$vlog" >> "$MEM/outbox"
  jg_lock_release "$MEM/.outbox.lock"
  if grep -q '^reverted ' "$vlog"; then
    printf '\n--- the reverted tip ---\n' >> "$vlog"
    JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" verify "$proj" >>"$vlog" 2>&1 || :
  fi
  exit 0
fi

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

# A stack of lanes: one `land-batch` run, then each lane's outcome is read from its own line, the same as a single landing's.
if [ "$1" = runbatch ]; then
  shift 2; arg=; locked=; out=; rc=0; ids=; fresh_top=
  for arg in "$@"; do [[ ${arg%%@*} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && ${arg#*@} =~ ^[0-9a-f]{40,64}$ ]] || exit 2; done
  trap 'for arg in $locked; do jg_lock_release "$STATE/.trunk-run-${arg%%@*}-${arg#*@}.lock"; done' EXIT
  for arg in "$@"; do
    jg_lock_try_acquire "$STATE/.trunk-run-${arg%%@*}-${arg#*@}.lock" || { for arg in "$@"; do rm -f -- "$MEM/${arg%%@*}.${arg#*@}.state"; done; exit 0; }
    locked="$locked $arg"
  done
  for arg in "$@"; do printf 'running %s %s\n' "$(date +%s)" "$$" > "$MEM/${arg%%@*}.${arg#*@}.state"; done
  pn=$(basename "$(mval "$STATE/${1%%@*}.meta" project)")
  out=$(JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" land-batch "$@" 2>&1) || rc=$?
  tip=$(verdict_tip "$pn")  # a lane the stack returned was judged on top of the stack's lanes that landed
  for arg in "$@"; do
    id=${arg%%@*}; head=${arg#*@}; proj=$(mval "$STATE/$id.meta" project)
    request_log=$(mktemp "$MEM/$id.$head.request-XXXXXX.log") || exit 1
    printf '%s\n' "$out" > "$request_log"; printf '%s\n' "$out" > "$MEM/$id.$head.log"
    if printf '%s\n' "$out" | grep -q "^landed $id " || printf '%s\n' "$out" | grep -q "^already landed $id "; then
      printf '%s\n' "$out" | grep -q "^landed $id " && { ids="$ids $id"; fresh_top=$id; }
      br=$(mval "$STATE/$id.meta" branch); br=${br:-fm/$id}
      now=$(git -C "$proj" rev-parse --verify --quiet "refs/heads/$br^{commit}" 2>/dev/null) || now=
      res=$(JG_HOME="$FMH" "$FMH/bin/jg-teardown.sh" "$id" 2>&1) && res='cleaned up' || res="cleanup refused, nothing was forced: $(printf '%s' "$res" | tail -n 1 | cut -c1-200)"
      printf 'landed %s\n' "$res" > "$MEM/$id.$head.state"; rm -f -- "$STATE/$id.land-next"
      [ -z "$now" ] || [ "$now" = "$head" ] || printf 'landed %s\n' "$res" > "$MEM/$id.$now.state"
      jg_lock_acquire_wait "$MEM/.outbox.lock"
      printf 'trunk-landing: landed %s (local-trunk) on the local trunk in one stack with its queue (not live yet: the whole suite runs on it first, then live follows the captain'"'"'s word or the project'"'"'s waiver and its quiet window); %s\n' "$id" "$res" >> "$MEM/outbox"
      jg_lock_release "$MEM/.outbox.lock"
      continue
    fi
    why=$(printf '%s\n' "$out" | grep -E "^returned $id: " | tail -n 1 | sed "s/^returned $id: //")
    [ -n "$why" ] || why=$(printf '%s\n' "$out" | grep -E '^(REFUSED|error|IN_PROGRESS):' | tail -n 1)
    why=$(printf '%s' "${why:-landing failed; see $request_log}" | cut -c1-300)
    verdict_record "$id" "$head" "" "$tip" "$out" "$why"
  done
  # The whole suite runs once, at the top of the stack, and reverts the lane that caused a red by itself.
  if [ -n "$fresh_top" ]; then
    cand=$(awk -F'\t' -v i="$fresh_top" '$1 == i { c = $3 } END { print c }' "$DATA_DIR/trunk-landings.tsv" 2>/dev/null)
    proj=$(landed_project "$cand" || :)
    for arg in "$@"; do [ "${arg%%@*}" != "$fresh_top" ] || head=${arg#*@}; done
    if [ -n "$cand" ] && [ -d "$proj" ]; then
      setsid nohup "$SELF" post "$FMH" "$fresh_top" "$head" "$cand" >"$MEM/$fresh_top.$head.post.log" 2>&1 < /dev/null &
    fi
  fi
  "$SELF" next "$FMH" >/dev/null 2>&1 || :
  exit 0
fi

if [ "$1" = run ]; then
  id=$3; head=$4; out=; rc=0; why=; res=; now=
  [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $head =~ ^[0-9a-f]{40,64}$ ]] || exit 2
  run_lock=$STATE/.trunk-run-$id-$head.lock
  jg_lock_try_acquire "$run_lock" || exit 0
  trap 'jg_lock_release "$run_lock"' EXIT
  printf 'running %s %s\n' "$(date +%s)" "$$" > "$MEM/$id.$head.state"
  tip=$(verdict_tip "$(basename "$(mval "$STATE/$id.meta" project)")")
  out=$(JG_HOME="$FMH" JG_TRUNK_RUN_HELD_BY="$$" JG_TRUNK_EXPECT_HEAD="$head" "$FMH/bin/jg-trunk.sh" land "$id" 2>&1) || rc=$?
  request_log=$(mktemp "$MEM/$id.$head.request-XXXXXX.log") || exit 1
  printf '%s\n' "$out" > "$request_log"
  printf '%s\n' "$out" > "$MEM/$id.$head.log"
  if [ "$rc" -eq 0 ]; then
    JG_HOME="$FMH" "$FMH/bin/jg-machine-shadow.sh" landing "$id.$head" landed || true  # shadow report of the move (jg-machine-shadow.sh)
    proj=$(mval "$STATE/$id.meta" project)
    fresh=; printf '%s\n' "$out" | grep -q '^landed ' && fresh=1
    # The lander rebased the lane, so its branch is now at the landed commit: the same verdict stands for that head.
    br=$(mval "$STATE/$id.meta" branch); br=${br:-fm/$id}
    now=$(git -C "$proj" rev-parse --verify --quiet "refs/heads/$br^{commit}" 2>/dev/null) || now=
    out=$(JG_HOME="$FMH" "$FMH/bin/jg-teardown.sh" "$id" 2>&1) && out='cleaned up' || out="cleanup refused, nothing was forced: $(printf '%s' "$out" | tail -n 1 | cut -c1-200)"
    printf 'landed %s\n' "$out" > "$MEM/$id.$head.state"; rm -f -- "$STATE/$id.land-next"
    [ -z "$now" ] || [ "$now" = "$head" ] || printf 'landed %s\n' "$out" > "$MEM/$id.$now.state"
    jg_lock_acquire_wait "$MEM/.outbox.lock"
    printf 'trunk-landing: landed %s (local-trunk) on the local trunk (not live yet: the whole suite runs on it first, then live follows the captain'"'"'s word or the project'"'"'s waiver and its quiet window); %s\n' "$id" "$out" >> "$MEM/outbox"
    jg_lock_release "$MEM/.outbox.lock"
    # The whole suite runs at the landed commit apart from the landings, and reverts that one commit if it caused a red.
    cand=$(awk -F'\t' -v i="$id" '$1 == i { c = $3 } END { print c }' "$DATA_DIR/trunk-landings.tsv" 2>/dev/null)
    if [ -n "$fresh" ] && [ -n "$cand" ] && [ -d "$proj" ]; then
      setsid nohup "$SELF" post "$FMH" "$id" "$head" "$cand" >"$MEM/$id.$head.post.log" 2>&1 < /dev/null &
    fi
    "$SELF" next "$FMH" >/dev/null 2>&1 || :
    exit 0
  fi
  why=$(printf '%s\n' "$out" | grep -E '^(REFUSED|error|IN_PROGRESS):' | tail -n 1 | cut -c1-300)
  # The lander rebased the lane, so its branch may now be at another head: the same verdict stands for that head.
  br=$(mval "$STATE/$id.meta" branch); br=${br:-fm/$id}
  now=$(git -C "$(mval "$STATE/$id.meta" project)" rev-parse --verify --quiet "refs/heads/$br^{commit}" 2>/dev/null) || now=
  verdict_record "$id" "$head" "$now" "$tip" "$out" "${why:-landing failed; see $request_log}"
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
# Only a project registered local-trunk is ever touched; no-mistakes, direct-PR and local-only projects keep their own rules.
local_trunk() { [ "$(JG_HOME="$FMH" "$FMH/bin/jg-project-mode.sh" --raw "$(basename "$1")" 2>/dev/null | cut -d' ' -f1)" = local-trunk ] && echo yes || echo no; }
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
  JG_HOME="$FMH" "$FMH/bin/jg-trunk.sh" green-alarm "$proj" >/dev/null 2>&1 || :
done
# Under a go-live waiver every tick starts the batched live step (detached, so it never holds a landing back).
for tip in "$STATE"/trunk-tip-*; do
  [ -z "$QUIET" ] || break
  [ -f "$tip" ] || continue
  pn=${tip##*/trunk-tip-}
  awk -v p="$pn" '$1 == p { f = 1 } END { exit !f }' "$FMH/config/trunk-live-waiver" 2>/dev/null || continue
  [ -d "$FMH/projects/$pn" ] && [ "$(local_trunk "$FMH/projects/$pn")" = yes ] || continue
  setsid nohup "$SELF" live "$FMH" "$pn" >/dev/null 2>&1 < /dev/null &
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
# A landing in progress: lanes land one at a time, so a second lane never races the first for the trunk. Only a lane's own
# `<task>.<head>.state` counts; the lander's admission records (`<task>.<head>.<context>.state`) are not landings.
busy() {
  local f l
  for f in "$MEM"/*.state; do
    [ -f "$f" ] || continue
    ! printf '%s' "${f##*/}" | grep -Eq '\.[0-9a-f]{40,64}\.[0-9a-f]{40,64}\.state$' || continue
    l=$(cat "$f" 2>/dev/null || true)
    case $l in running*) run_alive "$l" && return 0 ;; esac
  done
  return 1
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
  case $(mval "$meta" mode) in local-trunk|local-only) ;; *) continue ;; esac
  proj=$(mval "$meta" project); [ -d "$proj" ] || continue
  [ -e "$STATE/trunk-tip-$(basename "$proj")" ] || continue
  [ "$(local_trunk "$proj")" = yes ] || continue
  branch=$(mval "$meta" branch); branch=${branch:-fm/$id}
  head=$(git -C "$proj" rev-parse --verify --quiet "refs/heads/$branch^{commit}") || continue
  st=$MEM/$id.$head.state; line=$(cat "$st" 2>/dev/null || true)
  case $line in landed*) continue ;; esac
  at=$(ready_at "$id") || continue
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
        report "$id.$head" "$id not landed: ${line#final }" "$why"; lane_refusal_reach "$id" "$head" "$proj" "$branch" "$why"; continue
      fi ;;
    retry*) verdict_due "$st" || continue ;;
    wait*) [ -z "$QUIET" ] || verdict_due "$st" || continue; report "$id.$head" "$id waits to land: ${line#wait }" "${line#wait }" ;;
  esac
  # <epoch done> <task> <head> <project> <1, or 0 for a lane marked `land-next`> <1, or 0 for a lane once returned for a conflict>
  cands="$cands$at $id $head $(basename "$proj") $([ -e "$STATE/$id.land-next" ] && echo 0 || echo 1) $(verdict_returned "$id" && echo 0 || echo 1)"$'\n'
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
if ! busy; then
  # The flush rule (bin/jg-trunk-policy-lib.sh): a project's ready lanes wait until flush-at-ready of them are ready, or the oldest has
  # waited flush-after-minutes, or `jg-trunk.sh flush` was run; then they all land (up to batch-max, oldest done first; the rest follow
  # at once). A lane marked `land-next` goes first and lands at once, with or without the others. One project per stack.
  now=$(date +%s); ready=(); id=; head=
  while read -r pn; do
    [ -n "$pn" ] || continue
    list=$(printf '%s' "$cands" | awk -v p="$pn" '$4 == p' | sort -k5,5n -k6,6n -k1,1n -k2,2)
    oldest=$(printf '%s\n' "$list" | sort -n -k1,1 | head -n 1 | cut -d' ' -f1)
    at_ready=$(polnum flush-at-ready "$pn" 3); after=$(polnum flush-after-minutes "$pn" 20)
    if [ -e "$STATE/trunk-flush-$pn" ] || [ "$(printf '%s\n' "$list" | grep -c .)" -ge "$at_ready" ] || [ $(( now - ${oldest:-0} )) -ge $(( after * 60 )) ]; then :; else
      list=$(printf '%s\n' "$list" | awk '$5 == 0')
    fi
    [ -n "$list" ] || continue
    batch=$(printf '%s\n' "$list" | head -n "$(jg_trunk_policy batch-max "$pn")" | awk '{ printf "%s%s@%s", (NR > 1 ? " " : ""), $2, $3 }')
    read -r -a ready <<< "$batch"; break
  done < <(printf '%s' "$cands" | sort -n -k1,1 | awk '!seen[$4]++ { print $4 }')
  [ "${#ready[@]}" -gt 0 ] || { rmdir "$MEM/.start" 2>/dev/null; exit 0; }
  if [ "${#ready[@]}" -ge 2 ]; then
    for arg in "${ready[@]}"; do printf 'running %s\n' "$(date +%s)" > "$MEM/${arg%%@*}.${arg#*@}.state"; done
    launch_log=$(mktemp "$MEM/batch.launch-XXXXXX.log") || exit 1
    setsid nohup "$SELF" runbatch "$FMH" "${ready[@]}" >"$launch_log" 2>&1 < /dev/null &
    id=${ready[0]%%@*}; head=${ready[0]#*@}
  else
  id=${ready[0]%%@*}; head=${ready[0]#*@}
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

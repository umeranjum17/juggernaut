#!/usr/bin/env bash
# lead-sweep watcher check: every beat, clean up the landed lanes of this home, unforced, with no model turn.
# Usage: lead-sweep.sh check <jg-home>   (the registered check: prints the results of finished jobs, starts a job, returns)
#        lead-sweep.sh job <jg-home>     (one sweep as its own detached job, one at a time per home; the check starts it)
#        lead-sweep.sh run <jg-home>     (one sweep in the foreground, printing what a check prints)
# A teardown can wait minutes for the project's slot lock, so the sweep is not run inside the check's 30-second limit:
# `check` starts `job` with setsid and returns, and the job's output is published as data/lead-sweep/results.<time> and
# printed by the next beat. Lanes are swept oldest done line first, so a lane never waits behind a newer one.
#
# A lane of this home (state/<id>.meta, kind ship or scout) whose latest status line is `done` or `resolved` (an answered
# lane) is swept when it has landed:
#   - ship: its branch head is on the trunk and is not the commit the lane started on (meta base=) (state/trunk-tip-<project> for a local-trunk project, else the default branch
#     of the clone), or its recorded pull request is merged (GitHub only, asked at most every JG_LEAD_SWEEP_PR_MIN
#     minutes, default 10, per lane);
#   - scout (Recon): its report data/<id>/report.md exists, Main relayed it (its ticket has the `relayed` move in data/moves.log,
#     which Main writes with bin/jg-move.sh when it relays the findings), and no message reached its inbox in the last
#     JG_LEAD_SWEEP_QUIET_MIN minutes (default 60). A done line, a passed critic or a gone agent is not enough; until then the
#     record, inbox and copy stay (the agent may still end at its done line).
# The sweep then runs `bin/jg-teardown.sh <id>` and nothing else: no --force, ever. The teardown owns the landed-work test
# and every gate (unlanded or dirty work, the report, captain-call inventory and depth gates), so a lane with unlanded work
# or a failing gate is refused and left alone. A lane a landing is running for (state/.trunk-run-<id>-*.lock) is skipped.
# A `resolved` lane that has not landed is left alone and reported once (`lead-sweep: <id> ended as resolved, left alone: ...`);
# a `done` lane that has not landed is waiting for its landing and prints nothing.
# Output, which becomes a check wake: `lead-sweep: <id> cleaned up (<why>)` once. A cleanup that is refused or left alone is the
# drift alert (bin/jg-alert.sh raise --deliver), once per lane and reason (data/lead-sweep/<id>.reported); the same refusal on the next beat prints nothing.
# The other ends of a lane (machine 10 request; worker expire and retire), each acted on once and never forced:
#   done, not landed   the agent ends at once (`bin/jg-control.sh <id> exit`); the copy, branch and ticket stay;
#   parked             a ship lane whose last line is paused, blocked or needs-decision for JG_LEAD_SWEEP_PARK_H hours (default 24;
#                      JG_LEAD_SWEEP_PARK_EMPTY_H, default 2, when its branch holds no commit of its own): the agent ends and a
#                      clean copy goes back (`jg-teardown.sh <id> --park`); the branch, the ticket and the records stay;
#   never started      a ship lane with no status line JG_LEAD_SWEEP_START_MIN minutes (default 30) after its record was written:
#                      one relaunch with a note; if it still has none after the same time, it is parked as above;
#   agent gone         a lane whose agent is dead or missing, whatever its last line, is cleaned up when its work has landed.
# JG_LEAD_SWEEP_TEARDOWN, JG_LEAD_SWEEP_GH, JG_LEAD_SWEEP_CONTROL and JG_LEAD_SWEEP_AGENT (<id> -> alive|dead|missing|unknown) name
# the teardown, gh-axi, control and agent-state commands; JG_LEAD_SWEEP_NOW is the clock (tests point them at stubs).
set -u
MODE=${1:-}
[ "$#" -eq 2 ] && case $MODE in check|job|run) true ;; *) false ;; esac && [ -d "$2/state" ] || { echo "usage: lead-sweep.sh check|job|run <jg-home>" >&2; exit 2; }
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")
FMH=$(cd "$2" && pwd -P)
STATE=$FMH/state
MEM=$FMH/data/lead-sweep
TEARDOWN=${JG_LEAD_SWEEP_TEARDOWN:-$FMH/bin/jg-teardown.sh}
GH=${JG_LEAD_SWEEP_GH:-gh-axi}
CONTROL=${JG_LEAD_SWEEP_CONTROL:-$FMH/bin/jg-control.sh}
NOW=${JG_LEAD_SWEEP_NOW:-$(date +%s)}
num() { case ${1:-} in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }
PARK_S=$(( $(num "${JG_LEAD_SWEEP_PARK_H:-}" 24) * 3600 ))
PARK_EMPTY_S=$(( $(num "${JG_LEAD_SWEEP_PARK_EMPTY_H:-}" 2) * 3600 ))
START_S=$(( $(num "${JG_LEAD_SWEEP_START_MIN:-}" 30) * 60 ))
QUIET_S=$(( $(num "${JG_LEAD_SWEEP_QUIET_MIN:-}" 60) * 60 ))
PR_MIN=${JG_LEAD_SWEEP_PR_MIN:-10}; case $PR_MIN in ''|*[!0-9]*) PR_MIN=10 ;; esac
umask 077
mkdir -p "$MEM" || exit 0
# drift <lane> <note>: a refused or left-alone cleanup is the drift alert, one per lane; a changed reason rings again.
drift() {
  local a=$FMH/bin/jg-alert.sh
  JG_HOME="$FMH" JG_STATE_OVERRIDE="$STATE" "$a" resolve "drift--lead-sweep-$1" >/dev/null 2>&1 || true
  JG_HOME="$FMH" JG_STATE_OVERRIDE="$STATE" "$a" raise drift "lead-sweep-$1" --deliver --ticket "$1" --note "$2" >/dev/null 2>&1 \
    || echo "lead-sweep: $2"
}
case $MODE in
  check)
    # Print every finished job's results, oldest first, then make sure a job is running. The job itself refuses to start
    # while another holds the lock, so a beat that finds one running changes nothing.
    for f in "$MEM"/results.*; do
      [ -f "$f" ] || continue
      cat "$f" && rm -f -- "$f"
    done
    if [ "${JG_TEST_SEAM:-}" = 1 ] && [ -n "${JG_TEST_DETACHED_REGISTRY:-}" ]; then
      setsid nohup env JG_LEAD_SWEEP_REGISTER=1 "$SELF" job "$FMH" > /dev/null 2>&1 < /dev/null &
    else
      setsid nohup "$SELF" job "$FMH" > /dev/null 2>&1 < /dev/null &
    fi
    exit 0 ;;
  job)
    # shellcheck source=bin/jg-wake-lib.sh
    . "$FMH/bin/jg-wake-lib.sh"
    if [ "${JG_LEAD_SWEEP_REGISTER:-}" = 1 ]; then
      printf '%s %s\n' "$$" "$(jg_pid_identity "$$" 2>/dev/null)" >> "$JG_TEST_DETACHED_REGISTRY" 2>/dev/null || :
    fi
    jg_lock_try_acquire "$MEM/.job.lock" || exit 0
    trap 'jg_lock_release "$MEM/.job.lock"' EXIT
    tmp=$(mktemp "$MEM/.job-XXXXXX") || exit 1
    "$SELF" run "$FMH" > "$tmp" 2>&1 || true
    if [ -s "$tmp" ]; then mv -- "$tmp" "$MEM/results.$(date +%s).$$"; else rm -f -- "$tmp"; fi
    exit 0 ;;
esac
mval() { sed -n "s/^$2=//p" "$1" | tail -n 1; }
mtime() { stat -c %Y "$1" 2>/dev/null || echo "$NOW"; }
run_as_home() { JG_HOME="$FMH" JG_STATE_OVERRIDE="$STATE" "$@"; }
# refuse <lane> <text>: a step that failed is one alert per lane and text, like a refused cleanup.
refuse() {
  [ "$(cat "$MEM/$1.reported" 2>/dev/null)" != "$2" ] || return 0
  printf '%s\n' "$2" > "$MEM/$1.reported"
  if declare -F drift >/dev/null 2>&1; then drift "$1" "$1 $2"; else echo "lead-sweep: $1 $2"; fi
}
# agent_state <meta>: alive, dead, missing or unknown for the lane's recorded endpoint (the backend's own classifier).
agent_state() {
  local id=${1##*/}; id=${id%.meta}
  if [ -n "${JG_LEAD_SWEEP_AGENT:-}" ]; then run_as_home "$JG_LEAD_SWEEP_AGENT" "$id" 2>/dev/null || echo unknown; return 0; fi
  ( . "$FMH/bin/jg-backend.sh" >/dev/null 2>&1 \
      && jg_backend_agent_state "$(jg_backend_of_meta "$1")" "$(jg_backend_target_of_meta "$1")" "$1" "$id" ) 2>/dev/null || echo unknown
}
# own_commit <meta> <project> <branch>: succeeds when the lane's branch holds a commit past the one it started on.
own_commit() {
  local head base; head=$(git -C "$2" rev-parse --verify --quiet "refs/heads/$3^{commit}") || head=
  base=$(mval "$1" base)
  [ -n "$head" ] && [ -n "$base" ] && [ "$head" != "$base" ]
}
# park <lane> <why>: the agent ends and a clean copy goes back; the branch, the ticket and the records stay.
park() {
  local out rc=0
  out=$(run_as_home "$TEARDOWN" "$1" --park 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then rm -f -- "$MEM/$1.reported"; echo "lead-sweep: $1 parked ($2); its branch and ticket stay"
  else refuse "$1" "could not be parked ($2): $(printf '%s\n' "$out" | grep -E '^(REFUSED|error)' | tail -n 1 | cut -c1-200)"; fi
}

# scout_relayed <meta>: succeeds when the scout's ticket has the relayed move and its inbox has been quiet for the quiet window.
scout_relayed() {
  local id=${1##*/} ticket last
  id=${id%.meta}; ticket=$(mval "$1" ticket)
  [ -n "$ticket" ] && awk -F'\t' -v t="$ticket" '$2 == t && $4 == "relayed" { f = 1 } END { exit !f }' "$FMH/data/moves.log" 2>/dev/null || return 1
  last=$(find "$STATE/$id.inbox" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1); last=${last%%.*}
  case $last in ''|*[!0-9]*) return 0 ;; esac
  [ $(( NOW - last )) -ge "$QUIET_S" ]
}

# why_landed <meta> <project> <branch>: prints why the ship lane counts as landed; prints nothing when it does not.
why_landed() {
  local id=${1##*/} head base target tipf pr slug num asked
  id=${id%.meta}
  head=$(git -C "$2" rev-parse --verify --quiet "refs/heads/$3^{commit}") || head=
  # A lane still on the commit it started on holds no work: that head is an ancestor of the trunk, yet nothing landed.
  base=$(mval "$1" base)
  [ -z "$base" ] || [ "$head" != "$base" ] || return 0
  tipf=$STATE/trunk-tip-$(basename "$2")
  if [ -s "$tipf" ]; then target=$(cat "$tipf"); else target=$(git -C "$2" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || target=; fi
  if [ -n "$head" ] && [ -n "$target" ] && git -C "$2" merge-base --is-ancestor "$head" "$target" 2>/dev/null; then
    echo 'its head is on the trunk'; return 0
  fi
  pr=$(mval "$1" pr)
  slug=$(printf '%s\n' "$pr" | sed -n 's#^https://github\.com/\([A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*\)/pull/[0-9]*$#\1#p')
  num=${pr##*/}
  [ -n "$slug" ] || return 0
  asked=$MEM/$id.asked
  [ -z "$(find "$asked" -mmin "-$PR_MIN" 2>/dev/null)" ] || return 0
  : > "$asked"
  [ "$(timeout 20 "$GH" api "repos/$slug/pulls/$num" --jq .merged 2>/dev/null)" = true ] && echo 'its pull request is merged'
  return 0
}

# Oldest report first: a lane's status file modification time is when it last reported; a lane with no status line
# is ordered by its record's age.
order=$(for m in "$STATE"/*.meta; do
  [ -f "$m" ] || continue
  i=${m##*/}; i=${i%.meta}
  if [ -f "$STATE/$i.status" ]; then t=$(mtime "$STATE/$i.status"); else t=$(mtime "$m"); fi
  printf '%s %s\n' "$t" "$i"
done | sort -n | cut -d' ' -f2)
for id in $order; do
  meta=$STATE/$id.meta
  [ -f "$meta" ] || continue
  kind=$(mval "$meta" kind)
  case $kind in ship|scout) ;; *) continue ;; esac
  line=$(tail -n 1 "$STATE/$id.status" 2>/dev/null)
  ls "$STATE"/.trunk-run-"$id"-*.lock >/dev/null 2>&1 && continue
  proj=$(mval "$meta" project); branch=$(mval "$meta" branch); branch=${branch:-fm/$id}
  case $line in
    done\ *|done:*) ended='done' ;;
    resolved\ *|resolved:*) ended=resolved ;;
    paused\ *|paused:*|blocked\ *|blocked:*|needs-decision\ *|needs-decision:*)
      # A parked lane past its limit gives its agent and copy back; a lane whose agent is gone and whose work landed is swept below.
      ended=gone
      if [ "$kind" = ship ] && [ -d "$proj" ] && [ ! -e "$STATE/$id.parked" ]; then
        limit=$PARK_S; own_commit "$meta" "$proj" "$branch" || limit=$PARK_EMPTY_S
        [ $(( NOW - $(mtime "$STATE/$id.status") )) -lt "$limit" ] || { park "$id" "waiting for $(( limit / 3600 )) hours"; continue; }
      fi ;;
    '')
      # Never started: one relaunch, then the lane is closed the way a parked one is.
      [ "$kind" = ship ] && [ ! -e "$STATE/$id.parked" ] || continue
      since=$(mtime "$meta"); tried=$(head -n 1 "$MEM/$id.relaunched" 2>/dev/null)
      case $tried in ''|*[!0-9]*) tried=0 ;; esac
      [ "$tried" -le "$since" ] || since=$tried
      [ $(( NOW - since )) -ge "$START_S" ] || continue
      if [ "$tried" -eq 0 ]; then
        if run_as_home "$CONTROL" "$id" relaunch --note "Your session never wrote a status line in $(( START_S / 60 )) minutes. Read your instructions, write a working status line and begin the task." >/dev/null 2>&1; then
          echo "$NOW" > "$MEM/$id.relaunched"; echo "lead-sweep: $id never started in $(( START_S / 60 )) minutes, relaunched once"
        else refuse "$id" "never started and could not be relaunched"; fi
      else park "$id" "never started, even after a relaunch"; fi
      continue ;;
    *) ended=gone ;;
  esac
  # Any other lane is swept only when its agent is gone: its record is cleaned once its work has landed.
  if [ "$ended" = gone ]; then case $(agent_state "$meta") in dead|missing) ;; *) continue ;; esac; fi
  why=
  if [ "$kind" = scout ]; then
    [ ! -s "$FMH/data/$id/report.md" ] || ! scout_relayed "$meta" || why='its report exists and Main relayed it'
  else
    [ ! -d "$proj" ] || why=$(why_landed "$meta" "$proj" "$branch")
  fi
  [ "$ended" != gone ] || [ -z "$why" ] || why="its agent is gone and $why"
  if [ -z "$why" ]; then
    # A done lane that has not landed is waiting for its landing: its agent ends at once and its copy and branch stay.
    if [ "$ended" = 'done' ] && [ ! -e "$STATE/$id.parked" ]; then
      exited=$(head -n 1 "$STATE/$id.exit" 2>/dev/null); case $exited in ''|*[!0-9]*) exited=0 ;; esac
      case $(agent_state "$meta") in
        dead|missing) ;;
        *) if [ "$exited" -lt "$(mtime "$STATE/$id.status")" ]; then
             if run_as_home "$CONTROL" "$id" exit >/dev/null 2>&1; then echo "lead-sweep: $id is done, its agent was ended; its copy and branch stay"
             else refuse "$id" "is done, but its agent could not be ended"; fi
           fi ;;
      esac
    fi
    # Only an answered lane is reported: nothing else will ever revisit it. A done lane is waiting for its landing.
    if [ "$ended" = resolved ] && [ "$kind" = ship ] && [ "$(cat "$MEM/$id.reported" 2>/dev/null)" != unlanded ]; then
      echo unlanded > "$MEM/$id.reported"
      drift "$id" "$id ended as resolved, left alone: its work has not landed on the trunk"
    fi
    continue
  fi
  rc=0
  out=$(JG_HOME="$FMH" JG_STATE_OVERRIDE="$STATE" "$TEARDOWN" "$id" 2>&1) || rc=$?
  last=$(printf '%s\n' "$out" | grep -E '^(REFUSED|error)' | tail -n 1)
  [ -n "$last" ] || last=$(printf '%s\n' "$out" | tail -n 1)
  last=$(printf '%s' "$last" | cut -c1-200)
  case $rc in
    0) rm -f -- "$MEM/$id.reported" "$MEM/$id.asked"; echo "lead-sweep: $id cleaned up ($why)" ;;
    4) rm -f -- "$MEM/$id.reported" "$MEM/$id.asked"; echo "lead-sweep: $id cleaned up ($why), but a returned worktree slot was lost: $last" ;;
    *)
      [ "$(cat "$MEM/$id.reported" 2>/dev/null)" != "$last" ] || continue
      printf '%s\n' "$last" > "$MEM/$id.reported"
      drift "$id" "$id ($why) not cleaned up, nothing was forced: ${last:-the cleanup was refused}" ;;
  esac
done
exit 0

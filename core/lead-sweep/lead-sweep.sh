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
#     JG_LEAD_SWEEP_QUIET_MIN minutes (default 60). With a handoff record (jg-recon-handoff.sh) the draft must be accepted and the relayed
#     move must not be older than that verdict; a steer still waiting in the inbox keeps the Recon. A done line, a passed critic or a gone agent is not enough; until then the
#     record, inbox and copy stay (the agent may still end at its done line).
# The sweep then runs `bin/jg-teardown.sh <id>` and nothing else: no --force, ever. The teardown owns the landed-work test
# and every gate (unlanded or dirty work, the report, captain-call inventory and depth gates), so a lane with unlanded work
# or a failing gate is refused and left alone. A lane a landing is running for (state/.trunk-run-<id>-*.lock) is skipped.
# A `resolved` lane that has not landed is left alone and reported once (`lead-sweep: <id> ended as resolved, left alone: ...`);
# a `done` lane that has not landed is waiting for its landing and prints nothing.
# Output, which becomes a check wake: `lead-sweep: <id> cleaned up (<why>)` once. A cleanup that is refused or left alone is the
# drift alert (bin/jg-alert.sh raise --deliver), once per lane and reason (data/lead-sweep/<id>.reported); the same refusal on the next beat prints nothing.
# A lane someone waits for is live and is never ended, parked or cleaned up by this sweep: an unread steer in its inbox, an open Recon critic
# round, a steer newer than its last status line, or a relaunch after its done line (bin/jg-facts-lib.sh jg_fact_lane_waited). A done line does not
# end it. When the agent of such a lane is already dead or missing, the sweep raises the worker-stopped alert (P1, bin/jg-worker-stop-alert.sh) at once.
# A lane whose head is on the trunk is finished even when its agent was started again after the done line or it read a steer: only an unread steer
# or an open Recon round keeps it. A backlog close teardown recorded but never landed, whose task record is gone, is replayed on every beat and
# its leftover files retired (pending_closes), so a ticket never stays in flight until a restart.
# The other ends of a lane (machine 10 request; worker expire and retire), each acted on once and never forced:
#   done, not landed   the agent ends at once (`bin/jg-control.sh <id> exit`); the copy, branch and ticket stay;
#   parked             a ship lane whose last line is a declared park (`paused ... reason=parked`) is parked on the next beat, at once: the
#                      worker set itself aside, so nothing is waited for. A lane whose last line is any other paused, blocked or
#                      needs-decision line is parked after JG_LEAD_SWEEP_PARK_H hours (default 24;
#                      JG_LEAD_SWEEP_PARK_EMPTY_H, default 2, when its branch holds no commit of its own): the agent ends and a
#                      clean copy goes back (`jg-teardown.sh <id> --park`); the branch, the ticket and the records stay;
# A parked lane is rechecked on every beat. bin/jg-teardown-park-lib.sh writes state/<id>.parked with the branch, its head, its base and
# `owner=lead`, and no other actor revisits that record, so its lead owns what the park left open and this sweep asks it:
#   landed   its branch head is on the trunk (or its recorded pull request is merged): the park record is cleaned up, the alert this
#            sweep raised for it is resolved with that commit as proof, and one line says so;
#   live     the lane has a record again (a respawn): the stale park record would hide the new incarnation from this sweep, so it is cleared;
#   open     it is not landed: after JG_LEAD_SWEEP_PARKED_RECHECK_MIN minutes (default 60) ONE alert, parked-lane--<subject>, names its branch
#            and the next step its lead must take - land, re-prove or drop - and the obligation is kept in
#            data/lead-sweep/<id>.parked-owner (owner=lead, branch, head, next_action). The same alert is rung again only when the step
#            changes, so one parked lane never carries two alerts;
#   never started      a ship lane with no status line JG_LEAD_SWEEP_START_MIN minutes (default 30) after its record was written:
#                      one relaunch with a note; if it still has none after the same time, it is parked as above;
#   agent gone         a lane whose agent is dead or missing, whatever its last line, is cleaned up when its work has landed.
# JG_LEAD_SWEEP_TEARDOWN, JG_LEAD_SWEEP_GH, JG_LEAD_SWEEP_CONTROL and JG_LEAD_SWEEP_AGENT (<id> -> alive|dead|missing|unknown) name
# the teardown, gh-axi, control and agent-state commands; JG_LEAD_SWEEP_NOW is the clock (tests point them at stubs), and
# JG_LEAD_SWEEP_PARKED_RECHECK_MIN is the parked lane's recheck window in minutes (default 60).
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
# A parked lane's recheck window: how long a park is left alone before its lead is asked for the next step.
RECHECK_MIN=${JG_LEAD_SWEEP_PARKED_RECHECK_MIN:-60}; case $RECHECK_MIN in ''|*[!0-9]*) RECHECK_MIN=60 ;; esac
RECHECK_S=$(( RECHECK_MIN * 60 ))
# The installed copy sits alone in its data directory, so the lib comes from the home; the repo-relative path serves a run from the checkout.
# shellcheck source=bin/jg-facts-lib.sh disable=SC1091
if [ -f "$FMH/bin/jg-facts-lib.sh" ]; then . "$FMH/bin/jg-facts-lib.sh"; else . "$(dirname "$SELF")/../../bin/jg-facts-lib.sh"; fi
umask 077
mkdir -p "$MEM" || exit 0
# capacity_snapshot <lane> <reason> <next action>: retain observations, never a release receipt.
# The existing central drift alert owns pending/resolved and its original `since`; this file only binds its action
# to the observed home/task/spawn_gen and copy. A missing generation or copy is explicitly unknown, never free capacity.
# Refusal -> pending; changed refusal -> same pending episode; successful park/cleanup -> still pending until the
# preservation and authoritative reusable-slot proof owners settle it. Status, ack and a reduced record count cannot settle it.
capacity_snapshot() {
  local id=$1 reason=$2 next=$3 out tmp head=unknown inventory=unknown
  out=$MEM/$lane_subject.capacity
  [ ! -L "$out" ] && { [ ! -e "$out" ] || [ -f "$out" ]; } || {
    echo "lead-sweep: $id capacity snapshot is unsafe; lead must repair its retention destination" >&2; return 1;
  }
  [ -z "${lane_wt:-}" ] || [ ! -d "$lane_wt" ] || inventory=copy-present-slot-unverified
  [ -z "${proj:-}" ] || head=$(git -C "$proj" rev-parse --verify --quiet "refs/heads/$branch^{commit}" 2>/dev/null) || head=unknown
  tmp=$(mktemp "$MEM/.$id.capacity.XXXXXX") || return 1
  {
    printf 'home=%s\ntask=%s\ngeneration=%s\n' "$FMH" "$id" "${lane_gen:-unknown}"
    printf 'alert_key=drift--lead-sweep-%s\n' "$lane_subject"
    printf 'project=%s\nworktree=%s\nbranch=%s\nhead=%s\n' "$proj" "${lane_wt:-unknown}" "$branch" "$head"
    printf 'inventory=%s\nowner=lead\nreason=%s\nnext_action=%s\nobserved_at=%s\n' "$inventory" "$reason" "$next" "$NOW"
  } > "$tmp" && mv -f -- "$tmp" "$out" || { rm -f -- "$tmp"; return 1; }
}
# drift <lane> <note>: a changed reason rings the same episode without resolving it or resetting its age.
drift() {
  local a=$FMH/bin/jg-alert.sh note="$2; generation=$lane_gen; next actor=lead: preserve all bytes and branch, remedy this refusal through guarded teardown/park, then prove reusable slot; snapshot=$MEM/$lane_subject.capacity" err
  capacity_snapshot "$1" "$2" 'preserve bytes and branch; use guarded return; prove reusable slot' || {
    echo "lead-sweep: $1 capacity snapshot failed; lead must repair retention before returning the copy" >&2; return 1;
  }
  err=$(JG_HOME="$FMH" JG_STATE_OVERRIDE="$STATE" "$a" raise drift "lead-sweep-$lane_subject" --deliver --repeat \
    --home "$FMH" --project "$proj" --ticket "$1" --note "$note" --wake check --text "lead-sweep: $note" 2>&1) || {
    echo "lead-sweep: $note; alert delivery refused: $err"; return 1;
  }
  echo "lead-sweep: $note"
}
case $MODE in
  check)
    # Print every finished job's results, oldest first, then make sure a job is running. The job itself refuses to start
    # while another holds the lock, so a beat that finds one running changes nothing.
    result=0
    for f in "$MEM"/results.*; do
      [ -f "$f" ] || continue
      case $f in *.failed) result=1 ;; esac
      cat "$f" && rm -f -- "$f"
    done
    if [ "${JG_TEST_SEAM:-}" = 1 ] && [ -n "${JG_TEST_DETACHED_REGISTRY:-}" ]; then
      setsid nohup env JG_LEAD_SWEEP_REGISTER=1 "$SELF" job "$FMH" > /dev/null 2>&1 < /dev/null &
    else
      setsid nohup "$SELF" job "$FMH" > /dev/null 2>&1 < /dev/null &
    fi
    exit "$result" ;;
  job)
    # shellcheck source=bin/jg-wake-lib.sh
    . "$FMH/bin/jg-wake-lib.sh"
    if [ "${JG_LEAD_SWEEP_REGISTER:-}" = 1 ]; then
      printf '%s %s\n' "$$" "$(jg_pid_identity "$$" 2>/dev/null)" >> "$JG_TEST_DETACHED_REGISTRY" 2>/dev/null || :
    fi
    jg_lock_try_acquire "$MEM/.job.lock" || exit 0
    trap 'jg_lock_release "$MEM/.job.lock"' EXIT
    tmp=$(mktemp "$MEM/.job-XXXXXX") || exit 1
    result=0 suffix=
    "$SELF" run "$FMH" > "$tmp" 2>&1 || result=$?
    if [ "$result" -ne 0 ]; then
      suffix=.failed
      printf 'lead-sweep: sweep exited with status %s\n' "$result" >> "$tmp"
    fi
    if [ -s "$tmp" ]; then mv -- "$tmp" "$MEM/results.$(date +%s).$$$suffix"; else rm -f -- "$tmp"; fi
    exit 0 ;;
esac
mval() { sed -n "s/^$2=//p" "$1" | tail -n 1; }
mtime() { stat -c %Y "$1" 2>/dev/null || echo "$NOW"; }
run_as_home() { JG_HOME="$FMH" JG_STATE_OVERRIDE="$STATE" "$@"; }
# refuse <lane> <text>: a step that failed is one alert per lane and text, like a refused cleanup.
refuse() {
  [ "$(cat "$MEM/$1.reported" 2>/dev/null)" != "$2" ] || return 0
  if drift "$1" "$1 $2"; then printf '%s\n' "$2" > "$MEM/$1.reported"; fi
}
# agent_state <meta>: alive, dead, missing or unknown for the lane's recorded endpoint (the backend's own classifier).
agent_state() {
  local id=${1##*/}; id=${id%.meta}
  if [ -n "${JG_LEAD_SWEEP_AGENT:-}" ]; then run_as_home "$JG_LEAD_SWEEP_AGENT" "$id" 2>/dev/null || echo unknown; return 0; fi
  ( . "$FMH/bin/jg-backend.sh" >/dev/null 2>&1 \
      && jg_backend_agent_state "$(jg_backend_of_meta "$1")" "$(jg_backend_target_of_meta "$1")" "$1" "$id" ) 2>/dev/null || echo unknown
}
# recon_phase <id> <kind>: the phase of a Recon's handoff record, none for any other lane or a Recon with no record.
recon_phase() {
  local p=none
  [ "$2" != scout ] || p=$(JG_HOME="$FMH" JG_DATA_OVERRIDE="$FMH/data" "$FMH/core/machines/observers/recon.sh" "$1" 2>/dev/null || echo none)
  printf '%s\n' "${p:-none}"
}
# lost_waited <lane> <why>: the agent of a waited-for lane is gone: a P1 alert to its owner, once per lane (the alert holds one live record per key).
lost_waited() {
  if [ -x "$FMH/bin/jg-worker-stop-alert.sh" ]; then run_as_home "$FMH/bin/jg-worker-stop-alert.sh" raise "$1" lost "$2" >/dev/null 2>&1 && return 0; fi
  [ "$(cat "$MEM/$1.reported" 2>/dev/null)" != "waited-lost-$2" ] || return 0
  printf 'waited-lost-%s\n' "$2" > "$MEM/$1.reported"
  echo "lead-sweep: $1's agent is gone and someone waits for it ($2)"
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
  if [ "$rc" -eq 0 ]; then
    [ ! -f "$MEM/$lane_subject.capacity" ] || capacity_snapshot "$1" "park returned success ($2)" 'verify preserved bytes and authoritative reusable slot; park alone is not recovery'
    rm -f -- "$MEM/$1.reported"; echo "lead-sweep: $1 parked ($2); its branch and ticket stay"
  else refuse "$1" "could not be parked ($2): $(printf '%s\n' "$out" | grep -E '^(REFUSED|error)' | tail -n 1 | cut -c1-200)"; fi
}

# scout_relayed <meta>: succeeds when the scout's current draft is relayed and its inbox has been quiet for the quiet window.
# A Recon with a handoff record (core/machines/tables/recon.tsv, read through its observer) is judged by that record: its phase must be
# accepted, and the relayed move must come at or after the accepting verdict, so a relay receipt for an older draft, or a draft still
# waiting for its critic, never closes it. With a record, a steer still waiting in its inbox also keeps it. A Recon with no record keeps the old test.
scout_relayed() {
  local id=${1##*/} ticket last phase accepted relayed
  id=${id%.meta}; ticket=$(mval "$1" ticket)
  [ -n "$ticket" ] || return 1
  relayed=$(awk -F'\t' -v t="$ticket" '$2 == t && $4 == "relayed" { r = $1 } END { print r }' "$FMH/data/moves.log" 2>/dev/null)
  [ -n "$relayed" ] || return 1
  phase=$(JG_HOME="$FMH" JG_DATA_OVERRIDE="$FMH/data" "$FMH/core/machines/observers/recon.sh" "$id" 2>/dev/null || echo none)
  if [ "$phase" != none ]; then
    [ "$phase" = accepted ] || return 1
    accepted=$(awk -F'\t' '$3 == "accepted" { a = $1 } END { print a }' "$FMH/data/$id/handoff.tsv" 2>/dev/null)
    case $accepted$relayed in *[!0-9]*) return 1 ;; esac
    [ "$relayed" -ge "$accepted" ] || return 1
    [ -z "$(find "$STATE/$id.inbox" -maxdepth 1 -type f -name '*.msg' 2>/dev/null | head -n 1)" ] || return 1
  fi
  last=$(find "$STATE/$id.inbox" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1); last=${last%%.*}
  case $last in ''|*[!0-9]*) return 0 ;; esac
  [ $(( NOW - last )) -ge "$QUIET_S" ]
}

# why_landed <meta> <project> <branch>: prints why the ship lane counts as landed; prints nothing when it does not.
why_landed() {
  local id=${1##*/} head
  id=${id%.meta}
  head=$(git -C "$2" rev-parse --verify --quiet "refs/heads/$3^{commit}") || head=
  why_landed_record "$1" "$2" "$3" "$head" "$id"
}

# why_landed_record <record> <project> <branch> <head> <id>: the one landed-work reader, for a lane record (state/<id>.meta) and for the
# park record that outlives it (both keep project, branch, head, base and pr). Prints why the lane counts as landed; prints nothing when not.
why_landed_record() {
  local base target tipf pr slug num asked
  # A lane still on the commit it started on holds no work: that head is an ancestor of the trunk, yet nothing landed.
  base=$(mval "$1" base)
  [ -z "$base" ] || [ "$4" != "$base" ] || return 0
  tipf=$STATE/trunk-tip-$(basename "$2")
  if [ -s "$tipf" ]; then target=$(cat "$tipf"); else target=$(git -C "$2" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || target=; fi
  if [ -n "$4" ] && [ -n "$target" ] && git -C "$2" merge-base --is-ancestor "$4" "$target" 2>/dev/null; then
    echo 'its head is on the trunk'; return 0
  fi
  pr=$(mval "$1" pr)
  slug=$(printf '%s\n' "$pr" | sed -n 's#^https://github\.com/\([A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*\)/pull/[0-9]*$#\1#p')
  num=${pr##*/}
  [ -n "$slug" ] || return 0
  asked=$MEM/$5.asked
  [ -z "$(find "$asked" -mmin "-$PR_MIN" 2>/dev/null)" ] || return 0
  : > "$asked"
  [ "$(timeout 20 "$GH" api "repos/$slug/pulls/$num" --jq .merged 2>/dev/null)" = true ] && echo 'its pull request is merged'
  return 0
}

# proof_whole <record> <id> <head>: 0 when the completion receipt and the sealed done-done run at that head are whole. The lander's own
# reader decides (bin/jg-merge-gate-lib.sh jg_dod_trunk_proof_gaps), so a parked lane is never judged by a second proof test; a home with
# no such lib cannot answer, and then the lead's next step is re-prove.
proof_whole() {
  local lib=$FMH/bin/jg-merge-gate-lib.sh
  [ -r "$lib" ] || return 1
  # shellcheck disable=SC1090 # the library is the home's own copy, so its path is read at run time
  ( . "$lib" && jg_dod_trunk_proof_gaps "$FMH" "$STATE" "$2" "$1" "$3" ) >/dev/null 2>&1
}

# parked_step <record> <head> <head state>: the next step the parked lane's lead must take, from records that already exist; prints one of
# drop, land or re-prove. <head state> is ok (the branch is there), gone (no such branch) or unknown (its project cannot be read).
parked_step() {
  local base status
  case $3 in
    gone) echo drop; return 0 ;;   # the branch is gone and its work is not on the trunk: nothing is left to land
    ok) ;; *) echo re-prove; return 0 ;;   # its project cannot be read: nothing can be landed until its lead decides
  esac
  base=$(mval "$1" base)
  [ -z "$base" ] || [ "$2" != "$base" ] || { echo drop; return 0; }   # it holds no commit of its own
  status=$STATE/$(mval "$1" task).status
  if [ ! -r "$status" ] || [ -z "$(grep -E '^done( \[[^]]*\])?:' "$status" | tail -n 1)" ]; then echo re-prove; return 0; fi
  proof_whole "$1" "$(mval "$1" task)" "$2" && echo land || echo re-prove
}

# parked_owner_record <id> <project> <branch> <head> <step> <alert key> <recheck due>: the obligation a park leaves, with its owner named.
# Written whole or not at all; a destination that is not a plain file is never written through.
parked_owner_record() {
  local out=$MEM/$1.parked-owner tmp
  [ ! -L "$out" ] && { [ ! -e "$out" ] || [ -f "$out" ]; } || {
    echo "lead-sweep: $1 parked-owner record is unsafe; its lead must repair $MEM" >&2; return 1;
  }
  tmp=$(mktemp "$MEM/.$1.parked-owner.XXXXXX") || return 1
  {
    printf 'home=%s\ntask=%s\nowner=lead\n' "$FMH" "$1"
    printf 'project=%s\nbranch=%s\nhead=%s\n' "$2" "$3" "$4"
    printf 'next_action=%s\nalert_key=%s\n' "$5" "$6"
    printf 'recheck_after=%s\nobserved_at=%s\n' "$7" "$NOW"
  } > "$tmp" && mv -f -- "$tmp" "$out" || { rm -f -- "$tmp"; return 1; }
}

# parked_resolve <key> <proof kind> <pointer>: close the one alert this sweep raised for a parked lane, when it is still open.
parked_resolve() {
  local rec=$STATE/alerts/$1.rec err
  [ -f "$rec" ] || return 0
  case $(sed -n 's/^state=//p' "$rec" | tail -n 1) in resolved) return 0 ;; esac
  err=$(JG_HOME="$FMH" JG_STATE_OVERRIDE="$STATE" "$FMH/bin/jg-alert.sh" resolve "$1" --proof "$2:$3" 2>&1) \
    || echo "lead-sweep: the parked-lane alert $1 could not be closed: $err"
}

# parked_alert <id> <project> <branch> <head> <step> <key> <head state>: one alert naming the branch and the next step its lead must take.
# The record is keyed by the lane, so a beat that finds the same step prints nothing and raises nothing; only a changed step rings
# again, which is what makes one park carry one alert.
parked_alert() {
  local note rec out
  note="$1 is parked and its work is not on the trunk: branch $3 at ${4:0:12}; next step for its lead: $5"
  case $7 in gone) note="$note (its branch is gone)" ;; unknown) note="$note (its project $2 cannot be read)" ;; esac
  rec=$STATE/alerts/$6.rec
  if [ -r "$rec" ] && [ "$(sed -n 's/^state=//p' "$rec" | tail -n 1)" != resolved ] \
    && [ "$(sed -n 's/^note=//p' "$rec" | tail -n 1)" = "$note" ]; then return 0; fi
  out=$(JG_HOME="$FMH" JG_STATE_OVERRIDE="$STATE" "$FMH/bin/jg-alert.sh" raise parked-lane "${6#parked-lane--}" --deliver --repeat \
    --home "$FMH" --project "$2" --ticket "$1" --note "$note" --wake check --text "lead-sweep: $note" 2>&1) || {
    echo "lead-sweep: $note; the alert was refused: $out"; return 1;
  }
  echo "lead-sweep: $note"
}

# parked_recheck: the owner and the recheck a park leaves behind, for every parked lane of this home.
parked_recheck() {
  local rec id gen subject key proj branch rhead head hstate why step parked_at due
  for rec in "$STATE"/*.parked; do
    [ -f "$rec" ] || continue
    id=$(mval "$rec" task)
    [ -n "$id" ] || id=${rec##*/}
    id=${id%.parked}
    proj=$(mval "$rec" project); branch=$(mval "$rec" branch); rhead=$(mval "$rec" head)
    [ -n "$branch" ] || continue
    gen=$(mval "$rec" spawn_gen); case $gen in ''|*[!A-Za-z0-9._-]*) gen=unknown ;; esac
    subject=$id; [ "$gen" = unknown ] || subject=$id-$gen
    key=parked-lane--$subject
    if [ -e "$STATE/$id.meta" ]; then
      # The lane is live again: this record belongs to an incarnation that is over, and it would hide the new one from this sweep.
      rm -f -- "$rec" "$MEM/$id.parked-owner"
      parked_resolve "$key" task "$id"
      echo "lead-sweep: $id was parked and has a record again; its parked record is cleared"
      continue
    fi
    parked_at=$(mval "$rec" parked_at); case $parked_at in ''|*[!0-9]*) parked_at=$(mtime "$rec") ;; esac
    due=$(( parked_at + RECHECK_S ))
    head=$rhead; hstate=unknown
    if [ -d "$proj" ]; then
      head=$(git -C "$proj" rev-parse --verify --quiet "refs/heads/$branch^{commit}" 2>/dev/null) || { head=$rhead; hstate=gone; }
      [ "$hstate" = gone ] || hstate=ok
    fi
    why=$(why_landed_record "$rec" "$proj" "$branch" "$head" "$id")
    if [ -n "$why" ]; then
      rm -f -- "$rec" "$MEM/$id.parked-owner"
      parked_resolve "$key" commit "$head"
      echo "lead-sweep: $id was parked and $why; its park record is cleaned up"
      continue
    fi
    step=$(parked_step "$rec" "$head" "$hstate")
    parked_owner_record "$id" "$proj" "$branch" "$head" "$step" "$key" "$due" || continue
    [ "$NOW" -ge "$due" ] || continue   # the recheck window: a fresh park is left alone until it runs out
    parked_alert "$id" "$proj" "$branch" "$head" "$step" "$key" "$hstate" || continue
  done
}

# pending_closes: a backlog close teardown recorded and never landed, whose task record is already gone, finishes on this beat: the close is
# replayed under teardown's own locks (bin/jg-backlog-transition-lib.sh) and the files the lane left beside its record are retired, so a
# landed lane's ticket never stays in flight until a restart. A lane with a record is left to its own teardown below, which owns that close.
pending_closes() {
  local marker id out note reported error
  ls "$STATE"/*.backlog-close >/dev/null 2>&1 || return 0
  for marker in "$STATE"/*.backlog-close; do
    id=${marker##*/}; id=${id%.backlog-close}
    [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || continue
    jg_fact_lane_lock_held "$STATE" "$id" && continue
    out=$(JG_HOME="$FMH" JG_STATE_OVERRIDE="$STATE" JG_DATA_OVERRIDE="$FMH/data" bash -c '
      set -u; FMH=$1; STATE=$2; marker=$3; id=$4
      . "$FMH/bin/jg-wake-lib.sh"; . "$FMH/bin/jg-backlog-lib.sh"; . "$FMH/bin/jg-backlog-transition-lib.sh"; . "$FMH/bin/jg-task-files-lib.sh"
      rc=0; jg_backlog_close_marker_replay_locked "$STATE" "$marker" "$FMH/data" || rc=$?
      case $rc in
        0) jg_task_files_retire "$STATE" "$id"; echo "closed ($JG_BACKLOG_CLOSE_REPLAY_RESULT)" ;;
        3) echo busy ;;
        *) echo "failed: $JG_BACKLOG_TRANSITION_ERROR" ;;
      esac' _ "$FMH" "$STATE" "$marker" "$id" 2>&1 | tail -n 1)
    reported=$MEM/$id.close-refusal
    case $out in
      closed*) rm -f -- "$MEM/$id.reported" "$reported"; echo "lead-sweep: $id's recorded backlog close was finished (${out#closed })" ;;
      busy|'') ;;
      *)
        # Teardown already retired the lane record. A close refusal has no lane or slot context.
        note="$id has a recorded backlog close that could not be finished: ${out#failed: }"
        [ "$(cat "$reported" 2>/dev/null)" != "$note" ] || continue
        if error=$(run_as_home "$FMH/bin/jg-alert.sh" raise drift "lead-sweep-close-$id" --deliver --repeat \
          --home "$FMH" --ticket "$id" --note "$note" --wake check --text "lead-sweep: $note" 2>&1); then
          printf '%s\n' "$note" > "$reported"
          echo "lead-sweep: $note"
        else
          echo "lead-sweep: $note; alert delivery refused: $error" >&2
        fi ;;
    esac
  done
}

# Oldest report first: a lane's status file modification time is when it last reported; a lane with no status line
# is ordered by its record's age.
parked_recheck
pending_closes
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
  jg_fact_lane_lock_held "$STATE" "$id" && continue
  proj=$(mval "$meta" project); branch=$(mval "$meta" branch); branch=${branch:-fm/$id}
  lane_wt=$(mval "$meta" worktree); lane_gen=$(mval "$meta" spawn_gen)
  case $lane_gen in ''|*[!a-zA-Z0-9._-]*) lane_gen=unknown ;; esac
  lane_subject=$id-$lane_gen
  [ "$lane_gen" != unknown ] || lane_subject=$id
  # A new incarnation must not inherit the previous one's notification cache or close its obligation.
  if [ "$(cat "$MEM/$id.generation" 2>/dev/null)" != "$lane_gen" ]; then
    rm -f -- "$MEM/$id.reported"
    printf '%s\n' "$lane_gen" > "$MEM/$id.generation"
  fi
  landed_why=
  if [ -n "$line" ]; then
    # A lane someone waits for is live, whatever its last line says: nothing here ends it. A waited-for agent that is gone is a loss.
    waited=$(jg_fact_lane_waited "$STATE" "$id" "$(recon_phase "$id" "$kind")" agent_state "$meta")
    if [ "$(jg_fact_val "$waited" waited)" = yes ]; then
      # Landed work owes its agent nothing: a lane whose head is on the trunk and whose only wait is its own later start (relaunched) or a steer
      # it already read is finished, so its cleanup goes on. The teardown still refuses a copy with uncommitted or unlanded work, so nothing
      # is lost; an unread steer or an open Recon round still keeps the lane live.
      landed_why=
      case $(jg_fact_val "$waited" reason) in
        relaunched|steer-read) [ "$kind" != ship ] || [ ! -d "$proj" ] || landed_why=$(why_landed "$meta" "$proj" "$branch") ;;
      esac
      if [ -z "$landed_why" ]; then
        case $(agent_state "$meta") in dead|missing) lost_waited "$id" "$(jg_fact_val "$waited" reason)" ;; esac
        continue
      fi
    fi
  fi
  case $line in
    done\ *|done:*) ended='done' ;;
    resolved\ *|resolved:*) ended=resolved ;;
    paused\ *|paused:*|blocked\ *|blocked:*|needs-decision\ *|needs-decision:*)
      # A parked lane past its limit gives its agent and copy back; a lane whose agent is gone and whose work landed is swept below.
      ended=gone
      if [ "$kind" = ship ] && [ -d "$proj" ] && [ ! -e "$STATE/$id.parked" ]; then
        limit=$PARK_S; own_commit "$meta" "$proj" "$branch" || limit=$PARK_EMPTY_S
        # A declared park is the worker setting itself aside: its copy goes back on this beat, with no wait.
        case $line in paused*reason=parked*) limit=0 ;; esac
        [ $(( NOW - $(mtime "$STATE/$id.status") )) -lt "$limit" ] || { park "$id" "$( [ "$limit" -gt 0 ] && echo "waiting for $(( limit / 3600 )) hours" || echo "declared parked" )"; continue; }
      fi ;;
    '')
      # Never started: one relaunch, then the lane is closed the way a parked one is.
      [ "$kind" = ship ] && [ ! -e "$STATE/$id.parked" ] || continue
      case $(jg_fact_val "$(jg_fact_sweep_retry "$STATE" "$MEM" "$id" "$NOW" "$START_S")" next) in
        relaunch)
          if run_as_home "$CONTROL" "$id" relaunch --note "Your session never wrote a status line in $(( START_S / 60 )) minutes. Read your instructions, write a working status line and begin the task." >/dev/null 2>&1; then
            echo "$NOW" > "$MEM/$id.relaunched"; echo "lead-sweep: $id never started in $(( START_S / 60 )) minutes, relaunched once"
          else refuse "$id" "never started and could not be relaunched"; fi ;;
        park) park "$id" "never started, even after a relaunch" ;;
        *) continue ;;
      esac
      continue ;;
    *) ended=gone ;;
  esac
  # Any other lane is swept only when its agent is gone: its record is cleaned once its work has landed.
  if [ "$ended" = gone ]; then case $(agent_state "$meta") in dead|missing) ;; *) continue ;; esac; fi
  why=$landed_why
  if [ -n "$why" ]; then :
  elif [ "$kind" = scout ]; then
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
      if drift "$id" "$id ended as resolved, left alone: its work has not landed on the trunk"; then echo unlanded > "$MEM/$id.reported"; fi
    fi
    continue
  fi
  rc=0
  out=$(JG_HOME="$FMH" JG_STATE_OVERRIDE="$STATE" "$TEARDOWN" "$id" 2>&1) || rc=$?
  last=$(printf '%s\n' "$out" | grep -E '^(REFUSED|error)' | tail -n 1)
  [ -n "$last" ] || last=$(printf '%s\n' "$out" | tail -n 1)
  last=$(printf '%s' "$last" | cut -c1-200)
  case $rc in
    0)
      [ ! -f "$MEM/$lane_subject.capacity" ] || capacity_snapshot "$id" "cleanup returned success ($why)" 'verify preserved bytes and authoritative reusable slot; command success alone is not recovery'
      rm -f -- "$MEM/$id.reported" "$MEM/$id.asked"; echo "lead-sweep: $id cleaned up ($why)" ;;
    4) refuse "$id" "cleanup returned but its slot is lost; lead must repair and prove reusable capacity: $last" ;;
    *)
      [ "$(cat "$MEM/$id.reported" 2>/dev/null)" != "$last" ] || continue
      if drift "$id" "$id ($why) not cleaned up, nothing was forced: ${last:-the cleanup was refused}"; then printf '%s\n' "$last" > "$MEM/$id.reported"; fi ;;
  esac
done
exit 0

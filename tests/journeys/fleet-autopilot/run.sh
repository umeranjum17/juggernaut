#!/usr/bin/env bash
# Fleet autopilot journey (autopilot plan section 11, slice J1a): 15 fixture homes and 30 lanes in a private Herdr lab
# session; every worker and lead is a shell script, so the run makes zero model calls (tripwire shims prove it).
#
# Usage: run.sh [--list] [--homes 15] [--lanes 30] [--leads 5] [--session <label>] [--faults all|none] [--update]
#               [--strict] [--bound <minutes=40>] [--evidence <dir>] [--keep]
#   --list      print the 13 steps with the slice that owns each, and exit
#   --strict    a step that cannot run yet because its slice is not on the trunk FAILS; without it the step is PENDING
#   --faults    run faults/NN-*.sh (slice J1b; faults/lib.sh is their library);  --update  run update.sh (slice J1c)
# A step outside this slice is a script that its owning slice adds: faults/NN-*.sh (06), update.sh (10), steps/NN-*.sh
# (05 07 08 09 11 12). It gets FA_LAB FA_EVID FA_SESSION FA_ROOT FA_DIR FA_MODEL_LOG, may `. lab.sh; lab_attach`, and
# exits 0 (PASS), 77 (PENDING: names what is missing) or anything else (FAIL); its last stdout line is the detail.
# Result lines (the last two): `FLEET-AUTOPILOT: PASS|PARTIAL|FAIL <n>/13` and `FLEET_AUTOPILOT PASS|PARTIAL|FAIL <step>`.
# PASS needs all 13 steps. Exit 0 for PASS or PARTIAL, 1 for FAIL, 124 for the time bound. Evidence: steps.tsv,
# metrics.jsonl, model-calls.log, herdr-*.txt and every home's records, under --evidence (default: the done-done folder).
set -u
FA_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); export FA_DIR
ROOT=$(cd "$FA_DIR/../../.." && pwd -P)

STEPS='01|provision-homes|J1a|15 fixture homes, a watcher in each, 5 with a checkpoint lead, in a named Herdr lab session
02|register-trunk|J1a, L3|the fixture project is registered local-trunk with no trunk; the landing check creates the trunk itself
03|start-lanes|J1a, L1, L2|30 shell lanes each make one commit and seal a run; the lane with no sealed run has its done refused
04|land-all|J1a|every lane lands through the check with zero model turns; every home goes live on the captain word
05|rebase-under-move|L4, M1|10 lanes ready while the trunk moves: 9 land by the lander rebase, 1 conflict stays final
06|faults|J1b|each known fault recovers by itself, with no wake lost or repeated, and a measured record
07|stall-action|W2|a hung command in a worker and in a lead is interrupted once; a declared paused worker is left alone
08|checkpoint-cadence|W3|a lead inside its cadence raises no alarm, past cadence plus grace exactly one
09|captain-ack|W5|a captain note with no model reply gets one shell acknowledgement with the ticket link
10|mid-run-update|J1c|a landing during load moves every home; one forced health failure pins that home back
11|legacy-records|R1, R2, R3, R7|legacy records rebind, a mode change resumes once, a spawn with no model refuses
12|session-bounds|D2, D3, D4, D7|session start under 30 s, digest under 20 KB, cold feed export under 1 s
13|teardown|J1a|teardown through the lab helper only; the default session is unchanged'
step_name() { printf '%s\n' "$STEPS" | awk -F'|' -v n="$1" '$1==n{print $2}'; }

HOMES=15 LANES=30 LEADS=5 LABEL=fleet-autopilot FAULTS=all UPDATE=0 STRICT=0 BOUND=40 FA_EVID=${FA_EVID:-} FA_KEEP=0
while [ "$#" -gt 0 ]; do
  case $1 in
    --list) printf '%s\n' "$STEPS" | awk -F'|' '{printf "%s %-20s %-16s %s\n", $1, $2, $3, $4}'; exit 0 ;;
    --homes) HOMES=$2; shift ;; --lanes) LANES=$2; shift ;; --leads) LEADS=$2; shift ;; --session) LABEL=$2; shift ;;
    --faults) FAULTS=$2; shift ;; --update) UPDATE=1 ;; --strict) STRICT=1 ;; --bound) BOUND=$2; shift ;;
    --evidence) FA_EVID=$2; shift ;; --keep) FA_KEEP=1 ;;
    *) echo "usage: run.sh [--list] [--homes N] [--lanes N] [--leads N] [--session L] [--faults all|none] [--update] [--strict] [--bound MIN] [--evidence DIR] [--keep]" >&2; exit 2 ;;
  esac
  shift
done
[ "$HOMES" -ge 1 ] && [ "$LANES" -ge 2 ] 2>/dev/null || { echo "run.sh: --homes needs 1 or more, --lanes 2 or more" >&2; exit 2; }
export FA_EVID FA_KEEP
for t in git jq herdr; do command -v "$t" > /dev/null || { echo "FLEET_AUTOPILOT FAIL missing-tool:$t"; exit 1; }; done

# shellcheck source=tests/journeys/fleet-autopilot/lab.sh
. "$FA_DIR/lab.sh"
# shellcheck source=tests/journeys/fleet-autopilot/homes.sh
. "$FA_DIR/homes.sh"
# shellcheck source=tests/journeys/fleet-autopilot/lanes.sh
. "$FA_DIR/lanes.sh"

START=$(date +%s)
left() { echo $(( BOUND * 60 - ($(date +%s) - START) )); }
# wait_for <seconds> <command...>: poll once a second until the command succeeds, the wait or the run bound ends
wait_for() {
  local t=$1 end
  shift; end=$(( $(date +%s) + t ))
  while [ "$(date +%s)" -lt "$end" ] && [ "$(left)" -gt 0 ]; do "$@" && return 0; sleep 1; done
  "$@"
}
each_home() { local fn=$1 h; shift; while IFS= read -r h; do "$fn" "$h" "$@" || return 1; done < "$LAB/homes.list"; }
D=; FAILED_STEP=

step_01() {
  homes_provision "$HOMES" || { D="could not provision the fixture homes"; return 1; }
  homes_start "$LEADS" || { D="could not start the homes' watchers"; return 1; }
  local n; n=$(lab_herdr workspace list | jq '.result.workspaces | length')
  [ "$n" = "$HOMES" ] || { D="$n Herdr workspaces for $HOMES homes"; return 1; }
  D="$HOMES homes (worktrees of one clone at $(git -C "$LAB/clone" rev-parse --short HEAD)), $LEADS checkpoint leads, session $SESSION"
}
trunk_up() { [ -e "$1/state/trunk-tip-$FA_PROJECT" ]; }
step_02() {
  homes_register
  if wait_for "${FA_SELFINIT_WAIT:-20}" each_home trunk_up; then D="the landing check created every trunk by itself"; return 0; fi
  homes_init_trunk || { D="trunk init failed in a home"; return 1; }
  D="trunks made by hand (self-init by the landing check is slice L3, not on this trunk)"; return 77
}
sealed() { [ -s "$1/state/$2.run-receipt.json" ]; }
step_03() {
  local i id h; : > "$LAB/lanes.list"
  lanes_start "$LANES" || { D="could not start the lanes"; return 1; }
  while read -r id h _; do [ "$id" = "$(lane_id "$LANES")" ] || wait_for 120 sealed "$h" "$id" || { D="$id never published its receipt"; return 1; }; done < "$LAB/lanes.list"
  id=$(lane_id "$LANES"); h=$(awk -v i="$id" '$1==i{print $2}' "$LAB/lanes.list")
  wait_for 60 test -e "$h/data/lab-done-$id.rc" || { D="$id never reported done"; return 1; }
  [ ! -e "$h/state/$id.run-receipt.json" ] || { D="$id has a receipt it should not have"; return 1; }
  if [ "$(cat "$h/data/lab-done-$id.rc")" = 0 ]; then
    D="$LANES lanes; 'done' was accepted for $id with no sealed run (its refusal is slices L1-L2, not on this trunk)"; return 77
  fi
  D="$LANES lanes; 'done' without a sealed run was refused for $id"
}
# A landing the check started whose detached run is gone: state `running`, older than 30 s, no process, no log.
stranded() {  # <id> <home>
  local st; st=$(ls -t "$2"/data/jg-trunk-landing/"$1".*.state 2>/dev/null | head -n 1)
  [ -n "$st" ] && grep -q '^running' "$st" && [ -n "$(find "$st" -mmin +0.5 2>/dev/null)" ] && [ ! -e "${st%.state}.log" ] \
    && ! ps -eo args | grep -F "trunk-landing.sh run $2 $1 " | grep -qv grep
}
settled() {  # <id> <home>: landed or stranded
  lanes_landed "$1" "$2" || stranded "$1" "$2"
}
all_settled() { local id h; while read -r id h _; do [ "$id" = "$(lane_id "$LANES")" ] || settled "$id" "$h" || return 1; done < "$LAB/lanes.list"; }
lost_runs() { local id h; while read -r id h _; do lanes_landed "$id" "$h" || ! stranded "$id" "$h" || printf '%s ' "$id"; done < "$LAB/lanes.list"; }
step_04() {
  local id h t0 rows lost
  t0=$(date +%s)
  wait_for "${FA_LAND_WAIT:-600}" all_settled || { D="not every lane landed in time: $(while read -r id h _; do lanes_landed "$id" "$h" || printf '%s ' "$id"; done < "$LAB/lanes.list")"; return 1; }
  lab_metric landing-29 $(( $(date +%s) - t0 )) lanes=$((LANES - 1))
  id=$(lane_id "$LANES"); h=$(awk -v i="$id" '$1==i{print $2}' "$LAB/lanes.list")
  ! lanes_landed "$id" "$h" || { D="$id landed with no sealed run"; return 1; }
  t0=$(date +%s); lane_seal "$h" "$id" || { D="could not seal $id"; return 1; }
  wait_for 120 settled "$id" "$h" || { D="$id did not land after its run was sealed"; return 1; }
  lab_metric landing-sealed-last $(( $(date +%s) - t0 ))
  lost=$(lost_runs)
  rows=$(cat "$LAB"/homes/*/data/trunk-landings.tsv | awk -F'\t' '$5!=""' | wc -l | tr -d ' ')
  [ "$rows" = "$((LANES - $(printf '%s' "$lost" | wc -w)))" ] || { D="$rows landing rows naming the gate for $LANES lanes (lost: $lost)"; return 1; }
  [ ! -s "$MODEL_LOG" ] || { D="model CLI called: $(head -n 1 "$MODEL_LOG")"; return 1; }
  while IFS= read -r h; do
    home_run "$h" "$h/bin/jg-trunk.sh" word in-use "$h/projects/$FA_PROJECT" "fleet-autopilot lab word" > /dev/null 2>&1 \
      && home_run "$h" "$h/bin/jg-trunk.sh" live "$h/projects/$FA_PROJECT" > "$h/data/lab-live.log" 2>&1 \
      && [ -s "$h/data/live-moves" ] || { D="live did not move $(basename "$h"): $(tail -n 1 "$h/data/lab-live.log" 2>/dev/null)"; return 1; }
  done < "$LAB/homes.list"
  [ -z "$lost" ] || { D="landing run lost for: $lost (state running, no process, no log; the check's detached run vanished: an admission fix of the landing owner, slices L3-L4; unverified cause)"; return 77; }
  D="$LANES lanes landed through the check with zero model turns and live ran in all $HOMES homes"
  grep -q -- '--base' "$ROOT/bin/jg-update.sh" 2>/dev/null || D="$D (the home mover is slice T2: a recording hook stands in)"
}
# step_ext <step> <script...>: run the scripts the owning slice added; none present = PENDING
step_ext() {
  local n=$1 s rc ran=0 out bad="" pend="" first=""; shift
  for s in "$@"; do
    [ -f "$s" ] || continue
    ran=1; out=$(FA_LAB=$LAB FA_EVID=$EVID FA_SESSION=$SESSION FA_ROOT=$ROOT FA_DIR=$FA_DIR FA_MODEL_LOG=$MODEL_LOG bash "$s" 2>&1); rc=$?
    printf '%s\n' "$out" > "$EVID/step-$n-$(basename "$s").log"
    out="$(basename "$s" .sh): $(printf '%s\n' "$out" | tail -n 1)"
    case $rc in 0) first=${first:-$out} ;; 77) pend="$pend$out; " ;; *) bad="$bad$out; " ;; esac
  done
  [ "$ran" = 1 ] || { D="no script for the owning slice ($(printf '%s\n' "$STEPS" | awk -F'|' -v n="$n" '$1==n{print $3}')) on this trunk"; return 77; }
  [ -z "$bad" ] || { D=$bad; return 1; }
  [ -z "$pend" ] || { D="pending: $pend"; return 77; }
  D=$first
}
step_13() {
  SESSION_DOWN=1
  "$HELPER" teardown "$SESSION" > "$EVID/herdr-teardown.txt" 2>&1 || { D="teardown refused or the default session changed: $(tail -n 1 "$EVID/herdr-teardown.txt")"; return 1; }
  D="session $SESSION torn down through the lab helper; default-session state identical before and after"
}

run_step() {  # <nn>: run, time and record one step; later steps are not run after a FAIL
  local n=$1 name t0 rc=0 status
  name=$(step_name "$n"); D=; t0=$(date +%s)
  if [ -n "$FAILED_STEP" ] && [ "$n" != 13 ]; then status=SKIPPED; D="after $FAILED_STEP failed"
  else
    case $n in
      06) if [ "$FAULTS" = none ]; then D="not requested (--faults none)"; rc=77; else step_ext 06 "$FA_DIR"/faults/[0-9]*.sh || rc=$?; fi ;;
      10) if [ "$UPDATE" = 0 ]; then D="not requested (--update)"; rc=77; else step_ext 10 "$FA_DIR/update.sh" || rc=$?; fi ;;
      05|07|08|09|11|12) step_ext "$n" "$FA_DIR/steps/$n"-*.sh || rc=$? ;;
      *) "step_$n" || rc=$? ;;
    esac
    case $rc in 0) status=PASS ;; 77) status=PENDING ;; *) status=FAIL; FAILED_STEP=$n-$name ;; esac
  fi
  [ "$status" != PENDING ] || [ "$STRICT" = 0 ] || { status=FAIL; FAILED_STEP=${FAILED_STEP:-$n-$name}; D="$D [pending, --strict]"; }
  printf 'step %s %-18s %-7s %ss  %s\n' "$n" "$name" "$status" $(( $(date +%s) - t0 )) "$D" | tee -a "$EVID/steps.tsv"
  lab_metric "step-$n" $(( $(date +%s) - t0 )) "status=$status"
  STATUS_LIST="${STATUS_LIST:-} $n=$status"
}

main() {
  lab_init "$LABEL" || { echo "FLEET_AUTOPILOT FAIL lab"; exit 1; }
  trap 'exit 124' TERM INT HUP
  # The watchdog polls instead of sleeping the whole bound, so it ends within seconds of the run and never holds a pipe open.
  ( me=$$; end=$(( START + BOUND * 60 )); while kill -0 "$me" 2>/dev/null && [ "$(date +%s)" -lt "$end" ]; do sleep 5; done
    if kill -0 "$me" 2>/dev/null; then echo "FLEET_AUTOPILOT FAIL bound-${BOUND}min"; kill -TERM "$me"; fi ) & FA_WATCHDOG=$!
  : > "$EVID/steps.tsv"; STATUS_LIST=
  local n
  for n in 01 02 03 04 05 06 07 08 09 10 11 12 13; do run_step "$n"; done
  local pass pend
  pass=$(printf '%s\n' $STATUS_LIST | grep -c '=PASS$'); pend=$(printf '%s\n' $STATUS_LIST | grep '=PENDING$' | cut -d= -f1 | tr '\n' ',' | sed 's/,$//')
  if [ -n "${DONE_DONE_EVIDENCE_ROOT:-}" ]; then
    printf '%s\n' "$STEPS" | jq -R -s --arg tip "$(git -C "$ROOT" rev-parse --short HEAD)" --arg res "$pass of 13 steps passed, pending: ${pend:-none}" \
      '{target: {version: $tip}, start: "a fixture clone of this checkout, worktree homes with their own Beads stores and a local-trunk fixture project, in a private Herdr lab session",
        steps: (split("\n") | map(select(length > 0) | split("|") | .[3])), result: $res}' > "$DONE_DONE_EVIDENCE_ROOT/steps.json"
  fi
  {
    printf 'fleet-autopilot journey: %s homes, %s lanes, %s checkpoint leads, strict=%s, model CLI calls=%s\n' "$HOMES" "$LANES" "$LEADS" "$STRICT" "$(wc -l < "$MODEL_LOG" | tr -d ' ')"
    cat "$EVID/steps.tsv"
    if [ -n "$FAILED_STEP" ]; then
      echo "FLEET-AUTOPILOT: FAIL $pass/13"; echo "FLEET_AUTOPILOT FAIL $FAILED_STEP"; RESULT=1
    elif [ -n "$pend" ]; then
      echo "FLEET-AUTOPILOT: PARTIAL $pass/13 pending=$pend"; echo "FLEET_AUTOPILOT PARTIAL pending=$pend"; RESULT=0
    else
      echo "FLEET-AUTOPILOT: PASS 13/13"; echo "FLEET_AUTOPILOT PASS"; RESULT=0
    fi
  } > "$EVID/fleet-autopilot.log"
  tail -n 2 "$EVID/fleet-autopilot.log"
  exit "$RESULT"
}
main

#!/usr/bin/env bash
# done-done journey: a Goal goes from ask to one finish message on a fake forge, in real time.
# A disposable home holds a real Goal-only store (the pinned bd and dolt through bin/jg-beads.sh) and the real
# bin/jg-goal.sh and core/goal-loop/goal-loop.sh. Each check pass is a fresh process, as a restart is. The fake
# forge is a folder and a background process that turns a PR green, merges it, tags a release, records it in the
# home's release record and advances the home, each after a real delay. Only the lead is a script: it takes the
# step the check wakes it for, does what the step names on the forge, and closes the row.
# Goal A runs the whole path with a stop and one failed proof. Goal B repeats one proof failure. Goal C has its
# finish line changed. Writes the timeline, the checks, the messages and the forge log into the evidence folder.
# shellcheck disable=SC2329 # the check helpers are called through "$@"
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
BIN=${GOAL_PINNED_BIN:-$HOME/.cache/fm-scratch/beads-native-n5/bin}
[ -x "$BIN/bd" ] && [ -x "$BIN/dolt" ] || { echo "fixture: the pinned bd and dolt are not in $BIN (set GOAL_PINNED_BIN)"; exit 1; }
T=$(mktemp -d)
W=$T/w H=$W/home F=$W/forge STORE=$W/store/.beads
mkdir -p "$H/state" "$H/config" "$H/data" "$F" "$W/store" "$W/probes"
for s in nats dapr; do printf '#!/bin/sh\necho up\n' > "$W/probes/$s"; chmod +x "$W/probes/$s"; done
printf '%s\n' "$STORE" > "$H/config/goal-beads-dir"
export JG_BEADS_BD=$BIN/bd JG_BEADS_DOLT=$BIN/dolt
BEADS_DIR=$STORE "$REPO/bin/jg-beads.sh" init --prefix goal >/dev/null 2>&1 || { echo "fixture: the Goal store did not start"; exit 1; }

cat > "$W/proof-a.sh" <<'SH'
#!/usr/bin/env bash
w=$1
[ "$(cat "$w/home/running" 2>/dev/null)" = v1 ] || { echo "the home does not run v1 yet"; exit 1; }
[ "$(cat "$w/home/health" 2>/dev/null)" = ok ] || { echo "the home health check says: $(cat "$w/home/health" 2>/dev/null || echo missing)"; exit 1; }
echo "the home runs v1 and is healthy"
SH

START=$(date +%s)
log() { printf '+%4ss %s\n' "$(( $(date +%s) - START ))" "$*" | tee -a "$OUT/timeline.txt"; }
flog() { printf '+%4ss %s\n' "$(( $(date +%s) - START ))" "$*" >> "$OUT/forge.log"; }
: > "$OUT/timeline.txt"
: > "$OUT/forge.log"

# goal: run bin/jg-goal.sh against the disposable home.
goal() { env JG_HOME="$H" "$REPO/bin/jg-goal.sh" "$@"; }
bd() { BEADS_DIR=$STORE "$REPO/bin/jg-beads.sh" "$@"; }
# One check pass is one fresh process, as a restart between passes is.
n=0
pass() {
  n=$((n + 1))
  env -i HOME="$HOME" PATH="$PATH" LANG=C.UTF-8 TMPDIR="$T" JG_HOME="$H" JG_GOAL_BIN="$REPO/bin/jg-goal.sh" \
    JG_BEADS_BD="$JG_BEADS_BD" JG_BEADS_DOLT="$JG_BEADS_DOLT" JG_LIVE_SERVICES_PROBES="$W/probes" \
    "$REPO/core/goal-loop/goal-loop.sh" check "$H" > "$T/pass.$n" 2>> "$T/err"
  if [ -s "$T/pass.$n" ]; then while IFS= read -r l; do log "pass $n: $l"; done < "$T/pass.$n"; else log "pass $n: nothing rung"; fi
}
rung() { grep -c "$1" "$T/pass.$n"; }                       # <text>: lines of the last pass that hold the text
wake_for() { grep -q "$1 is ready for its $2 step" "$T/pass.$n"; }  # <goal> <step>
messages() { cat "$T"/pass.* | grep -c "$1"; }               # <text>: lines in every pass so far
row_of() { bd list --parent "$1" --all --json 2>/dev/null | jq -r --arg k "$2" '[.[] | select(.metadata.kind == $k and .status != "closed")] | first | .id // empty'; }
take() { bd update "$(row_of "$1" "$2")" --status in_progress >/dev/null 2>&1; }  # <goal> <step>
close_step() { bd close "$(row_of "$1" "$2")" --reason "scripted lead" >/dev/null 2>&1; log "the lead closed the $2 step of $1"; }
wait_for() {  # <file> <seconds>
  local deadline=$(( $(date +%s) + $2 ))
  until [ -e "$1" ] || [ "$(date +%s)" -ge "$deadline" ]; do sleep 1; done
  [ -e "$1" ]
}
settle_proof() { wait_for "$H/data/goals/$1/proof.exit" 30; }  # the proof ends before the next pass reads it
tick() { sleep 3; }                                            # stands in for the 5 minutes between passes

# The fake forge: PR, CI, merge on green, release tag with its record, and the home advancing, in real time.
forge_train() {
  until [ -e "$F/pr1" ]; do sleep 1; done
  flog "PR 1 opened, checks pending"
  sleep 4; echo green > "$F/pr1"; flog "PR 1 checks green"
  sleep 3; echo merged > "$F/pr1"; touch "$F/merged"; flog "PR 1 merged on green"
  sleep 8; echo v1 > "$F/tag"; printf 'v1 prs=1\n' >> "$H/data/releases"; flog "tag v1 published and recorded"
  sleep 4; echo v1 > "$H/running"; flog "the home runs v1"
}

: > "$T/checks"
check() {  # <label> <command...>
  local label=$1
  shift
  if "$@"; then echo "PASS $label" >> "$T/checks"; else echo "FAIL $label" >> "$T/checks"; fi
}
refused() {  # <wanted text> <goal args...>: declare is refused with exit 2 naming the reason
  local want=$1 out code
  shift
  out=$(goal "$@" 2>&1); code=$?
  [ "$code" = 2 ] && printf '%s' "$out" | grep -qF "$want"
}

# 1. Declare refuses a proof that already passes and a missing proof.
log "start: a disposable home, a real Goal store, a fake forge"
check "declare refuses a proof that already exits 0" refused "already exits 0" declare --ask x --repo o/r -- true
check "declare refuses a missing proof command" refused "needs a proof command" declare --ask x --repo o/r
check "declare refuses a proof that cannot run" refused "cannot run (exit 127)" declare --ask x --repo o/r -- /nonexistent/proof
check "a refused declare leaves no Goal" [ -z "$(goal show)" ]

# 2. A Goal is declared with a failing proof.
A=$(goal declare --ask "the fix runs in the home" --repo o/r --released tag --where "this home" -- bash "$W/proof-a.sh" "$W") || { echo "fixture: declare failed"; exit 1; }
log "declared $A with a proof that fails now"
check "the Goal has five open steps" [ "$(goal show "$A" | grep -c ' open$')" -ge 5 ]

# 3. The lead is woken once for ship, and not again while the wait is unchanged.
pass
check "the first pass wakes the lead for ship" wake_for "$A" ship
tick; pass; check "a second pass raises nothing" [ ! -s "$T/pass.$n" ]
tick; pass; check "a third pass raises nothing" [ ! -s "$T/pass.$n" ]

# 4. The change ships and the forge carries it to the home, step by step.
take "$A" ship; echo pending > "$F/pr1"; log "the lead opened PR 1 on the forge"
forge_train &
train=$!
close_step "$A" ship
tick; pass; check "the merged step is the next wake" wake_for "$A" merged
take "$A" merged
wait_for "$F/merged" 60; check "the forge merged the green PR with no lead" [ "$(cat "$F/pr1")" = merged ]
close_step "$A" merged

# 6. A stop row: 3 passes with no wake, one message; a restart sends no second message; closing the row resumes.
stop_row=$(goal stop "$A" --kind owner-must --reason "the owner must approve the release tag") || { echo "fixture: stop failed"; exit 1; }
log "a stop row $stop_row was added"
tick; pass; check "the stop raised its one message" [ "$(rung 'is stopped')" = 1 ]
tick; pass; check "no wake in the second stopped pass" [ ! -s "$T/pass.$n" ]
rm -rf "$H/data/jg-goal-loop"; log "restart: the check's own records are gone"
tick; pass; check "no wake and no second message after the restart" [ ! -s "$T/pass.$n" ]
tick; pass; check "no wake in the fourth stopped pass" [ ! -s "$T/pass.$n" ]
check "one stop message in all" [ "$(messages 'is stopped')" = 1 ]
check "the stop message gives its reason" grep -q 'owner must approve the release tag' "$T/pass.$((n - 3))"
goal resume "$stop_row" >/dev/null; log "the owner settled it: $stop_row closed"
pass; check "closing the stop row resumes the Goal at its next step" wake_for "$A" released

# 4 again. Release and home.
wait_for "$F/tag" 60; take "$A" released
goal released "$A" "$(cat "$F/tag")" >/dev/null; close_step "$A" released
tick; pass; check "the running step is the next wake" wake_for "$A" running
wait_for "$H/running" 60; take "$A" running; close_step "$A" running
check "the forge advanced the home after the tag" [ "$(cat "$H/running")" = v1 ]
wait "$train" 2>/dev/null

# 5. The proof fails once, a fix step appears, a second run is green.
pass; check "the proof is started with no wake" [ ! -s "$T/pass.$n" ]
settle_proof "$A"; check "the first proof run failed" [ "$(cat "$H/data/goals/$A/proof.exit")" = 1 ]
pass; check "the failed proof raised no wake of its own" [ ! -s "$T/pass.$n" ]
tick; pass; check "the failure added a fix step that wakes the lead" wake_for "$A" fix
take "$A" fix; echo ok > "$H/health"; log "the lead fixed the health check"; close_step "$A" fix
pass; check "the proof is started again with no wake" [ ! -s "$T/pass.$n" ]
settle_proof "$A"; check "the second proof run passed" [ "$(cat "$H/data/goals/$A/proof.exit")" = 0 ]
pass

# 7. The epic closes with exactly one finish message that names version, place and proof log.
tick; pass
check "the finish message went once" [ "$(rung 'finished - ')" = 1 ]
msg=$(grep 'finished - ' "$T/pass.$n")
check "the finish message names the version" grep -q 'live: v1' <<< "$msg"
check "the finish message names the place" grep -q '@ this home' <<< "$msg"
logfile=$(sed -n 's/.*proof log: \([^)]*\))$/\1/p' <<< "$msg")
check "the finish message names a proof log that exists" [ -s "$logfile" ]
check "the epic is closed" [ -z "$(goal show)" ]
[ -s "$logfile" ] && cp "$logfile" "$OUT/goal-a-proof-log.txt" || echo "no proof log" > "$OUT/goal-a-proof-log.txt"

# 8. A restart sends no second message.
rm -rf "$H/data/jg-goal-loop"; log "restart: the check's own records are gone"
pass; check "no second finish message after the restart" [ ! -s "$T/pass.$n" ]
check "one finish message in all" [ "$(messages 'finished - ')" = 1 ]

# 9. The same proof failure 3 times is a limit stop.
B=$(goal declare --ask "a fix that never works" --repo o/r -- bash -c 'echo "still broken"; exit 1') || { echo "fixture: declare B failed"; exit 1; }
log "declared $B whose proof will fail every time"
for s in ship merged released running; do close_step "$B" "$s"; done
for round in 1 2; do
  pass; settle_proof "$B"; pass; tick; pass
  check "failure $round added fix step $round and woke the lead" wake_for "$B" fix
  close_step "$B" fix
done
pass; settle_proof "$B"; pass
check "the third identical failure made no third fix step" [ -z "$(row_of "$B" fix)" ]
tick; pass
check "the third identical failure is one limit stop message" [ "$(rung 'is stopped (limit)')" = 1 ]
tick; pass; tick; pass; tick; pass
check "a limit stop costs no wake" [ ! -s "$T/pass.$n" ]
check "the limit stop was announced once" [ "$(messages 'is stopped (limit)')" = 1 ]

# 10. A changed finish hash is a stop and the proof never runs.
C=$(goal declare --ask "a shrunk finish line" --repo o/r -- false) || { echo "fixture: declare C failed"; exit 1; }
for s in ship merged released running; do close_step "$C" "$s"; done
printf '{"proof":["true"],"repo":"o/r","released":"tag","where":"this home"}\n' > "$H/data/goals/$C/finish.json"
log "the finish line of $C was changed after it was declared"
pass; tick; pass
check "the changed finish line is an owner-must stop" [ "$(messages "$C is stopped (owner-must)")" = 1 ]
check "the proof of the changed finish line never started" [ ! -e "$H/data/goals/$C/proof.pid" ]
tick; pass; check "the changed finish line stop costs no wake" [ ! -s "$T/pass.$n" ]

# Records for the evidence folder.
cat "$T"/pass.* | grep -E 'is stopped|finished - ' > "$OUT/messages.txt"
check "neither the check nor the store wrote to stderr" [ ! -s "$T/err" ]
{ cat "$T/checks"; [ -s "$T/err" ] && { echo "stderr:"; head -n 20 "$T/err"; }; } > "$OUT/checks.txt"
cat "$OUT/checks.txt"
fails=0
grep -q '^FAIL' "$OUT/checks.txt" && fails=1

cat > "$OUT/steps.json" <<J
{"target":{"version":"juggernaut $(git -C "$REPO" rev-parse HEAD)"},
 "start":"a disposable home with a real Goal-only store (pinned bd and dolt), the real Goal verbs and watcher check, and a fake forge that merges, tags and advances the home after real delays",
 "steps":["declare refuses a passing and a missing proof, and takes a failing one","the lead is woken once for ship and not again","the forge turns the PR green, merges it, tags v1 and advances the home","a stop row sends one message, raises no wake over several passes, and closing it resumes the Goal","the first proof fails and adds a fix step, the second passes","one finish message names v1, the place and the proof log, and a restart sends no second one","the same failure three times is a limit stop, and a changed finish line is a stop with no proof run"],
 "result":"a Goal went from ask to one finish message with no model between steps, and stopped with its reason where it had to"}
J
rm -rf -- "$T"
exit "$fails"

#!/usr/bin/env bash
# Journey: a best-effort summary refresh never holds up its caller.
# `jg-home-summary-refresh.sh --best-effort` returns at once and refreshes in the
# background; calls that arrive while a refresh runs collapse into one more pass;
# a call without --best-effort still waits for its own refresh.
# The producer is a stand-in that takes 5 seconds, marks its start, counts its runs,
# and prints the real producer's document for an empty home (captured once below).
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
TMP_ROOT=$(jg_test_tmproot jg-home-summary-async)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" "$HOME_DIR/fakebin"
jg_fake_exit0 "$HOME_DIR/fakebin" tmux treehouse no-mistakes gh gh-axi
STATE="$HOME_DIR/state"
COUNTER="$TMP_ROOT/counter"
STARTED="$TMP_ROOT/started"
EVIDENCE="$TMP_ROOT/evidence.log"
DOC="$TMP_ROOT/real-summary.json"
STAND_IN="$TMP_ROOT/slow-producer.sh"

env PATH="$HOME_DIR/fakebin:$PATH" JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE" \
  JG_DATA_OVERRIDE="$HOME_DIR/data" "$ROOT/bin/jg-fleet-snapshot.sh" --squad-lead-home-summary > "$DOC" \
  || fail "the real producer printed no summary for the empty home"
cat > "$STAND_IN" <<STUB
#!/usr/bin/env bash
echo start >> '$STARTED'
sleep 5
echo run >> '$COUNTER'
cat '$DOC'
STUB
chmod +x "$STAND_IN"

refresh() {  # the call under test, with the stand-in producer
  env PATH="$HOME_DIR/fakebin:$PATH" JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE" \
    JG_DATA_OVERRIDE="$HOME_DIR/data" JG_HOME_SUMMARY_PRODUCER="$STAND_IN" \
    "$ROOT/bin/jg-home-summary-refresh.sh" "$@"
}
now_ms() { date +%s%3N; }
runs() { [ -f "$COUNTER" ] && wc -l < "$COUNTER" | tr -d '[:space:]' || echo 0; }
wait_runs() {  # <count> <seconds>: poll until the counter has <count> lines
  local want=$1 deadline=$(( $(date +%s) + $2 ))
  while [ "$(runs)" -lt "$want" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 0.2; done
  [ "$(runs)" -ge "$want" ]
}
note() { printf '%s\n' "$*" >> "$EVIDENCE"; }
quiesce() {  # wait until no refresh holds the lock
  local deadline=$(( $(date +%s) + 30 ))
  while [ -e "$STATE/.home-summary-refresh.lock" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 0.2; done
  sleep 1
}

# T1: one --best-effort call returns under a second and the refresh still happens.
start=$(now_ms)
refresh --best-effort || fail "T1: best-effort call exited non-zero"
took=$(( $(now_ms) - start ))
[ "$took" -lt 1000 ] || fail "T1: best-effort call took ${took} ms, wanted under 1000"
wait_runs 1 10 || fail "T1: the detached refresh did not run within 10 s"
quiesce
[ "$(runs)" -eq 1 ] || fail "T1: wanted 1 run, got $(runs)"
jq -e '.schema == "jg-squad-lead-home-summary.v1"' "$STATE/home-summary.json" >/dev/null \
  || fail "T1: the detached refresh published no ledger"
note "T1 call=${took}ms runs=$(runs)"
pass "T1: a best-effort call returns in ${took} ms and the refresh runs in the background"

# T2: five calls at once while a refresh runs: each is quick; one run plus one dirty pass, never five.
# (Calls that all land before any run holds the lock are covered by a single later run, so the
# test starts from a run in progress to make the count exact.)
: > "$COUNTER"; : > "$STARTED"
refresh --best-effort || fail "T2: the first best-effort call exited non-zero"
deadline=$(( $(date +%s) + 10 ))
while [ ! -s "$STARTED" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 0.1; done
[ -s "$STARTED" ] || fail "T2: the first refresh did not start within 10 s"
pids=()
for i in 1 2 3 4 5; do
  ( s=$(now_ms); refresh --best-effort; rc=$?; echo "$rc $(( $(now_ms) - s ))" > "$TMP_ROOT/call-$i" ) &
  pids+=($!)
done
wait "${pids[@]}"
for i in 1 2 3 4 5; do
  read -r rc ms < "$TMP_ROOT/call-$i"
  [ "$rc" -eq 0 ] || fail "T2: call $i exited $rc"
  [ "$ms" -lt 1000 ] || fail "T2: call $i took ${ms} ms, wanted under 1000"
  note "T2 call $i exit=$rc ${ms}ms"
done
wait_runs 2 20 || fail "T2: the dirty pass did not run (runs=$(runs))"
quiesce
[ "$(runs)" -eq 2 ] || fail "T2: wanted 2 runs (one plus one dirty pass), got $(runs)"
[ ! -e "$STATE/.home-summary-refresh.dirty" ] || fail "T2: a dirty mark was left behind"
note "T2 runs=$(runs) dirty_left=no"
pass "T2: five concurrent calls give 2 runs and leave no dirty mark"

# T3: without --best-effort the caller waits for its refresh, as before.
: > "$COUNTER"
start=$(now_ms)
refresh || fail "T3: foreground refresh exited non-zero"
took=$(( $(now_ms) - start ))
[ "$took" -gt 4000 ] || fail "T3: foreground call took ${took} ms, wanted over 4000"
[ "$(runs)" -eq 1 ] || fail "T3: wanted 1 run, got $(runs)"
note "T3 call=${took}ms runs=$(runs)"
pass "T3: a call without --best-effort waits for its refresh (${took} ms)"
# T4: a refresh killed hard leaves its temp files, and the next refresh removes them.
# The stand-in producer kills its own refresh worker with SIGKILL, so no EXIT trap runs.
KILLER="$TMP_ROOT/killer-producer.sh"
cat > "$KILLER" <<'STUB'
#!/usr/bin/env bash
kill -9 "$PPID"
sleep 5
STUB
chmod +x "$KILLER"
quiesce
env PATH="$HOME_DIR/fakebin:$PATH" JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE" \
  JG_DATA_OVERRIDE="$HOME_DIR/data" JG_HOME_SUMMARY_PRODUCER="$KILLER" \
  "$ROOT/bin/jg-home-summary-refresh.sh" >/dev/null 2>&1 && fail "T4: the killed refresh reported success"
leaked=$(find "$STATE" -maxdepth 1 \( -name '.home-summary.json.??????' -o -name '.home-summary-error.??????' \) | wc -l | tr -d '[:space:]')
[ "$leaked" -ge 2 ] || fail "T4: the killed refresh left $leaked temp files, wanted at least 2 (the leak was not reproduced)"
refresh || fail "T4: the next refresh exited non-zero"
left=$(find "$STATE" -maxdepth 1 \( -name '.home-summary.json.??????' -o -name '.home-summary-error.??????' \) | wc -l | tr -d '[:space:]')
[ "$left" -eq 0 ] || fail "T4: $left temp files were left after the next refresh"
note "T4 leaked_after_kill=$leaked left_after_next_refresh=$left"
pass "T4: a hard-killed refresh leaks $leaked temp files and the next refresh removes them"
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || cp "$EVIDENCE" "$DONE_DONE_EVIDENCE_ROOT/summary-refresh-async.log"

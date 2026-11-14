#!/usr/bin/env bash
# Behavior test for the worker table (core/machines/tables/worker.tsv): one agent session of a lane has 6 states.
# The table lints clean (rule of section 6.12 of the state-machine plan). A fixture record in every state prints the right word
# through the real jg-machine.sh and the real observer; crew state is a stand-in in the fixture home, so one file sets each word.
# A legal move adds no line to the shadow log, and an illegal move adds exactly one.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JM="$ROOT/bin/jg-machine.sh"
T=$(jg_test_tmproot jg-machine-worker); H=$T/home; S=$H/state
mkdir -p "$S" "$H/crew" "$H/data" "$H/bin"
for f in "$ROOT"/bin/*; do ln -s "$f" "$H/bin/"; done
ln -sn "$ROOT/core" "$H/core"
rm "$H/bin/jg-crew-state.sh"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "state: %%s · source: none · fixture\\n" "$(cat "$JG_HOME/crew/$1" 2>/dev/null || echo unknown)"\n' > "$H/bin/jg-crew-state.sh"; chmod +x "$H/bin/jg-crew-state.sh"
unset JG_MACHINES_TABLES
export JG_HOME="$H" JG_STATE_OVERRIDE="$S" JG_DATA_OVERRIDE="$H/data"
jm() { OUT=$(bash "$JM" "$@" 2>&1); RC=$?; }
state_of() { jm show worker "$1"; printf '%s\n' "$OUT" | awk -F'\t' '$1=="state"{print $2}'; }
seed() {  # <id> <meta: yes|no> <status line|-> <crew word>
  [ "$2" = no ] || printf 'kind=ship\nwindow=sess:jg-%s\n' "$1" > "$S/$1.meta"
  [ "$3" = - ] || printf '%s\n' "$3" > "$S/$1.status"
  printf '%s' "$4" > "$H/crew/$1"
}

# 1. The table lints clean: 6 states, 11 moves, and the enum file has the same six values.
jm check worker; expect_code 0 "$RC" "the table lints"; assert_equals "ok worker: 6 states, 16 edges" "$OUT" "lint golden"
assert_equals "starting working waiting done lost exited" "$(awk -F'\t' '$1=="state"{printf "%s ", $2}' "$ROOT/core/machines/tables/worker.tsv" | sed 's/ $//')" "the six states"
jm enum worker; expect_code 0 "$RC" "the enum lints"; assert_contains "$OUT" 6 "six values"
jm coverage worker; expect_code 0 "$RC" "every edge names its test"
pass "the worker table lints with 6 states and 11 moves, each with a test"

# 2. A fixture record in every state prints the right word.
seed w-start yes - unknown
seed w-work yes 'working [at=1]: x' working
for w in parked paused blocked; do seed "w-$w" yes "$w [at=1]: x" "$w"; done
seed w-done yes 'done [at=1]: ready' "done"
seed w-lost yes 'working [at=1]: x' unknown
seed w-failed yes 'failed [at=1]: x' failed
seed w-exit no 'done [at=1]: ready' "done"
for r in w-start w-work w-parked w-paused w-blocked w-done w-lost w-failed w-exit; do echo "show worker $r -> $(state_of "$r")"; done  # the log shows each fixture and its word
assert_equals starting "$(state_of w-start)" "a session that has not spoken"
assert_equals working "$(state_of w-work)" "a working session"
for w in parked paused blocked; do assert_equals waiting "$(state_of "w-$w")" "a $w session waits"; done
assert_equals "done" "$(state_of w-done)" "a session that reported done"
assert_equals lost "$(state_of w-lost)" "a session with no sign of life"
assert_equals lost "$(state_of w-failed)" "a failed line carries the health word lost"
assert_equals exited "$(state_of w-exit)" "a session whose meta is gone"
jm show worker w-nothing; expect_code 1 "$RC" "no record, no state"
jm next worker w-lost; assert_contains "$OUT" "relaunch" "a lost session offers relaunch"; assert_contains "$OUT" "abandon" "a lost session offers abandon"
jm next worker w-exit; assert_contains "$OUT" $'moves\t0' "an exited session has no move"
pass "a fixture record in every state prints the right word"

# 3. The shadow log: a legal move adds no line, an illegal one adds exactly one, and the writer carries on.
LOG=$H/data/machine-shadow.log
lines() { [ -f "$LOG" ] && wc -l < "$LOG" || echo 0; }
shadow() { local b; b=$(lines); bash "$H/bin/jg-machine-shadow.sh" worker "$1" "$2" || fail "the shadow helper must always exit 0"; echo $(( $(lines) - b )); }
echo "shadow log before: $(lines) lines"
assert_equals 0 "$(shadow w-start working)" "starting -> working is legal"
assert_equals 0 "$(shadow w-work waiting)" "working -> waiting is legal"
assert_equals 0 "$(shadow w-work "done")" "working -> done is legal"
assert_equals 0 "$(shadow w-done working)" "done -> working is legal"
assert_equals 0 "$(shadow w-lost starting)" "lost -> starting is legal"
assert_equals 0 "$(shadow w-lost exited)" "lost -> exited is legal"
assert_equals 0 "$(shadow w-parked exited)" "waiting -> exited is legal"
echo "shadow log after the seven legal moves: $(lines) lines"
assert_equals 1 "$(shadow w-work starting)" "working -> starting is illegal"
assert_contains "$(tail -n 1 "$LOG")" worker "the shadow line names the machine"
assert_equals 1 "$(shadow w-exit working)" "an exited session has no move"
pass "a legal move adds no shadow line, an illegal move adds one"
echo "shadow log after two illegal moves: $(lines) lines, the last: $(tail -n 1 "$LOG" | cut -f2-5)"

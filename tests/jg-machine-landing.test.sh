#!/usr/bin/env bash
# Behavior tests for the landing machine table (core/machines/tables).
# Every record is generated here by a seed function in the shape its writer prints; no fleet record is copied.
# The table is report-only: `show` and `check` print findings and nothing in the landing chain calls them.
# The landing run (9 states, 13 moves, observer core/machines/observers/landing.sh): a fixture record in every state prints the right word,
# the table lints, and a legal move adds no line to the shadow log. The last journey drives the start of a landing run from the host tick
# (core/sentinel/bin/jg-sentinel.sh, through bin/jg-delivery-tick.sh) in a tests/jg-trunk-fixture.sh world: real git, the real lander, a stub Herdr with no server.
set -u
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

JM="$ROOT/bin/jg-machine.sh"
T=$(jg_test_tmproot jg-machine-landing)
export JG_HOME="$T/home"
M=$JG_HOME/data/jg-trunk-landing; S=$JG_HOME/state
mkdir -p "$M" "$S"
tab() { local IFS=$'\t'; printf '%s\n' "$*"; }
jm() { OUT=$(bash "$JM" "$@" 2>&1); RC=$?; }
rep() { printf "$1%.0s" $(seq "$2"); }
H=$(rep a 40); X=$(rep b 40); NOW=$(date +%s)

jm check landing; expect_code 0 "$RC" "the landing table lints"; assert_equals "ok landing: 9 states, 13 edges" "$OUT" "lint golden"
jm enum landing; expect_code 0 "$RC" "the enum lints"; assert_contains "$OUT" 9 "nine values"
jm coverage landing; expect_code 0 "$RC" "every edge names its test"
assert_equals "queued rebasing resolving retesting checking retrying landed returned withdrawn" \
  "$(awk -F'\t' '$1=="state"{printf "%s ", $2}' "$ROOT/core/machines/tables/landing.tsv" | sed 's/ $//')" "the nine states"
pass "the landing table lints with 9 states and 13 moves, each with a test"

# A fixture record in every state prints the right word through the real jg-machine.sh and the real observer. The records are the
# lander's state line, the conflict run's rows (data/trunk-resolving.tsv) and the phase rows of lane_admit (data/trunk-landing-phases.tsv).
G=$T/proj; git init -q -b main "$G"; git -C "$G" -c user.name=t -c user.email=t@x commit -q --allow-empty -m one
git -C "$G" branch fm/lane-moved; NEW=$(git -C "$G" -c user.name=t -c user.email=t@x commit-tree "HEAD^{tree}" -p HEAD -m two); git -C "$G" update-ref refs/heads/fm/lane-moved "$NEW"
printf 'project=%s\nbranch=fm/lane-moved\n' "$G" > "$S/lane-moved.meta"
printf 'project=%s\nbranch=fm/lane-here\n' "$G" > "$S/lane-here.meta"; git -C "$G" branch fm/lane-here; HERE=$(git -C "$G" rev-parse fm/lane-here)
seed_land() { printf '%s\n' "$2" > "$M/$1.state"; }  # <file stem> <content as the writer prints it>
phase_row() { tab "$1" proj "$H" "${3:-$H}" "$2" "$(date +%s)" "" >> "$JG_HOME/data/${4:-trunk-resolving.tsv}"; }  # <task> <state> [lane commit] [file]
word_of() {  # the state word `show` found, or the word the observer printed when it found none
  jm show landing "$1"
  if [ "$RC" -eq 0 ]; then printf '%s\n' "$OUT" | awk -F'\t' '$1 == "state" { print $2 }'
  else printf '%s\n' "$OUT" | sed -n "s/.*observer printed '\(.*\)'.*/\1/p"; fi
}
seed_land "q-wait.$H" "wait REFUSED: linked to a decision"; seed_land "q-wait2.$H.$X" "wait 0 REFUSED: away mode"
seed_land "run-reb.$H" "running $NOW 4242"
seed_land "run-res.$H" "running $NOW 4242"; phase_row run-res resolving
seed_land "run-ret.$H" "running $NOW 4242"; phase_row run-ret resolving; phase_row run-ret resolved
seed_land "run-chk.$H" "running $NOW"; phase_row run-chk resolving; phase_row run-chk resolved; phase_row run-chk checking "" trunk-landing-phases.tsv
seed_land "run-chk2.$H" "running $NOW 4242"; phase_row run-chk2 checking "" trunk-landing-phases.tsv
seed_land "run-gaveup.$H" "running $NOW 4242"; phase_row run-gaveup resolving; phase_row run-gaveup returned
seed_land "other.$H" "running $NOW 4242"; phase_row other checking "$X" trunk-landing-phases.tsv   # a row of another lane commit is not this run's
seed_land "t-retry.$H.$X" "retry 1 REFUSED: read bound"; seed_land "t-env.$H" "env-wait away"
seed_land "t-final.$H" "final REFUSED: conflict in a.txt"; seed_land "t-final2.$H.$X" "final 2 REFUSED: gate failed; full log: /x"
seed_land "t-landed.$H" "landed"; seed_land "t-landed2.$H" "landed cleaned up"
seed_land "lane-moved.$H" "wait REFUSED: away mode"
mkdir -p "$M/retired"; printf 'final REFUSED: conflict in a.txt\n' > "$M/retired/old.$H.state"
printf 'final REFUSED: conflict in a.txt\n' > "$M/retired/lane-here.$HERE.state"
: > "$T/states.corpus"
for id in "none.$H:queued" "q-wait.$H:queued" "q-wait2.$H.$X:queued" "run-reb.$H:rebasing" "run-res.$H:resolving" "run-ret.$H:retesting" \
  "run-chk.$H:checking" "run-chk2.$H:checking" "run-gaveup.$H:returned" "other.$H:rebasing" "t-retry.$H.$X:retrying" "t-env.$H:retrying" \
  "t-final.$H:returned" "t-final2.$H.$X:returned" "t-landed.$H:landed" "t-landed2.$H:landed" "lane-moved.$H:withdrawn" "old.$H:returned" \
  "lane-here.$HERE:queued" "lane-moved.$NEW:queued"; do
  echo "show landing ${id%:*} -> $(word_of "${id%:*}")"
  assert_equals "${id##*:}" "$(word_of "${id%:*}")" "${id%:*} is ${id##*:}"
  word_of "${id%:*}" >> "$T/states.corpus"
done
for st in queued rebasing resolving retesting checking retrying landed returned withdrawn; do grep -qx "$st" "$T/states.corpus" || fail "no fixture is in state $st"; done
jm check landing --corpus "$T/states.corpus"; expect_code 0 "$RC" "every word a fixture printed is a state"
pass "a fixture record in every state prints the right word"

# A running record with no epoch above 0, an epoch past the 6-hour expiry, or a pid that is not a number is a finding, and blocks nothing.
seed_land "r0.$H.$X" "running 0"; seed_land "r1.$H" "running"; seed_land "r2.$H" "running $((NOW - 30000))"; seed_land "r3.$H" "running $NOW 4x2"
: > "$T/bad.corpus"
for id in r0.$H.$X:running-no-epoch r1.$H:running-no-epoch r2.$H:running-expired r3.$H:running-bad-pid; do
  jm show landing "${id%:*}"; expect_code 1 "$RC" "${id%:*} is a finding"
  assert_contains "$OUT" "no state: the observer printed '${id##*:}'" "${id%:*} names ${id##*:}"
  printf '%s\n' "${id##*:}" >> "$T/bad.corpus"
done
jm check landing --corpus "$T/bad.corpus"; expect_code 1 "$RC" "check flags the bad shapes"
assert_contains "$OUT" "running-no-epoch is not a state" "check names running 0"
jm check landing; expect_code 0 "$RC" "a bad record never fails the table check (report-only)"
pass "check flags running 0, expiry and a bad pid, and blocks nothing"

# Moves: the 13 legal moves replay clean, and a move out of a final state is a finding.
{ tab queued start rebasing; tab queued withdraw withdrawn; tab rebasing rebase-ok checking
  tab rebasing conflict resolving; tab resolving conflict-resolved retesting; tab resolving give-back returned
  tab retesting retest-ok checking; tab retesting retest-red returned; tab checking check-ok landed; tab checking check-red returned
  tab checking fault retrying; tab rebasing fault retrying; tab retesting fault retrying; tab retrying retry rebasing; } > "$T/moves.corpus"
jm check landing --corpus "$T/moves.corpus"; expect_code 0 "$RC" "legal moves replay clean"
tab landed start rebasing > "$T/bad-move.corpus"
jm check landing --corpus "$T/bad-move.corpus"; expect_code 1 "$RC" "a move out of landed"
assert_contains "$OUT" "landed start rebasing is not a move" "check names the move"
pass "check replays the legal moves and refuses a move out of a final state"

# The shadow log: a legal move adds no line, an illegal one adds exactly one, and the writer carries on.
LOG=$JG_HOME/data/machine-shadow.log
lines() { [ -f "$LOG" ] && wc -l < "$LOG" || echo 0; }
shadow() { local b; b=$(lines); bash "$ROOT/bin/jg-machine-shadow.sh" landing "$1" "$2" || fail "the shadow helper must always exit 0"; echo $(( $(lines) - b )); }
echo "shadow log before: $(lines) lines"
assert_equals 0 "$(shadow "run-chk.$H" landed)" "checking -> landed is legal: the move the lander reports"
assert_equals 0 "$(shadow "run-chk2.$H" landed)" "checking -> landed is legal after a clean rebase"
assert_equals 0 "$(shadow "run-reb.$H" checking)" "rebasing -> checking is legal"
assert_equals 0 "$(shadow "run-res.$H" retesting)" "resolving -> retesting is legal"
assert_equals 0 "$(shadow "t-retry.$H.$X" rebasing)" "retrying -> rebasing is legal"
assert_equals 0 "$(shadow "run-ret.$H" checking)" "retesting -> checking is legal"
echo "shadow log after the six legal moves: $(lines) lines"
assert_equals 1 "$(shadow "run-reb.$H" landed)" "rebasing -> landed skips the check and is illegal"
assert_contains "$(tail -n 1 "$LOG")" landing "the shadow line names the machine"
assert_equals 1 "$(shadow "t-landed.$H" rebasing)" "a landed run has no move"
pass "a legal move adds no shadow line, an illegal move adds one"

# A ready lane whose home has no model and no watcher left (09:03Z to 09:20Z on 10 Nov: nothing landed for 16.5 minutes)
# lands on the host sentinel's next tick. The sentinel serves Main's home and each local lead home, which is where a trunk lives.
# A watcher alive beside the tick changes nothing: one landing run, not two.
tick_world() {  # <name>: a fixture home that is its own checkout, a stub Herdr with no server, and the wake queue on files
  world "$1"
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  printf 'off\n' > "$HOME_D/config/wake-bus"
  # shellcheck disable=SC2016 # the stub expands its own arguments
  printf '#!/usr/bin/env bash\ncase " $* " in *" status "*) echo %s ;; *) exit 1 ;; esac\n' "'{\"server\":{\"running\":false}}'" > "$W/fakebin/herdr"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$W/fakebin/tmux"; printf '#!/usr/bin/env bash\nexit 1\n' > "$W/fakebin/systemctl"
  chmod +x "$W/fakebin/herdr" "$W/fakebin/tmux" "$W/fakebin/systemctl"; mkdir -p "$W/tmproot"
}
sentinel_tick() {  # <home>: one tick of the host sentinel for that home, as its unit runs it
  env PATH="$W/fakebin:$PATH" JG_HOME="$1" JG_BIN="${TICK_BIN:-}" JG_SENTINEL_HERDR_SESSION=jg-lab-machine-landing \
    JG_TMP_ROOT="$W/tmproot" JG_SENTINEL_TMP_SWEEP_SECS=0 JG_SENTINEL_CAPTAIN_SAY=true bash "$ROOT/core/sentinel/bin/jg-sentinel.sh" tick
}
landed_in_time() {  # <id> <head>
  local _; for _ in $(seq 1 300); do grep -Eqs '^landed( |$)' "$HOME_D/data/jg-trunk-landing/$1.$2.state" && return 0; sleep 0.1; done
  fail "$1 did not land: $(cat "$HOME_D/data/jg-trunk-landing/$1.$2".* 2>/dev/null | tail -n 5)"
}
runs_of() { find "$HOME_D/data/jg-trunk-landing" -name "$1.$2.request-*.log" | wc -l | tr -d ' '; }
rows_of() { awk -F'\t' -v i="$1" '$1 == i' "$HOME_D/data/trunk-landings.tsv" 2>/dev/null | wc -l | tr -d ' '; }

tick_world tick-lead; base=$(tip)
lane solo one; c=$(git -C "$PROJ" rev-parse fm/solo)
MAIN_D="$W/main"; mkdir -p "$MAIN_D/state" "$MAIN_D/data" "$MAIN_D/config"
printf -- '- trunk-lead - the lead that owns the trunk (home: %s; scope: x; projects: proj; added 2026-11-10)\n' "$HOME_D" > "$MAIN_D/data/squad_leads.md"
OUT=$(TICK_BIN="$ROOT/bin" sentinel_tick "$MAIN_D" 2>&1) || fail "Main's tick must pass: $OUT"
landed_in_time solo "$c"
assert_equals 1 "$(rows_of solo)" "one landing row for the lane"
assert_equals 1 "$(git -C "$PROJ" rev-list --count "$base..trunk")" "the trunk holds the lane's one commit"
assert_equals 1 "$(runs_of solo "$c")" "one landing run"
OUT=$(TICK_BIN="$ROOT/bin" sentinel_tick "$MAIN_D" 2>&1) || fail "the next tick must pass: $OUT"
assert_contains "$(cat "$HOME_D/state/.wake-queue" 2>/dev/null)" "check: trunk-landing: trunk-landing: landed solo" "the outcome waits in the lead home's own queue"
assert_contains "$(cat "$MAIN_D/state/.sentinel.log")" "delivery: $HOME_D: check: trunk-landing: trunk-landing: landed solo" "the tick logs the outcome it queued"
[ ! -e "$MAIN_D/state/.wake-queue" ] || ! grep -q trunk-landing "$MAIN_D/state/.wake-queue" || fail "the outcome must not go to Main's queue"
printf '%s\n' trunk-lead > "$MAIN_D/config/parked-homes"; lane later two f2.txt
OUT=$(TICK_BIN="$ROOT/bin" sentinel_tick "$MAIN_D" 2>&1) || fail "a tick with a parked lead must pass: $OUT"
sleep 1; [ ! -e "$HOME_D/data/jg-trunk-landing/later.$(git -C "$PROJ" rev-parse fm/later).state" ] || fail "a parked lead home gets no landing"
pass "one sentinel tick lands a ready lane in a local lead home with no model or watcher, and queues its outcome there"

# The watcher alive too: the real watcher's fast tick and the sentinel's tick race for the same ready lane.
tick_world tick-watcher; base=$(tip)
lane pair one; c=$(git -C "$PROJ" rev-parse fm/pair)
JG_HOME="$HOME_D" JG_STATE_OVERRIDE="$HOME_D/state" bash -c \
  '. "$1"; jg_wake_append check urgent "check: waiting-state urgent blocker"' _ "$ROOT/bin/jg-wake-lib.sh" || fail "could not queue the urgent wake"
JG_HOME="$HOME_D" "$ROOT/bin/jg-bus.sh" watcher oldest >/dev/null 2>&1 || fail "could not observe the queued wake"
( env -u JG_TASK_ID PATH="$W/fakebin:$PATH" JG_HOME="$HOME_D" JG_ROOT_OVERRIDE="$W/root" \
    JG_STATE_OVERRIDE="$HOME_D/state" JG_CONFIG_OVERRIDE="$HOME_D/config" JG_POLL=1 JG_SIGNAL_GRACE=0 \
    JG_WATCH_HANDLING_SUCCESSOR=1 JG_SQUAD_LEAD_WAKE_STALL_SECS=1 JG_FAST_CHECK_INTERVAL=0 JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 \
    timeout 60 "$HOME_D/bin/jg-watch.sh" > "$W/watch.out" 2>&1 ) & watcher=$!
for _ in 1 2 3; do sentinel_tick "$HOME_D" >> "$W/tick.out" 2>&1 || fail "the tick must pass: $(cat "$W/tick.out")"; done
wait "$watcher" || fail "the watcher failed: $(cat "$W/watch.out")"
landed_in_time pair "$c"
assert_equals 1 "$(runs_of pair "$c")" "one landing run, not two"
assert_equals 1 "$(rows_of pair)" "one landing row"
assert_equals 1 "$(git -C "$PROJ" rev-list --count "$base..trunk")" "the trunk moved once"
pass "a watcher alive beside the sentinel tick gives one landing run, not two"

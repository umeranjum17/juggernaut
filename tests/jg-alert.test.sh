#!/usr/bin/env bash
# Behavior test for the alert table and its raise function (bin/jg-alert.sh, core/machines/styles/alert-table.tsv, core/machines/tables/alert.tsv;
# slice J10 of the state-machine plan). Everything runs through the real command in a fixture home: a stuck wait raises one alert with the
# right precedence and rung in each of the four delivery modes; with supervision-down open it raises none; the quiet facts, the limits
# by kind, the ladder top, rule I5, rule I6 and the four states are each driven once.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AL="$ROOT/bin/jg-alert.sh"; JM="$ROOT/bin/jg-machine.sh"
T=$(cd "$(jg_test_tmproot jg-alert)" && pwd); H=$T/home
mkdir -p "$H/state"
export JG_HOME="$H" JG_STATE_OVERRIDE="$H/state"
al() { OUT=$(bash "$AL" "$@" 2>&1); RC=$?; }
rec() { bash "$AL" show "$1" | sed -n "s/^$2=//p"; }

# 1. The table lints, and the twelve rows, six rules and five limits are all there.
OUT=$(bash "$JM" check alert 2>&1); expect_code 0 $? "alert table lint"; assert_contains "$OUT" "4 states, 7 edges" "the alert machine has four states"
assert_equals 12 "$(grep -c '^alert	' "$ROOT/core/machines/styles/alert-table.tsv")" "twelve alert rows"
assert_equals 6 "$(grep -c '^rule	' "$ROOT/core/machines/styles/alert-table.tsv")" "rules I1 to I6"
al row stuck-wait; assert_contains "$OUT" "P2" "the stuck-wait row is P2"
al row nonsense; expect_code 1 "$RC" "an unknown alert"; assert_contains "$OUT" "known:" "the refusal lists the rows"
pass "the table lints and holds its rows"

# 2. A stuck wait in each of the four modes: one alert, P2, the rung of the one the wait names, the same row in every mode.
for m in no-mistakes direct-PR local-only local-trunk; do
  al raise stuck-wait "t-$m" --mode "$m" --fact wait=lead --ticket "t-$m"; expect_code 0 "$RC" "raise in $m"
  assert_equals "$(printf 'ring\tstuck-wait--t-%s\t2\tlead' "$m")" "$OUT" "one ring to the lead in $m"
  assert_equals P2 "$(rec "stuck-wait--t-$m" precedence)" "precedence in $m"; assert_equals 2 "$(rec "stuck-wait--t-$m" rung)" "rung in $m"
  assert_equals open "$(bash "$AL" word "stuck-wait--t-$m")" "state in $m"
  assert_equals open "$(bash "$ROOT/core/machines/observers/alert.sh" "stuck-wait--t-$m")" "observer in $m"
done
al raise stuck-wait t-dup --mode local-trunk --fact wait=lead; al raise stuck-wait t-dup --mode local-trunk --fact wait=lead
assert_equals "" "$OUT" "a second raise of a live key rings nothing"
assert_equals 5 "$(bash "$AL" list | wc -l | tr -d ' ')" "five live keys: four modes and one duplicate"
al raise stuck-wait t-bad --mode nonsense --fact wait=lead; expect_code 1 "$RC" "an unknown mode"
al raise stuck-wait t-nowait; expect_code 1 "$RC" "a stuck wait that names no one"
pass "a stuck wait raises one P2 alert at rung 2 in each of the four modes"

# 3. Quiet facts keep a row quiet; a wait that names the worker starts at rung 1 and Main at rung 3.
al raise stuck-wait q1 --fact wait=owner; assert_equals "" "$OUT" "wait owner is quiet"
al raise stuck-wait q2 --fact wait=outside --fact reason=ci; assert_equals "" "$OUT" "wait outside for ci is quiet"
al raise stuck-wait q3 --fact wait=lead --fact reason=parked; assert_equals "" "$OUT" "reason parked is quiet"
al raise stuck-wait q4 --fact wait=outside --fact reason=dependency; expect_code 1 "$RC" "a wait that is not worker, lead or main is not this alert's state"
al raise stuck-wait w1 --fact wait=worker; assert_contains "$OUT" "	1	worker" "a worker wait starts at rung 1"
al raise stuck-wait w2 --fact wait=main; assert_contains "$OUT" "	3	main" "a Main wait starts at rung 3"
! bash "$AL" list | grep -qE "q[123]\$" || fail "a quiet row left a record"
pass "quiet facts keep a row quiet and the first rung follows the wait"

# 4. Rule I1: with supervision-down open for a home, the wait alerts of that home are inhibited and ring nothing; another home still rings.
al raise supervision-down h1 --home h1 --fact beats=2; assert_contains "$OUT" "	0	tick" "supervision-down starts at the tick"
al raise stuck-wait s-h1 --home h1 --fact wait=lead; assert_equals "" "$OUT" "supervision-down open: no ring"
assert_equals inhibited "$(bash "$AL" word stuck-wait--s-h1)" "the covered alert is recorded inhibited"
assert_equals supervision-down--h1 "$(rec stuck-wait--s-h1 covered_by)" "it names its cover"
al raise stuck-wait s-h2 --home h2 --fact wait=lead; assert_contains "$OUT" "ring" "another home still rings"
al resolve supervision-down--h1; assert_contains "$OUT" "ring	stuck-wait--s-h1	2	lead" "resolving the cover releases the covered alert with a ring"
assert_equals open "$(bash "$AL" word stuck-wait--s-h1)" "the released alert is open"
pass "supervision-down open raises no wait alert in its home, and resolving it releases them"

# 5. Fires-at and limits by kind: slow-delivery needs a kind; a state that has not held long enough is refused.
al limit ship-delivering; assert_equals 300 "$OUT" "ship delivering limit"; al limit ship-proving; assert_equals 900 "$OUT" "ship proving limit"
al raise slow-delivery sd1; expect_code 1 "$RC" "slow-delivery with no kind"
al raise slow-delivery sd1 --kind ship-delivering --held 299; expect_code 1 "$RC" "held 299 s of 300"
al raise slow-delivery sd1 --kind ship-delivering --held 300 --ticket tk; assert_contains "$OUT" "ring	slow-delivery--sd1	0	tick" "held 300 s rings the tick first"
al raise slow-delivery sd2 --kind ship-delivering --held 400 --fact wait=outside --fact reason=ci; assert_equals "" "$OUT" "wait outside for ci keeps slow-delivery quiet"
pass "limits by kind gate the fires-at time"

# 6. Rule I5: a higher alert for a ticket keeps a lower one for the same ticket quiet.
al raise lost-worker lw1 --ticket tk; assert_contains "$OUT" "ring" "lost-worker (P2) for tk rings"
al raise slow-delivery sd3 --kind ship-delivering --held 300 --ticket tk; assert_equals "" "$OUT" "P3 for the same ticket is covered by the P2"
assert_equals inhibited "$(bash "$AL" word slow-delivery--sd3)" "the P3 is inhibited"
pass "one page for one ticket"

# 7. The ladder: climb waits for the timer and stops at the row's top; rule I6 holds rung 4 for P1 while the owner is away.
al raise line-red lr1 --project p --fact presence=away; assert_contains "$OUT" "	2	lead" "line-red starts at the lead"
now=$(rec line-red--lr1 rung_at)
al climb line-red--lr1 --now $((now + 299)); expect_code 1 "$RC" "a climb before 300 s"
al climb line-red--lr1 --now $((now + 300)); assert_contains "$OUT" "	3	main" "a climb at 300 s reaches Main"
al climb line-red--lr1 --now $((now + 600)); assert_contains "$OUT" "	4	owner" "a climb at 600 s reaches the owner"
al climb line-red--lr1 --now $((now + 900)); expect_code 1 "$RC" "no climb above the top"
al raise security sec1 --fact presence=away; assert_contains "$OUT" "	4	owner" "P0 reaches the owner even while away (I6)"
al raise line-red lr2 --project p2 --fact presence=away; al climb line-red--lr2 --now $(( $(rec line-red--lr2 rung_at) + 300 ))
assert_equals 3 "$(rec line-red--lr2 rung)" "away: the P1 climb stops at Main"
pass "the ladder climbs by its timer, stops at its top, and presence holds rung 4"

# 8. The four states: open to acknowledged to open, and resolved is final.
al ack stuck-wait--w1; expect_code 0 "$RC" "ack"; assert_equals acknowledged "$(bash "$AL" word stuck-wait--w1)" "acknowledged"
al climb stuck-wait--w1 --now 99999999999; expect_code 1 "$RC" "an acknowledged alert does not climb"
al reopen stuck-wait--w1; assert_equals open "$(bash "$AL" word stuck-wait--w1)" "reopened"
al resolve stuck-wait--w1; assert_equals resolved "$(bash "$AL" word stuck-wait--w1)" "resolved"
al ack stuck-wait--w1; expect_code 1 "$RC" "a resolved alert cannot be acknowledged"
al raise stuck-wait w1 --fact wait=worker; assert_contains "$OUT" "ring" "a resolved key can ring again as a new episode"
pass "open, acknowledged, inhibited and resolved follow the table"

# 9. deliver: a ring reaches its holder as one wake, a tick ring is only recorded, and a stray line is refused.
export JG_CONFIG_OVERRIDE="$H/config" JG_DATA_OVERRIDE="$H/data"; mkdir -p "$H/config" "$H/data"
Q=$(bash -c '. "$1/bin/jg-wake-lib.sh"; printf %s "$JG_WAKE_QUEUE"' _ "$ROOT")
bash "$AL" raise host mem1 --machine m1 | bash "$AL" deliver; expect_code 0 $? "deliver a main ring"
assert_contains "$(cat "$Q" 2>/dev/null)" "alert-host--mem1" "the main ring is one wake in the queue"
assert_contains "$(cat "$Q")" "(P3) at rung 3 for main" "the wake names precedence, rung and holder"
bash "$AL" raise supervision-down h9 --home h9 --fact beats=2 | bash "$AL" deliver
! grep -q "alert-supervision-down--h9" "$Q" || fail "a tick ring made a wake"
assert_contains "$(bash "$ROOT/bin/jg-wake.sh" settled 2>&1)" "alert-supervision-down--h9" "a tick ring is recorded as settled"
bash "$AL" raise line-red nt1 --note "the tip is red" | bash "$AL" deliver
assert_contains "$(cat "$Q")" "(P1) at rung 2 for lead: nt1. the tip is red" "the producer's note rides in the wake"
echo "not a ring" | bash "$AL" deliver 2>/dev/null; expect_code 1 $? "a stray line is refused"
# The old line-red wake calls are gone from every producer: the only wake they raise is the alert's.
assert_equals "" "$(grep -nE 'jg_wake_append check "(trunk-tip-red|trunk-reverted|line-red|trunk-no-green|post-merge-ci)-' "$ROOT"/bin/jg-trunk.sh "$ROOT"/bin/jg-post-merge-ci.sh)" "no producer of line-red wakes by itself"
pass "deliver turns a ring into a wake for its holder and only records a tick ring"

# 10. The wait ladder reads its rung timers from the table: they print from it, a changed row changes them, and the library holds no default of its own.
al timers; expect_code 0 "$RC" "timers"; assert_equals "$(printf 'escalate\t300\ncard\t600\nrealert\t600\nready-stall\t600')" "$OUT" "the timers come from the stuck-wait ladder and the ready-idle row"
sed 's/^ladder\tP2\t300\t600/ladder\tP2\t120\t240/' "$ROOT/core/machines/styles/alert-table.tsv" > "$T/alert-table.tsv"
OUT=$(JG_ALERT_TABLE="$T/alert-table.tsv" bash "$AL" timers 2>&1 | tr '\t' ' ' | paste -sd' ' -); assert_equals "escalate 120 card 240 realert 240 ready-stall 600" "$OUT" "a changed ladder row moves every rung timer"
assert_equals "" "$(grep -nE 'JG_(WAIT_ESCALATE|WAIT_CARD|PROMPT_REALERT|READY_STALL)_SECS:-[0-9]' "$ROOT/core/wait-timers/bin/jg-wait-timers-lib.sh")" "no rung timer default is written in the library"
pass "the wait ladder reads its rung timers from the alert table"

# 11. capacity: every capacity producer raises through the one entry; the alert starts at rung 1 (a live wake, not a tick record), carries
# the producer's text, a new event of the same producer replaces its last one, and no producer calls jg_wake_append itself any more.
: > "$Q"
al capacity zai-quota "GLM low" --print; assert_equals "alert capacity (P2) at rung 1 for worker: zai-quota - GLM low" "$OUT" "the printed line a check hands the watcher"
bash "$AL" capacity model-outage-abc "affected=[a,b]: down" --deliver; expect_code 0 $? "capacity --deliver"
assert_contains "$(cat "$Q")" "alert-capacity--model-outage-abc" "the capacity alert is one wake in the queue"
assert_contains "$(cat "$Q")" "at rung 1 for worker: model-outage-abc - affected=[a,b]: down" "the wake carries the producer's text"
bash "$AL" capacity model-outage-abc "affected=[a,b,c]: down" --deliver
assert_equals 2 "$(grep -c 'alert-capacity--model-outage-abc' "$Q")" "a new event of the producer rings again"
assert_equals 1 "$(bash "$AL" list | grep -c '^capacity--model-outage-abc$')" "and leaves one live record"
al capacity route-chain; expect_code 2 "$RC" "capacity needs a producer and a text"
assert_equals "" "$(grep -nE 'jg_wake_append (check )?(admission-retry|"?model-outage-)' "$ROOT/bin/jg-watch.sh" "$ROOT/core/alerts/bin/jg-model-outage-lib.sh")" "the old wake calls are gone"
pass "capacity raises through the alert function at rung 1 and the old wake calls are gone"

# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 9. deliver: a ring reaches its holder as one wake, a tick ring is only recorded, and a stray line is refused.
export JG_CONFIG_OVERRIDE="$H/config" JG_DATA_OVERRIDE="$H/data"; mkdir -p "$H/config" "$H/data"
Q=$(bash -c '. "$1/bin/jg-wake-lib.sh"; printf %s "$JG_WAKE_QUEUE"' _ "$ROOT")
bash "$AL" raise host mem1 --machine m1 | bash "$AL" deliver; expect_code 0 $? "deliver a main ring"
assert_contains "$(cat "$Q" 2>/dev/null)" "alert-host--mem1" "the main ring is one wake in the queue"
assert_contains "$(cat "$Q")" "(P3) at rung 3 for main" "the wake names precedence, rung and holder"
bash "$AL" raise lost-worker h9 --home h9 | bash "$AL" deliver
! grep -q "alert-lost-worker--h9" "$Q" || fail "a tick ring made a wake"
assert_contains "$(bash "$ROOT/bin/jg-wake.sh" settled 2>&1)" "alert-lost-worker--h9" "a tick ring is recorded as settled"
bash "$AL" raise line-red nt1 --note "the tip is red" | bash "$AL" deliver
assert_contains "$(cat "$Q")" "(P1) at rung 2 for lead: nt1 - the tip is red" "the producer's note rides in the wake"
echo "not a ring" | bash "$AL" deliver 2>/dev/null; expect_code 1 $? "a stray line is refused"
# The old line-red wake calls are gone from every producer: the only wake they raise is the alert's.
assert_equals "" "$(grep -nE 'jg_wake_append check "(trunk-tip-red|trunk-reverted|line-red|trunk-no-green|post-merge-ci)-' "$ROOT"/bin/jg-trunk.sh "$ROOT"/bin/jg-post-merge-ci.sh)" "no producer of line-red wakes by itself"
pass "deliver turns a ring into a wake for its holder and only records a tick ring"

# 9b. raise --deliver on a slow delivery: a slow delivery rings the worker (rung 1) as one wake, a quiet row rings nothing, a refusal is passed on.
al raise slow-delivery fire1 --kind ship-delivering --deliver; expect_code 0 "$RC" "fire a slow delivery"
assert_contains "$(cat "$Q")" "alert-slow-delivery--fire1" "the fired slow delivery is one wake in the queue"
assert_contains "$(cat "$Q")" "(P3) at rung 1 for worker" "it rings the worker, the tick climb not being built"
al raise slow-delivery fire2 --kind ship-delivering --fact wait=outside --fact reason=ci --deliver; expect_code 0 "$RC" "a quiet fire"; ! grep -q "slow-delivery--fire2" "$Q" || fail "a quiet row made a wake"
al raise slow-delivery fire3; expect_code 1 "$RC" "a refusal is passed on"
pass "a slow delivery raised with --deliver rings the worker as one wake"

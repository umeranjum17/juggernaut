# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
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

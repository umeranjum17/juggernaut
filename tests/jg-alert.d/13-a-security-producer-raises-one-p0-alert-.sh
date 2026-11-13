# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 13. A security producer raises one P0 alert per event through raise --deliver, and no producer keeps its own wake call.
: >"$Q"
al raise security fixture-event-1 --note "a refused delete in /w" --deliver; expect_code 0 "$RC" "raise a security event"
al raise security fixture-event-2 --note "a refused delete in /w" --deliver; expect_code 0 "$RC" "raise a second event"
assert_equals 2 "$(bash "$AL" list | grep -c '^security--fixture-event-')" "each event is its own record, never dropped for an open one"
assert_equals P0 "$(rec security--fixture-event-1 precedence)" "a security alert is P0"; assert_equals 4 "$(rec security--fixture-event-1 rung)" "a security alert rings the owner at rung 4"
assert_contains "$(cat "$Q")" "(P0) at rung 4 for owner: fixture-event-1 - a refused delete in /w" "the wake names the alert, precedence, rung, holder and note"
assert_equals "" "$(cd "$ROOT" && git grep -nE 'jg_wake_append check (unauthenticated-state-checks|delete-guard)\b' -- bin core ':!*tests*' ':!core/wait-timers' || true)" "the old direct wake calls of the security producers are gone"
assert_equals "" "$(cd "$ROOT" && git grep -nE '^\s*print\(line\)$' -- core/key-in-env-check/key-in-env-check)" "key-in-env prints no wake line of its own"
pass "a security producer raises one P0 alert per event and the old wake calls are gone"

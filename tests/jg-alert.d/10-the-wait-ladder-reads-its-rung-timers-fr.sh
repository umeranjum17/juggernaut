# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 10. The wait ladder reads its rung timers from the table: they print from it, a changed row changes them, and the library holds no default of its own.
al timers; expect_code 0 "$RC" "timers"; assert_equals "$(printf 'escalate\t300\ncard\t600\nrealert\t600\nready-stall\t600')" "$OUT" "the timers come from the stuck-wait ladder and the ready-idle row"
sed 's/^ladder\tP2\t300\t600/ladder\tP2\t120\t240/' "$ROOT/core/machines/styles/alert-table.tsv" > "$T/alert-table.tsv"
OUT=$(JG_ALERT_TABLE="$T/alert-table.tsv" bash "$AL" timers 2>&1 | tr '\t' ' ' | paste -sd' ' -); assert_equals "escalate 120 card 240 realert 240 ready-stall 600" "$OUT" "a changed ladder row moves every rung timer"
assert_equals "" "$(grep -nE 'JG_(WAIT_ESCALATE|WAIT_CARD|PROMPT_REALERT|READY_STALL)_SECS:-[0-9]' "$ROOT/core/wait-timers/bin/jg-wait-timers-lib.sh")" "no rung timer default is written in the library"
pass "the wait ladder reads its rung timers from the alert table"

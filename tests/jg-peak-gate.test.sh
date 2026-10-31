#!/usr/bin/env bash
# tests/jg-peak-gate.test.sh - the peak-price guard answers its two questions
# from defaults/peak-windows.tsv alone, defers a spawn at the boundary, lets
# captain-urgent work through with a recorded line, and wakes the fleet exactly
# once per off-peak stretch (bin/jg-peak-lib.sh, bin/jg-peak-gate.sh).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-peak-gate)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
GATE="$ROOT/bin/jg-peak-gate.sh"
DATA="$ROOT/defaults/peak-windows.tsv"
HOME_DIR=$TMP_ROOT/home
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
export JG_HOME=$HOME_DIR JG_STATE_OVERRIDE=$HOME_DIR/state JG_CONFIG_OVERRIDE=$HOME_DIR/config

# Fixed epochs, never the live clock: 2026-10-28 is a Wednesday and 2026-10-31 a
# Saturday, both far enough from any real now that no run depends on when it runs.
WED=1793145600
SAT=1793404800
utc() { printf '%s' $(($1 + 10#${2%%:*} * 3600 + 10#${2##*:} * 60)); }
OLLAMA=ollama-cloud/deepseek-v4.1-flash
DEEPSEEK=deepseek/deepseek-flash
LOG=$HOME_DIR/state/.peak-overrides.log

# in_peak <route> <epoch>: prints peak, off-peak, or error.
in_peak() {
  local rc=0
  JG_PEAK_NOW=$2 "$GATE" route "$1" >/dev/null 2>&1 || rc=$?
  case "$rc" in 0) printf 'off-peak' ;; 3) printf 'peak' ;; *) printf 'error %s' "$rc" ;; esac
}

# --- the data file carries every field the guard needs ----------------------
bad=$(awk -F '\t' '!/^#/ && NF && $1 != "provider" &&
  (NF != 7 || $5 !~ /^https:\/\// || $6 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/)' "$DATA")
assert_equals '' "$bad" "every peak row names 7 columns, a source URL, and the date it was checked"

# --- Ollama's weekday window, one minute either side of each edge -----------
for row in '11:59 off-peak' '12:00 peak' '17:59 peak' '18:00 off-peak'; do
  IFS=' ' read -r hh mm_verdict <<<"$row"
  assert_equals "$mm_verdict" "$(in_peak "$OLLAMA" "$(utc "$WED" "$hh")")" "Ollama at $hh UTC on a Wednesday"
done
assert_equals 'peak until 2026-10-28T18:00Z' \
  "$(JG_PEAK_NOW=$(utc "$WED" 12:00) "$GATE" route "$OLLAMA")" \
  "the current peak reports the moment it ends"

# --- all weekend is off-peak ------------------------------------------------
assert_equals off-peak "$(in_peak "$OLLAMA" "$(utc "$SAT" 13:00)")" "Ollama at 13:00 UTC on a Saturday"
assert_equals off-peak "$(in_peak "$OLLAMA" "$(utc "$SAT" 15:00)")" "Ollama mid-window on a Saturday"

# --- DeepSeek's own API peaks in two earlier weekday windows ----------------
for row in '00:59 off-peak' '01:00 peak' '03:59 peak' '04:00 off-peak' \
  '05:59 off-peak' '06:00 peak' '09:59 peak' '10:00 off-peak'; do
  IFS=' ' read -r hh mm_verdict <<<"$row"
  assert_equals "$mm_verdict" "$(in_peak "$DEEPSEEK" "$(utc "$WED" "$hh")")" "DeepSeek at $hh UTC on a Wednesday"
done
assert_equals off-peak "$(in_peak "$DEEPSEEK" "$(utc "$SAT" 02:00)")" "DeepSeek at 02:00 UTC on a Saturday"

# --- the provider decides which price list applies --------------------------
assert_equals peak "$(in_peak "$DEEPSEEK" "$(utc "$WED" 02:00)")" "DeepSeek peaks at 02:00"
assert_equals off-peak "$(in_peak "$OLLAMA" "$(utc "$WED" 02:00)")" "the same hour is off-peak on Ollama"
assert_equals peak "$(in_peak "$OLLAMA" "$(utc "$WED" 13:00)")" "Ollama peaks at 13:00"
assert_equals off-peak "$(in_peak "$DEEPSEEK" "$(utc "$WED" 13:00)")" "the same hour is off-peak on DeepSeek"

# --- the dispatch gate: deferred inside the window, admitted outside ---------
PEAK_AT=$(utc "$WED" 13:00)
OFF_AT=$(utc "$WED" 18:30)
rc=0
out=$(JG_PEAK_NOW=$PEAK_AT "$GATE" admit --task defer-me --model "$OLLAMA" 2>&1) || rc=$?
expect_code 75 "$rc" "admit refuses a peak-priced route inside the window"
assert_contains "$out" 'waits for off-peak' 'the refusal names the wait'
assert_equals 1 "$("$GATE" waiting)" 'the refused task is counted as waiting for off-peak'

rc=0
JG_PEAK_NOW=$OFF_AT "$GATE" admit --task defer-me --model "$OLLAMA" >/dev/null 2>&1 || rc=$?
expect_code 0 "$rc" 'admit allows the same route once the window closes'
assert_equals 0 "$("$GATE" waiting)" 'admitting the task clears its waiting marker'

# --- the override path: through the window, with a line naming it -----------
rc=0
JG_PEAK_NOW=$PEAK_AT "$GATE" admit --task urgent --model "$OLLAMA" \
  --override 'captain says ship now' >"$TMP_ROOT/override.out" 2>&1 || rc=$?
expect_code 0 "$rc" 'the override admits a peak-priced route'
assert_grep 'task=urgent' "$LOG" 'the override log names the task'
assert_grep "route=$OLLAMA" "$LOG" 'the override log names the route'
assert_grep 'peak-until=2026-10-28T18:00Z' "$LOG" 'the override log names the window'
assert_grep 'override=captain says ship now' "$LOG" 'the override log records the reason'
assert_grep 'task=urgent' "$TMP_ROOT/override.out" 'the override line is printed, not only filed'
assert_equals 0 "$("$GATE" waiting)" 'an override leaves nothing waiting'

# --- a capped plan bills nothing extra at peak, so nothing is deferred ------
printf 'capped\n' >"$HOME_DIR/config/peak-billing"
rc=0
JG_PEAK_NOW=$PEAK_AT "$GATE" admit --task capped-task --model "$OLLAMA" >/dev/null 2>&1 || rc=$?
expect_code 0 "$rc" 'a capped plan does not gate a peak-priced route'
rm -f -- "$HOME_DIR/config/peak-billing"
rc=0
JG_PEAK_NOW=$PEAK_AT "$GATE" admit --task plan-gone --model "$OLLAMA" >/dev/null 2>&1 || rc=$?
expect_code 75 "$rc" 'with no recorded plan the guard avoids peak by default'

# --- the window-end event fires exactly once for the stretch that waited ----
assert_equals '' "$(JG_PEAK_NOW=$(utc "$WED" 15:00) "$GATE" check)" 'no wake while the peak window is still open'
fired=$(JG_PEAK_NOW=$(utc "$WED" 18:30) "$GATE" check)
assert_contains "$fired" 'off-peak now' 'the window end wakes the leads to dispatch the work that waited'
assert_contains "$fired" '1 task(s) waited' 'the wake carries the waiting count'
assert_equals '' "$(JG_PEAK_NOW=$(utc "$WED" 19:00) "$GATE" check)" 'the same off-peak stretch does not fire twice'
assert_equals '' "$(JG_PEAK_NOW=$(utc "$WED" 20:00) "$GATE" check)" 'and it stays fired for the whole stretch'

# --- a route still inside a peak blocks the wake even when work waits -------
rm -f -- "$HOME_DIR"/state/.peak-gate/dispatched-*
assert_equals '' "$(JG_PEAK_NOW=$(utc "$WED" 02:00) "$GATE" check)" 'no wake while another route is still inside its peak'

# --- nothing waiting means no wake at all -----------------------------------
rm -f -- "$HOME_DIR"/state/.peak-waiting/* "$HOME_DIR"/state/.peak-gate/dispatched-*
assert_equals '' "$(JG_PEAK_NOW=$(utc "$WED" 05:00) "$GATE" check)" 'nothing waiting, so nothing wakes'

# --- the digest and heartbeat sentence --------------------------------------
assert_contains "$(JG_PEAK_NOW=$PEAK_AT "$GATE" status)" 'peak now on ollama/deepseek-v4*' 'status names the route in peak'
assert_contains "$(JG_PEAK_NOW=$PEAK_AT "$GATE" status)" 'until 2026-10-28T18:00Z' 'status names when the peak ends'
assert_contains "$(JG_PEAK_NOW=$OFF_AT "$GATE" status)" 'off-peak; next peak at' 'status names the next change when off-peak'
assert_contains "$(JG_PEAK_NOW=$PEAK_AT "$GATE" status)" 'task(s) waiting for off-peak' 'status carries the waiting count'

HB=$TMP_ROOT/hb
mkdir -p "$HB/state"
printf '{"ready_work":0}\n' >"$HB/state/home-summary.json"
touch "$HB/state/.last-watcher-beat"
row=$(JG_HOME="$HB" "$ROOT/bin/jg-fleet-heartbeat.sh" rows | head -1)
assert_equals 9 "$(printf '%s' "$row" | awk -F '\t' '{ print NF }')" 'the heartbeat carries the peak sentence as its ninth column'
assert_contains "$row" 'waiting for off-peak' 'the heartbeat row reports peak state and the waiting count'

pass "peak-price guard: boundaries, weekend, override, and the one-shot window-end wake"

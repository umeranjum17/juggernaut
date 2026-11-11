#!/usr/bin/env bash
# The wake ledger (data/wake-ledger.tsv): every wake the append path sees leaves one row of
# epoch, home, kind, key and class, whatever class the routing gave it, so alerts stay
# countable after the queue's acknowledgement deletes them. The three heartbeat shapes
# (an urgent heartbeat, a silent one over an unchanged fleet, a batched fleet-heartbeat
# check) all appear; the file keeps a week and rolls to wake-ledger.tsv.1; a ledger that
# cannot be written never fails the wake.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(jg_test_tmproot jg-wake-ledger)
TAB=$(printf '\t')

# append <home> <kind> <key> <payload>: the production appender; the ledger lands in <home>/data.
# shellcheck disable=SC2016 # the single-quoted body expands only inside the called bash
append() {
  env -u JG_WAKE_ROUTING JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" bash -c '. "$1/bin/jg-wake-lib.sh"; jg_wake_append "$2" "$3" "$4"' _ "$ROOT" "$2" "$3" "$4"
}

new_home() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/config" "$dir/data"
  printf '%s\n' "$dir"
}

test_every_class_and_the_three_heartbeats() {
  local dir ledger now
  dir=$(new_home classes)
  ledger="$dir/data/wake-ledger.tsv"
  now=$(date +%s)
  append "$dir" heartbeat heartbeat heartbeat || true
  JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" JG_CONFIG_OVERRIDE="$dir/config" \
    bash -c '. "$1/bin/jg-wake-lib.sh"; jg_wake_fleet_fp_record' _ "$ROOT"
  append "$dir" heartbeat heartbeat heartbeat || true
  append "$dir" check "$dir/state/fleet-heartbeat.check.sh" \
    'fleet-heartbeat: GAP for 3 ready lanes working' || true
  [ -s "$ledger" ] || fail "no ledger was written at $ledger"
  assert_equals 3 "$(awk 'END { print NR }' "$ledger")" "one row per wake, whatever its class"
  awk -F '\t' -v home="$dir" -v now="$now" '
    NF != 5 { exit 1 }
    $1 < now || $1 > now + 60 { exit 2 }
    $2 != home { exit 3 }' "$ledger" || fail "a row is not epoch, home, kind, key, class: $(cat "$ledger")"
  assert_equals "heartbeat${TAB}heartbeat${TAB}now" "$(sed -n 1p "$ledger" | cut -f3-5)" "a heartbeat over a changed fleet is urgent"
  assert_equals "heartbeat${TAB}heartbeat${TAB}silent" "$(sed -n 2p "$ledger" | cut -f3-5)" "a heartbeat over an unchanged fleet is recorded as silent"
  assert_equals "check${TAB}$dir/state/fleet-heartbeat.check.sh${TAB}batch" "$(sed -n 3p "$ledger" | cut -f3-5)" "a fleet-heartbeat gap is recorded as batch"
  pass "each wake leaves one row, and the urgent, silent and batched heartbeats are all present"
}

test_week_rotation() {
  local dir ledger now
  dir=$(new_home rotate)
  ledger="$dir/data/wake-ledger.tsv"
  now=$(date +%s)
  printf '%s\t%s\tcheck\told\tbatch\n' "$((now - 604800 - 5))" "$dir" > "$ledger"
  printf '%s\t%s\tcheck\tolder\tbatch\n' "$((now - 604800))" "$dir" >> "$ledger"
  append "$dir" check new 'check: new' || true
  assert_equals 1 "$(awk 'END { print NR }' "$ledger")" "a week-old ledger starts again with the new row"
  assert_equals new "$(cut -f4 "$ledger")" "the new row opens the new ledger"
  assert_equals "old${TAB}older" "$(cut -f4 "$ledger.1" | paste -s -)" "the old week is kept as wake-ledger.tsv.1"
  append "$dir" check newer 'check: newer' || true
  assert_equals 2 "$(awk 'END { print NR }' "$ledger")" "a current ledger keeps appending"
  assert_equals 2 "$(awk 'END { print NR }' "$ledger.1")" "a current ledger leaves the old week alone"
  pass "the ledger rolls once its first row is a week old and keeps one older week"
}

test_no_data_directory_no_ledger_and_no_failure() {
  local dir
  dir=$(new_home bare)
  rmdir "$dir/data"
  append "$dir" check key 'check: x' || fail "a home without a data directory failed the wake"
  [ ! -e "$dir/data" ] || fail "the ledger made a data directory"
  pass "a home with no data directory gets no ledger and its wake still succeeds"
}

test_every_class_and_the_three_heartbeats
test_week_rotation
test_no_data_directory_no_ledger_and_no_failure
echo "wake ledger: one row per wake in every class, the heartbeat shapes, weekly rotation, no data directory means no ledger"

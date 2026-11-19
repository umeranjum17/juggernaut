#!/usr/bin/env bash
# The bus is retired (slice 11b1): with no config/wake-bus and nothing listening on any bus port, a
# wake is raised, drained and acknowledged on local files; a steer's handled word is recorded; the
# captain channel's mode is `direct`; the three stubbed bus scripts publish nothing; and the key-value
# surface the task leases use keeps its contract on one SQLite file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 is needed"; exit 0; }
DIR=$(jg_test_tmproot bus-direct)
HOME_DIR="$DIR/home"
STATE="$HOME_DIR/state"
mkdir -p "$STATE" "$HOME_DIR/config" "$HOME_DIR/data"
printf 'now * * * *\n' > "$HOME_DIR/config/wake-routing"
printf 'set mode direct\n' > "$DIR/channel.conf"
export JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE" JG_DATA_OVERRIDE="$HOME_DIR/data"
export JG_WAKE_ROUTING="$HOME_DIR/config/wake-routing"
export JG_CAPTAIN_CHANNEL="$DIR/channel.conf"
[ ! -e "$HOME_DIR/config/wake-bus" ] || fail "the fixture home must have no config/wake-bus"

test_a_wake_is_raised_drained_and_acknowledged_locally() {
  local out rows
  # shellcheck source=bin/jg-wake-lib.sh
  . "$ROOT/bin/jg-wake-lib.sh"
  jg_wake_append check direct-probe "check: raised with no bus" || fail "the raise failed with no bus"
  [ -s "$STATE/.wake-bus.outbox.jsonl" ] || fail "the raise left no row in the local outbox"
  rows=$(awk 'END { print NR }' "$STATE/.wake-queue" 2>/dev/null)
  assert_equals 1 "${rows:-0}" "the raise must be folded into the local queue at once"
  out=$("$ROOT/bin/jg-wake-drain.sh" 2>&1) || fail "the drain failed: $out"
  case "$out" in *"raised with no bus"*) ;; *) fail "the drain did not show the reason line: $out" ;; esac
  local seq gen
  seq=$(printf '%s\n' "$out" | sed -n 's/.*--ack-through \([0-9][0-9]*\) --recovery-generation \([^ ]*\).*/\1/p' | head -n 1)
  gen=$(printf '%s\n' "$out" | sed -n 's/.*--ack-through \([0-9][0-9]*\) --recovery-generation \([^ ]*\).*/\2/p' | head -n 1)
  [ -n "$seq" ] || fail "the drain printed no acknowledgement command: $out"
  "$ROOT/bin/jg-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 || fail "the acknowledgement failed"
  assert_equals 0 "$(awk 'END { print NR }' "$STATE/.wake-queue")" "an acknowledged wake must leave the queue"
  pass "a wake is raised, drained and acknowledged on local files"
}

test_a_handled_steer_is_recorded() {
  local rec show
  rec=$(bash -c '. "$1/bin/jg-task-inbox-lib.sh"; jg_task_inbox_write "$2" "$3" "do the thing"' _ "$ROOT" "$STATE" lab-task) || fail "the steer was not written"
  [ -f "$rec" ] || fail "no steer file"
  "$ROOT/bin/jg-delivery.sh" handled lab-task 1 --evidence status:lab >/dev/null 2>&1 || fail "handled was refused with no bus"
  show=$("$ROOT/bin/jg-delivery.sh" show lab-task)
  case "$show" in *"handled="[0-9]*) pass "a handled word is recorded with no bus: $show" ;; *) fail "no handled word: $show" ;; esac
}

test_the_channel_mode_is_direct() {
  local out
  out=$("$ROOT/bin/jg-bus.sh" status 2>&1) || true
  case "$out" in *"mode direct"*) pass "jg-bus status prints mode direct" ;; *) fail "status: $out" ;; esac
}

test_the_key_value_surface_keeps_its_contract_on_one_file() {
  local n rev
  # shellcheck source=bin/jg-kv-lib.sh
  . "$ROOT/bin/jg-kv-lib.sh"
  jg_kv_ready "$HOME_DIR" || fail "jg_kv_ready refused: $JG_KV_WHY"
  jg_kv_ensure_bucket B || fail "the bucket was not opened"
  (jg_kv_create B k one; echo $? > "$DIR/c1") &
  (jg_kv_create B k two; echo $? > "$DIR/c2") &
  wait
  n=$(cat "$DIR/c1" "$DIR/c2" | grep -c '^0$')
  assert_equals 1 "$n" "two creates of one key at once: exactly one must win"
  [ -f "$STATE/kv.db" ] || fail "the store is not state/kv.db"
  rev=$(jg_kv_revision B k) || fail "no revision for a held key"
  jg_kv_update B k three "$rev" || fail "an update at the read revision must win"
  assert_equals three "$(jg_kv_get B k)" "the update must be stored"
  jg_kv_update B k four "$rev" && fail "an update at a stale revision must fail"
  assert_equals three "$(jg_kv_get B k)" "a refused update must change nothing"
  printf 'five' | jg_kv_put B p/1 || fail "put failed"
  assert_equals "p/1" "$(jg_kv_keys B p/)" "keys must list by prefix"
  jg_kv_del B k
  jg_kv_get B k >/dev/null && fail "a deleted key must be absent"
  pass "create, update at a revision, put, get, keys and del keep their contract on state/kv.db"
}

test_a_wake_is_raised_drained_and_acknowledged_locally
test_a_handled_steer_is_recorded
test_the_channel_mode_is_direct
test_the_key_value_surface_keeps_its_contract_on_one_file

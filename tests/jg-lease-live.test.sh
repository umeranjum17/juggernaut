#!/usr/bin/env bash
# tests/jg-lease-live.test.sh - the task leases live on the key-value bus
# (docs/state-shadow.md, "The lease path, live"): the same holder, the same
# refusal, the same expiry, and the same guard, with the bucket's revision in
# place of the lease-command lock.
#
# Every case drives the shipped executables - bin/jg-lease.sh for the record, and
# bin/jg-send.sh for the guard - against a throwaway nats-server on a free port.
# A case that needs the store says it skipped when this machine has no server or
# no client, which is the CI posture, instead of failing on a missing tool.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEASE="$ROOT/bin/jg-lease.sh"
SEND="$ROOT/bin/jg-send.sh"

DIR=$(jg_test_tmproot jg-lease-live)
HOME_DIR="$DIR/home"
STATE_DIR="$HOME_DIR/state"
DEAD_PID=999999
while kill -0 "$DEAD_PID" 2>/dev/null; do DEAD_PID=$((DEAD_PID + 1)); done

# The store. Without one every case below can decide nothing, so the file says so
# once and exits green: a CI runner has neither binary, and a red result there
# would blame this change for an absent tool.
jg_test_bus_start "$DIR" || {
  echo "skip: nats-server or the nats client not found (set JG_NATS_SERVER and JG_NATS_BIN)"
  exit 0
}

make_home() {
  mkdir -p "$STATE_DIR" "$HOME_DIR/config"
  # The session lock names this test shell as the supervising process, so a
  # lease this test claims is live and one with a dead pid is stale.
  printf '%s\n' "$$" > "$STATE_DIR/.lock"
  # A send needs a resolvable task: a metadata record with a window, and a
  # terminal whose submission is stubbed.
  jg_fake_exit0 "$(jg_fakebin "$DIR")" tmux
  jg_write_meta "$STATE_DIR/t1.meta" "window=sess:jg-t1" "kind=ship" "harness=claude"
}

# lease <actor> <args...>: the shipped command, scoped to this test's home.
lease() { # <actor> <args...>
  local actor=$1
  shift
  JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE_DIR" JG_SUPERVISION_ACTOR="$actor" \
    bash "$LEASE" "$@" 2>&1
}

# send_as_main: one steer through the shipped send, its terminal stubbed. Prints
# the send's stderr and returns its exit status.
send_as_main() {
  env PATH="$DIR/fakebin:$PATH" \
    JG_ROOT_OVERRIDE="$HOME_DIR" JG_HOME="$HOME_DIR" \
    JG_SUPERVISION_ACTOR=main JG_SEND_SETTLE=0 \
    "$SEND" t1 "proceed with the migration" >/dev/null
}

test_a_claim_is_live_and_visible_to_the_other_actor() {
  local out status=0
  out=$(lease main claim t1 --actor main) || fail "the main claim failed: $out"
  out=$(lease branch check t1) || fail "check on a held lease must succeed"
  assert_contains "$out" "main $$ " "check must name the holder and the session-lock pid"
  assert_contains "$out" " live" "a lease held by the live session cannot read as stale"
  out=$(lease branch claim t1 --actor branch) || status=$?
  [ "$status" -eq 6 ] || fail "a claim by the other actor over a live lease must be refused with exit 6, got $status: $out"
  assert_contains "$out" "leased to the main supervision actor" "the refusal must name the holder"
  out=$(lease main check t1)
  assert_contains "$out" "main $$ " "a refused claim must leave the holder in place"
  pass "a claim is live, the other actor is refused with exit 6, and the holder stays"
}

test_the_holder_refreshes_and_an_expired_record_is_taken_over() {
  local out
  out=$(lease main claim t1 --actor main) || fail "the holder's own claim must refresh: $out"
  assert_contains "$(lease main check t1)" "main $$ " "a refresh must keep the holder"
  # A record whose pid is dead is stale for every reader, whichever actor asks:
  # the file path cleared it and the bucket's claim takes it over.
  JG_LEASE_HOLDER_PID="$DEAD_PID" lease branch claim t2 --actor branch >/dev/null \
    || fail "could not seed a stale record"
  assert_contains "$(lease branch check t2)" "stale" "a record with a dead pid must read as stale"
  out=$(JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE_DIR" JG_SUPERVISION_ACTOR=main \
    JG_LEASE_HOLDER_PID="$$" bash "$LEASE" claim t2 --actor main) \
    || fail "a stale record must be taken over, not refuse: $out"
  out=$(lease main check t2)
  assert_equals "main" "$(printf '%s' "$out" | cut -d' ' -f1)" "the takeover must record the actor that took it over"
  assert_equals "$$" "$(printf '%s' "$out" | cut -d' ' -f2)" "the takeover must record the session-lock holder as the pid"
  assert_equals "live" "$(printf '%s' "$out" | cut -d' ' -f4)" "the taken-over record must be live"
  pass "the holder refreshes its own lease, and a stale record is taken over"
}

test_release_and_the_two_bulk_paths() {
  local out
  out=$(lease main release t1 --actor main) || fail "the holder's release failed: $out"
  out=$(lease main check t1) && fail "a released lease must not read as held"
  assert_equals 1 "$?" "check must exit 1 for an unleased task"
  # Naming the other actor's lease leaves it alone: a release is the holder's.
  lease main claim t3 --actor main >/dev/null || fail "could not seed t3"
  lease branch release t3 --actor branch >/dev/null 2>&1 || true
  assert_contains "$(lease main check t3)" "main $$ " "another actor's release must not drop the holder's lease"
  # release-actor drops exactly the named actor's records.
  JG_LEASE_HOLDER_PID="$DEAD_PID" lease branch claim t4 --actor branch >/dev/null \
    || fail "could not seed the branch record"
  lease main claim t5 --actor main >/dev/null || fail "could not seed the main record"
  lease branch release-actor --actor branch >/dev/null || fail "release-actor failed"
  lease branch check t4 >/dev/null && fail "release-actor left the branch's own record behind"
  assert_contains "$(lease main check t5)" "main $$ " "release-actor must leave the other actor's records alone"
  pass "a release drops the holder's own lease, and release-actor drops exactly one actor's"
}

test_sweep_removes_only_the_stale_records() {
  local out
  JG_LEASE_HOLDER_PID="$DEAD_PID" lease branch claim t6 --actor branch >/dev/null \
    || fail "could not seed the dead record"
  lease main claim t7 --actor main >/dev/null || fail "could not seed the live record"
  out=$(JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE_DIR" bash "$LEASE" sweep) \
    || fail "the sweep failed: $out"
  assert_contains "$out" "t6" "the sweep must name the record it removed"
  assert_contains "$out" "stale leases removed: 1" "the sweep must count what it removed"
  lease branch check t6 >/dev/null && fail "the sweep left a provably stale lease in place"
  assert_contains "$(lease main check t7)" "main $$ " "the sweep removed a live lease"
  pass "the sweep removes a stale record and leaves a live one"
}

test_a_watcher_sees_the_claim_and_the_release() {
  local out watchfile="$DIR/watch.out" wpid
  timeout 8 "$JG_NATS_BIN" -s "$JG_KV_URL" kv watch JG_LEASES --updates > "$watchfile" 2>&1 &
  wpid=$!
  sleep 0.7
  lease main claim t8 --actor main >/dev/null || fail "could not claim the watched task"
  lease main release t8 --actor main >/dev/null || fail "could not release the watched task"
  sleep 0.7
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  out=$(cat "$watchfile")
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c 'PUT.*/t8: main')" \
    "a watcher must see the claim with the holder that made it"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c 'DELETE .*/t8$')" \
    "a watcher must see the release as one delete"
  pass "a watcher sees the claim and the release, which is what replaces the poll"
}

test_the_guard_refuses_a_steer_while_the_other_actor_holds_the_task() {
  local out status=0
  lease branch claim t1 --actor branch >/dev/null || fail "could not take the branch lease"
  out=$(send_as_main 2>&1) || status=$?
  [ "$status" -eq 6 ] || fail "a steer must be refused with exit 6 while the other actor holds the task, got $status: $out"
  assert_contains "$out" "leased to the branch supervision actor" "the refusal must name the holder"
  lease branch release t1 --actor branch >/dev/null || fail "could not release the branch lease"
  send_as_main || fail "the steer must deliver once the lease is released"
  pass "the guard refuses a steer through the shipped send while the other actor holds the task"
}

test_an_unreachable_store_refuses_instead_of_passing() {
  local out status=0 dead_url="nats://127.0.0.1:1"
  JG_LEASE_HOLDER_PID="$DEAD_PID" lease branch claim t9 --actor branch >/dev/null \
    || fail "could not seed the record the guard must not excuse"
  out=$(env PATH="$DIR/fakebin:$PATH" \
    JG_ROOT_OVERRIDE="$HOME_DIR" JG_HOME="$HOME_DIR" \
    JG_SUPERVISION_ACTOR=main JG_SEND_SETTLE=0 JG_KV_URL="$dead_url" \
    "$SEND" t1 "proceed" 2>&1 >/dev/null) || status=$?
  [ "$status" -eq 1 ] || fail "a guard that cannot read the store must refuse with exit 1, got $status: $out"
  assert_contains "$out" "no task-lease store answers" "the refusal must name the missing store"
  out=$(JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE_DIR" JG_KV_URL="$dead_url" bash "$LEASE" check t9 2>&1) \
    || status=$?
  [ "$status" -eq 2 ] || fail "check must exit 2 when the store cannot answer, got $status: $out"
  assert_contains "$out" "no task-lease store answers" "check must name the missing store rather than reporting an empty task"
  pass "an unreachable store refuses the mutation and never reads as an empty lease"
}

make_home
result=0
test_a_claim_is_live_and_visible_to_the_other_actor || result=1
test_the_holder_refreshes_and_an_expired_record_is_taken_over || result=1
test_release_and_the_two_bulk_paths || result=1
test_sweep_removes_only_the_stale_records || result=1
test_a_watcher_sees_the_claim_and_the_release || result=1
test_the_guard_refuses_a_steer_while_the_other_actor_holds_the_task || result=1
test_an_unreachable_store_refuses_instead_of_passing || result=1
exit "$result"

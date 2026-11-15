#!/usr/bin/env bash
# The one typed wait writer (bin/jg-wait-write.sh) through its real callers, in two isolated homes.
#   W1 An owner call written by the writer survives a generic done and a failed on a ship lane in both homes, while a
#      worker's own question is still closed by that done (the old contract).
#   W2 The real answer path (bin/jg-send.sh --resolve-key) to a busy worker closes the call once in its own home only;
#      the answer waits durably in the inbox across busy to idle; a second resolution, by the answer path or by the
#      writer, writes nothing and names the wait as already resolved, so it never fires again.
#   W3 A wait opens once as written, a different question on an open key is a new wait, and a bad word writes nothing.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$ROOT/tests/fixtures.sh"
# shellcheck source=bin/jg-classify-lib.sh
. "$ROOT/bin/jg-classify-lib.sh"
T=$(jg_test_tmproot jg-wait-write)
export XDG_CACHE_HOME=$T/cache
WRITE=$ROOT/bin/jg-wait-write.sh
FB=$T/fakebin; mkdir -p "$FB"; jg_test_fake_tmux_send "$FB"; jg_test_fake_sleep_noop "$FB"

# A home with its own Beads store, one ticket in flight and a captain hold on it: the guard wants a hold on record for an owner call.
home() {
  local h=$T/$1
  jg_test_beads_home "$h"; mkdir -p "$h/state"
  jg_test_add "$h" task-w1 "[feature] wait fixture"; jg_test_backlog "$h" start task-w1 >/dev/null
  JG_HOME=$h JG_STATE_OVERRIDE=$h/state JG_DATA_OVERRIDE=$h/data JG_CONFIG_OVERRIDE=$h/config "$ROOT/bin/jg-captain-hold.sh" hold task-w1 --reason "Keep the old name?" >/dev/null || fail "could not hold the fixture ticket"
  jg_write_meta "$h/state/task-w1.meta" "window=sess:jg-task-w1" "kind=ship" "harness=claude"; : > "$h/state/task-w1.status"; printf '%s\n' "$h"; }
write() { local h=$1; shift; JG_HOME=$h JG_STATE_OVERRIDE=$h/state JG_DATA_OVERRIDE=$h/data JG_CONFIG_OVERRIDE=$h/config "$WRITE" "$@"; }
send() { local h=$1; shift; : > "$h/send.log"; env PATH="$FB:$PATH" JG_ROOT_OVERRIDE="$h" JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" JG_DATA_OVERRIDE="$h/data" JG_CONFIG_OVERRIDE="$h/config" JG_SEND_LOG="$h/send.log" JG_SEND_SETTLE=0 "$ROOT/bin/jg-send.sh" "$@" 2>&1; }
open_keys() { status_open_decisions "$1/state/task-w1.status" ship | cut -f1 | paste -sd, -; }

A=$(home a); B=$(home b)
for h in "$A" "$B"; do
  write "$h" open "$h/state/task-w1.status" owner-call --task task-w1 --key pick -- "Keep the old name? Options: keep | rename." >/dev/null || fail "owner call refused in $h"
  write "$h" open "$h/state/task-w1.status" decision --key mine -- "Which flag?" >/dev/null || fail "decision refused in $h"
done
grep -qF 'needs-decision [at=' "$A/state/task-w1.status" || fail "the owner call line has the wrong verb"
grep -qF 'captain call, hold task-w1: Keep the old name?' "$A/state/task-w1.status" || fail "the owner call line has the wrong note"
[ "$(open_keys "$A")" = "pick,mine" ] || fail "both waits must be open before the done, got $(open_keys "$A")"

test_a_generic_done_never_closes_an_owner_call() {
  local h
  for h in "$A" "$B"; do
    printf 'failed [at=1]: tests red\ndone [at=2]: ready in branch x (local)\n' >> "$h/state/task-w1.status"
    [ "$(open_keys "$h")" = pick ] || fail "a done closes only the worker's own question; open after done: $(open_keys "$h") in $h"
  done
  pass "wait writer: a done leaves an owner call open in both homes and closes the worker's own question"
}

test_the_answer_closes_one_home_once_and_the_steer_survives_idle() {
  local out gen lines
  gen=$("$ROOT/bin/jg-busy-event.sh" arm "$A/state" task-w1) || fail "could not arm a busy turn"
  out=$(send "$A" task-w1 --resolve-key pick "keep it") || fail "the answer was refused: $out"
  [ -z "$(open_keys "$A")" ] || fail "the answer left the call open: $(open_keys "$A")"
  [ "$(open_keys "$B")" = pick ] || fail "the answer to home a closed the call in home b"
  grep -qF "keep it" "$A/state/task-w1.inbox/001.msg" || fail "the answer never reached the busy worker's inbox"
  "$ROOT/bin/jg-busy-event.sh" apply "$A/state" task-w1 idle --gen "$gen" >/dev/null 2>&1 || true
  [ -f "$A/state/task-w1.inbox/001.msg" ] || fail "the answer did not persist across busy to idle"
  lines=$(wc -l < "$A/state/task-w1.status")
  out=$(write "$A" resolve "$A/state/task-w1.status" --key pick -- "again") || fail "a second resolve must not fail"
  assert_contains "$out" "already resolved: pick" "the second resolve names the wait as resolved"
  [ "$(wc -l < "$A/state/task-w1.status")" = "$lines" ] || fail "a second resolve wrote a line"
  out=$(send "$A" task-w1 --resolve-key pick "keep it again") && fail "a second answer to a resolved call passed"
  [ "$(wc -l < "$A/state/task-w1.status")" = "$lines" ] || fail "a refused second answer wrote a line"
  pass "wait writer: the answer closes its own home's call once, the steer persists busy to idle, nothing re-fires"
}

test_a_wait_opens_once_and_a_bad_word_writes_nothing() {
  local h out lines
  h=$(home c)
  write "$h" open "$h/state/task-w1.status" pause --who outside --reason ci --until 2099-01-01T00:00Z -- "CI run" >/dev/null || fail "pause refused"
  lines=$(wc -l < "$h/state/task-w1.status")
  out=$(write "$h" open "$h/state/task-w1.status" pause --who outside --reason ci --until 2099-01-01T00:00Z -- "CI run") || fail "reopening failed"
  assert_contains "$out" "already open" "an open wait is not written twice"
  [ "$(wc -l < "$h/state/task-w1.status")" = "$lines" ] || fail "a repeat open wrote a line"
  write "$h" open "$h/state/task-w1.status" decision -- "First?" >/dev/null || fail "decision refused"
  write "$h" open "$h/state/task-w1.status" decision -- "Second?" >/dev/null || fail "second decision refused"
  [ "$(status_open_decisions "$h/state/task-w1.status" ship | cut -f3)" = "Second?" ] || fail "a new question on an open key must replace the old one"
  lines=$(wc -l < "$h/state/task-w1.status")
  write "$h" open "$h/state/task-w1.status" pause --who nobody --reason ci -- "x" >/dev/null 2>&1 && fail "a word outside the closed list passed"
  [ "$(wc -l < "$h/state/task-w1.status")" = "$lines" ] || fail "a refused wait wrote a line"
  pass "wait writer: a wait opens once as written, a new question replaces the old one, a bad word writes nothing"
}

test_a_generic_done_never_closes_an_owner_call
test_the_answer_closes_one_home_once_and_the_steer_survives_idle
test_a_wait_opens_once_and_a_bad_word_writes_nothing

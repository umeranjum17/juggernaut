#!/usr/bin/env bash
# The wake-routing done-done journey runs this suite with tests/jg-wake-route.test.sh.
# Wake urgency routing, proved through the Go command the wake library calls (bin/jg-wake-core.sh).
# tests/fixtures/wake-recorded/route-classes.tsv holds the class the shell rule reader gave each
# distinct event recorded on a real JG_WAKE stream (241 events, 205 raises); the Go port must give
# the same class. tests/jg-wake-route.test.sh keeps the product-level journeys; this suite keeps
# the pattern grammar, the conditions and the append-time dedupe that replay found worth pinning.
# Usage: tests/jg-wake-router.test.sh
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
if ! command -v "${JG_WAKE_CORE_GO:-go}" >/dev/null 2>&1; then
  printf 'skip: no Go toolchain on PATH; install go to build the wake router\n'
  exit 0
fi
TMP_ROOT=$(jg_test_tmproot jg-wake-core)
CORE=$ROOT/bin/jg-wake-core.sh

# route <state> <home> <kind> <key> <payload> [routing-file]
route() {
  JG_STATE_OVERRIDE=$1 "$CORE" --state "$1" --home "$2" --root "$ROOT" --queue "$1/.wake-queue" \
    --routing "${6:-}" route "$3" "$4" "$5"
}

test_recorded_events_keep_their_class() (
  dir=$(make_case recorded)
  bad=0 n=0
  while IFS=$'\t' read -r kind key payload want; do
    n=$((n + 1))
    got=$(route "$dir/state" "$dir" "$kind" "$key" "$payload")
    [ "$got" = "$want" ] || { bad=$((bad + 1)); printf '  %s %s: want %s, got %s\n' "$kind" "$key" "$want" "$got"; }
  done < "$ROOT/tests/fixtures/wake-recorded/route-classes.tsv"
  [ "$n" -gt 50 ] || fail "the recorded events were not read ($n)"
  [ "$bad" -eq 0 ] || fail "$bad of $n recorded events changed class"
  pass "all $n recorded events keep the class the shell rule reader gave them"
)

test_pattern_grammar() (
  dir=$(make_case grammar)
  rules=$dir/rules
  r() { route "$dir/state" "$dir" "$1" "$2" "$3" "$rules"; }
  printf 'silent * /home/*/state/* *\nbatch check ?-wait *\nbatch check [a-c]x *\nbatch check [!a-c]y *\nbatch check lit\\*star *\nbatch check cls-[[:digit:]]* *\nbatch\tcheck\ttab\t*\nnow check plain *\nsilent check final *' > "$rules"
  assert_equals "$(r check /home/u/state/deep/x.sh p)" silent "a star crosses slashes"
  assert_equals "$(r check a-wait p)" batch "a question mark is one character"
  assert_equals "$(r check ab-wait p)" now "a question mark is not two"
  assert_equals "$(r check bx p)" batch "a bracket range matches"
  assert_equals "$(r check dx p)" now "a bracket range excludes"
  assert_equals "$(r check dy p)" batch "a negated bracket matches"
  assert_equals "$(r check 'lit*star' p)" batch "a backslash makes a star literal"
  assert_equals "$(r check litXstar p)" now "a literal star is not a wildcard"
  assert_equals "$(r check cls-7z p)" batch "a character class matches"
  assert_equals "$(r check tab anything)" batch "tabs separate fields"
  assert_equals "$(r check final p)" silent "a final rule line with no newline still counts: the shell cats each file and adds one"
  assert_equals "$(r heartbeat unknown p)" now "no matching rule is now"
  pass "rule patterns follow the shell's case grammar"
)

test_status_file_decides_status_events() (
  dir=$(make_case status)
  rules=$dir/rules
  printf 'silent signal *.status working*\nbatch signal *.status done*\nnow * * *\n' > "$rules"
  r() { route "$dir/state" "$dir" signal "$1" 'signal: x' "$rules"; }
  printf 'working [at=1]: a\n' > "$dir/state/a.status"
  printf 'working [at=1]: a\ndone [at=2]: b\n' > "$dir/state/b.status"
  printf 'done [at=1]: a\n\n' > "$dir/state/c.status"
  ln -s /nonexistent "$dir/state/d.status"
  assert_equals "$(r a.status)" silent "the status file's newest line names the state word"
  assert_equals "$(r b.status)" batch "the newest line wins over an older one"
  assert_equals "$(r c.status)" now "a blank newest line leaves the recorded payload, which names no state"
  assert_equals "$(r d.status)" now "a symlink is never followed"
  assert_equals "$(r missing.status)" now "an absent file falls back to the recorded payload"
  pass "a status event is matched against its status file's newest line"
)

test_queue_quiet_cannot_loop() (
  dir=$(make_case quiet)
  rules=$dir/rules
  printf 'silent@queue-quiet check rearm-resurface *\nnow * * *\n' > "$rules"
  : > "$dir/state/.wake-queue"
  assert_equals "$(route "$dir/state" "$dir" check rearm-resurface x "$rules")" silent "an empty queue is quiet"
  printf '1\t1\tsignal\tx.status\tneeds-decision: y\n' > "$dir/state/.wake-queue"
  assert_equals "$(route "$dir/state" "$dir" check rearm-resurface x "$rules")" now "an urgent queued row is not quiet"
  # A queued re-arm row is routed by the same rule, which reads the queue again. The shell recursed
  # until it died; the port stops after a bound and treats the queue as not quiet.
  printf '1\t1\tcheck\trearm-resurface\tx\n' > "$dir/state/.wake-queue"
  out=$(route "$dir/state" "$dir" check rearm-resurface x "$rules"; echo "rc=$?")
  assert_contains "$out" "rc=0" "a rule that reads the queue it routes still ends"
  pass "queue-quiet answers and always ends"
)

test_append_dedupes_repeats_and_never_hides() (
  dir=$(make_case append)
  out=$(JG_STATE_OVERRIDE="$dir/state" JG_HOME="$dir" bash -c '. "$1/bin/jg-wake-lib.sh"
    jg_wake_bus() { :; }
    for i in 1 2; do
      jg_wake_append_locked check alert-host--memory "check: ready work"
      printf "%s " "$JG_WAKE_LAST"
    done
    jg_wake_append_locked check alert-host--memory "check: other work"
    printf "%s\n" "$JG_WAKE_LAST"' _ "$ROOT" 2>&1)
  assert_equals "$out" "now:alert-host--memory batch:alert-host--memory now:alert-host--memory" \
    "an unchanged now event inside the re-alert window rides the digest; a changed one wakes"
  # With no Go to build the router, an event is urgent rather than hidden.
  out=$(JG_WAKE_CORE_BIN="$dir/none/jg-wake-core" JG_WAKE_CORE_GO="$dir/no-such-go" JG_STATE_OVERRIDE="$dir/state2" \
    JG_HOME="$dir" bash -c '. "$1/bin/jg-wake-lib.sh"
    jg_wake_bus() { :; }
    printf "%s " "$(jg_wake_route_class signal crew.turn-ended x)"
    jg_wake_append_locked signal crew.turn-ended "signal: x"
    printf "%s\n" "$JG_WAKE_LAST"' _ "$ROOT" 2>/dev/null)
  assert_equals "$out" "now now:crew.turn-ended" "with no runnable router every event is now"
  pass "appends dedupe repeats, and a missing router hides nothing"
)

result=0
test_recorded_events_keep_their_class || result=1
test_pattern_grammar || result=1
test_status_file_decides_status_events || result=1
test_queue_quiet_cannot_loop || result=1
test_append_dedupes_repeats_and_never_hides || result=1
exit "$result"

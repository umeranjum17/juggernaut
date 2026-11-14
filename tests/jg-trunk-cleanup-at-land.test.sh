#!/usr/bin/env bash
# Integration test for cleanup inside the landing step (slice H51a, core/trunk-landing/cleanup-retry.sh), through the real
# core/trunk-landing/trunk-landing.sh `runbatch` over real lanes (tests/jg-trunk-fixture.sh). The lander (bin/jg-trunk.sh) and the
# teardown are stand-ins in the fixture home, because the test needs to control what they print and when.
#
# K1 A stack is cleaned lane by lane at each lane's own landed line: the first lane is cleaned up while the lander is still running.
# K2 A refusal that only needs time (a slot allocation in progress) is retried on the ladder and the lane is cleaned on the retry.
# K3 Any other refusal (uncommitted changes) gets its reason from the closed list, is tried once, and raises one alert.
# K4 A time-only refusal that never clears is final when the ladder ends (4 retries), with one alert.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"
# shellcheck disable=SC2034 # read by the fixture
JG_TRUNK_FIXTURE_CACHE=1

mem() { printf '%s\n' "$HOME_D/data/jg-trunk-landing"; }
wait_for() {  # <what> <command...>
  local what=$1 _; shift
  for _ in $(seq 1 200); do "$@" && return 0; sleep 0.1; done
  fail "never reached: $what"
}

# A home whose lander prints one landed line per lane, with a pause after each, and whose teardown follows <mode-file> per lane:
# `ok`, `time` (a slot allocation in progress, until the lane's call count reaches <n>), `uncommitted` or `time-always`.
# shellcheck disable=SC2016 # the stand-in bodies are written out verbatim and expand when they run
stub_world() {  # <name>
  world "$1"
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  cat > "$HOME_D/bin/jg-trunk.sh" <<SH
#!/usr/bin/env bash
[ "\$1" = land-batch ] || exit 1
shift
for a in "\$@"; do
  echo "landed \${a%%@*} on trunk (stand-in)"
  sleep 1
done
: > "$W/lander-ended"
SH
  cat > "$HOME_D/bin/jg-teardown.sh" <<SH
#!/usr/bin/env bash
id=\$1
printf '%s %s\n' "\$id" "\$([ -e "$W/lander-ended" ] && echo after || echo during)" >> "$W/teardown-calls"
n=\$(grep -c "^\$id " "$W/teardown-calls")
mode=\$(cat "$W/mode-\$id" 2>/dev/null || echo ok)
case \$mode in
  time) [ "\$n" -ge 3 ] || { echo "REFUSED: another Treehouse slot allocation or return is in progress for proj; the task record is kept, rerun teardown" >&2; exit 1; } ;;
  time-always) echo "REFUSED: another Treehouse slot allocation or return is in progress for proj; the task record is kept, rerun teardown" >&2; exit 1 ;;
  uncommitted) echo "teardown: cleanup refused, reason: uncommitted" >&2; exit 1 ;;
esac
rm -f "$HOME_D/state/\$id.meta"
SH
  chmod +x "$HOME_D/bin/jg-trunk.sh" "$HOME_D/bin/jg-teardown.sh"
}
run_stack() {  # <id>...: the landing check's stack run over the lanes, as `check` starts it
  local args=() id
  for id in "$@"; do args+=("$id@$(git -C "$PROJ" rev-parse "fm/$id")"); done
  JG_TEST_SEAM=1 JG_CLEANUP_LADDER="${LADDER:-0.2 0.2 0.2 0.2}" JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" \
    bash "$ROOT/core/trunk-landing/trunk-landing.sh" runbatch "$HOME_D" "${args[@]}" >"$W/run.out" 2>&1 || fail "the stack run must not fail: $(tail -5 "$W/run.out")"
}
state_of() { cat "$(mem)/$1".*.state 2>/dev/null | head -n 1; }
alerts() { local n; n=$(grep -c "ALERT: $1" "$(mem)/outbox" 2>/dev/null) || n=0; echo "$n"; }

test_each_lane_is_cleaned_at_its_own_landed_line() {
  stub_world stream
  lane k1 one k1.txt; lane k2 two k2.txt; lane k3 three k3.txt
  run_stack k1 k2 k3
  [ "$(cat "$W/teardown-calls")" = "$(printf 'k1 during\nk2 during\nk3 during')" ] || fail "every lane is cleaned while the lander still runs: $(cat "$W/teardown-calls")"
  [ "$(grep -c . "$W/teardown-calls")" = 3 ] || fail "each lane is cleaned once"
  for id in k1 k2 k3; do [ "$(state_of $id)" = 'landed cleaned up' ] || fail "$id state: $(state_of $id)"; done
  [ "$(grep -c '^trunk-landing: landed k' "$(mem)/outbox")" = 3 ] || fail "one outbox line per lane"
  pass 'a stack is cleaned lane by lane at each lane'"'"'s own landed line, while the lander still runs'
}

test_a_time_only_refusal_is_retried_and_cleaned() {
  stub_world retry
  lane t1 one t1.txt; lane t2 two t2.txt; echo time > "$W/mode-t1"
  run_stack t1 t2
  wait_for 'the retry cleans the lane' test "$(state_of t1)" = 'landed cleaned up'
  [ "$(grep -c '^t1 ' "$W/teardown-calls")" = 3 ] || fail "two refusals then a clean third attempt: $(cat "$W/teardown-calls")"
  [ ! -f "$HOME_D/state/t1.meta" ] || fail "the lane's record is gone once cleaned"
  [ "$(alerts t1)" = 0 ] || fail "a refusal that clears raises no alert"
  grep -q 't1: cleaned up on retry 2' "$(mem)/outbox" || fail "the retry is reported: $(cat "$(mem)/outbox")"
  pass 'a refusal that only needs time is retried on the ladder and the lane is cleaned on the retry'
}

test_any_other_refusal_has_its_reason_and_one_alert() {
  stub_world other
  lane u1 one u1.txt; lane u2 two u2.txt; echo uncommitted > "$W/mode-u1"
  run_stack u1 u2; sleep 1
  [ "$(state_of u1)" = 'landed cleanup refused, nothing was forced: reason: uncommitted' ] || fail "u1 state: $(state_of u1)"
  [ "$(grep -c '^u1 ' "$W/teardown-calls")" = 1 ] || fail "a non-time refusal is not retried"
  [ "$(alerts u1)" = 1 ] || fail "one alert: $(cat "$(mem)/outbox")"
  grep -q 'ALERT: u1 .*reason: uncommitted' "$(mem)/outbox" || fail "the alert names the reason"
  [ -f "$HOME_D/state/u1.meta" ] || fail "nothing is forced: the lane's record stays"
  pass 'any other refusal gets one reason from the closed list, is tried once and raises one alert'
}

test_a_refusal_that_never_clears_is_final_after_the_ladder() {
  stub_world final
  lane f1 one f1.txt; lane f2 two f2.txt; echo time-always > "$W/mode-f1"
  run_stack f1 f2
  wait_for 'the ladder ends' test "$(alerts f1)" = 1
  [ "$(grep -c '^f1 ' "$W/teardown-calls")" = 5 ] || fail "one attempt and four retries: $(cat "$W/teardown-calls")"
  [ "$(state_of f1)" = 'landed cleanup refused, nothing was forced: reason: check-failed' ] || fail "f1 state: $(state_of f1)"
  pass 'a time-only refusal that never clears is final when the ladder ends, with one alert'
}

test_each_lane_is_cleaned_at_its_own_landed_line
test_a_time_only_refusal_is_retried_and_cleaned
test_any_other_refusal_has_its_reason_and_one_alert
test_a_refusal_that_never_clears_is_final_after_the_ladder
printf 'jg-trunk-cleanup-at-land: ok\n'

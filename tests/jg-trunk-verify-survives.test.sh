#!/usr/bin/env bash
# Integration test: a verify that has started runs to its own result (ticket jg-qj0ct), through the real detached job
# (core/trunk-landing/trunk-landing.sh verify) and the real tick, on tests/jg-trunk-fixture.sh.
#  1. A lane lands while the verify runs: the running verify ends green and the pin moves to its commit; the verify of the newer tip
#     starts only after it and ends too. Neither attempt ends "stopped by signal TERM".
#  2. The tick's own process group is stopped while the verify runs (the way the watcher stops a check): the verify still ends green.
#  3. A lane lands while the verify runs past its lock lease, and the lock-lease check runs (ticket jg-eqs3k.1): the verify beats its
#     lock, so the check leaves it running and it ends green, not "stopped by signal TERM".
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

tip_after_land() { trunk land "$1" >/dev/null 2>&1 || fail "$1 must land"; tip; }
verify_rows() { cut -f5 "$HOME_D/data/trunk-verify.tsv" 2>/dev/null | paste -sd, -; }
# a whole-suite gate that records its commit and runs <seconds> (default 20), so a landing and a group stop both happen inside it
slow_gate() {  # [<seconds>]
  # shellcheck disable=SC2016 # written verbatim, expands when the gate runs it
  printf '#!/usr/bin/env bash\ngit rev-parse HEAD >> %s/verify-ran\nsleep %s\n' "$W" "${1:-20}" > "$W/slow.sh"
  printf 'gate-verify=bash %s/slow.sh\ngate-full=true\n' "$W" >> "$HOME_D/config/trunk-policy"
  # the home the detached job runs in, with the pin below the tip so a verify is due
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  tip > "$HOME_D/state/trunk-green-proj"
}
start_verify() { # sets VPID: the job exactly as the tick starts it, in the tick's process group
  JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" verify "$HOME_D" proj >/dev/null 2>&1 & VPID=$!
  for _ in $(seq 1 100); do [ -s "$W/verify-ran" ] && return 0; sleep 0.1; done
  fail "the verify must be running"
}
no_term() { ! grep -rqs 'signal TERM' "$HOME_D"/data/trunk/verify-*.log || fail "no verify may end stopped by a signal: $(cat "$HOME_D"/data/trunk/verify-*.log)"; }

test_a_landing_during_a_verify_does_not_stop_it_and_the_newer_tip_is_verified_after_it() {
  local c2 n
  world survive1; slow_gate
  lane s1 one a.txt; tip_after_land s1 >/dev/null
  start_verify
  lane s2 two b.txt; c2=$(tip_after_land s2)
  sweep >/dev/null
  wait "$VPID" 2>/dev/null || :
  [ "$(cut -f5 "$HOME_D/data/trunk-verify.tsv" | head -n 1)" = green ] || fail "the first verify must end green: $(cat "$HOME_D/data/trunk-verify.tsv")"
  sweep >/dev/null  # the next tick, now that the slot is free
  for n in $(seq 1 400); do [ "$(cat "$HOME_D/state/trunk-green-proj" 2>/dev/null)" = "$c2" ] && break; sleep 0.2; done
  [ "$(cat "$HOME_D/state/trunk-green-proj" 2>/dev/null)" = "$c2" ] || fail "the verify of the newer tip must end green and move the pin: $(verify_rows)"
  no_term
  pass 'a landing during a verify does not stop it; the newer tip is verified after it'
}

test_a_group_stop_of_the_tick_does_not_stop_a_running_verify() {
  local pg
  world survive2; slow_gate
  lane g1 one a.txt; tip_after_land g1 >/dev/null
  # the tick itself (check), in a process group of its own, as the watcher runs a check; it starts the verify detached and ends
  set -m
  JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" >/dev/null 2>&1 & VPID=$!
  set +m
  for _ in $(seq 1 100); do [ -s "$W/verify-ran" ] && break; sleep 0.1; done
  [ -s "$W/verify-ran" ] || fail "the verify must be running"
  pg=$(ps -o pgid= -p "$VPID" | tr -d ' ')
  kill -TERM -- "-$pg" 2>/dev/null || :   # what the watcher does to a check that ran past its time limit
  sleep 1
  for _ in $(seq 1 300); do [ -s "$HOME_D/data/trunk-verify.tsv" ] && break; sleep 0.2; done
  [ "$(cut -f5 "$HOME_D/data/trunk-verify.tsv" | head -n 1)" = green ] || fail "the verify must end green after its group was stopped: $(cat "$HOME_D"/data/trunk/verify-*.log 2>&1)"
  no_term
  pass "a stop of the tick's process group does not stop a running verify"
}

# The verify runs as its systemd unit runs it, leading its own process group, so the lease's group stop would reach the whole gate.
# A short lease and beat stand in for the 600 s lease and 60 s beat; the gate outlasts the lease three times over.
test_a_verify_past_its_lock_lease_keeps_running_through_a_landing_and_the_lease_check() {
  local lock out since
  world lease1; slow_gate 40
  lane l1 one a.txt; tip_after_land l1 >/dev/null
  export JG_LOCK_LEASE_WARN_S=4 JG_LOCK_LEASE_END_S=6 JG_LOCK_BEAT_S=1
  JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" setsid bash "$ROOT/core/trunk-landing/trunk-landing.sh" verify "$HOME_D" proj >/dev/null 2>&1 < /dev/null &
  VPID=$!
  for _ in $(seq 1 100); do [ -s "$W/verify-ran" ] && break; sleep 0.1; done
  [ -s "$W/verify-ran" ] || fail "the verify must be running"
  lock=$HOME_D/state/.trunk-autoverify-proj.lock
  [ "$(cat "$lock/pid" 2>/dev/null)" = "$VPID" ] || fail "fixture: the verify job must hold its lock as its group leader"
  lane l2 two b.txt; tip_after_land l2 >/dev/null
  since=$(cat "$lock/since")
  while [ $(( $(date +%s) - since )) -le 8 ]; do sleep 0.5; done
  out=$(JG_STATE_OVERRIDE="$HOME_D/state" bash "$ROOT/core/lock-lease/lock-lease.check.sh" "$HOME_D" 2>&1)
  case $out in *autoverify*) fail "the lease check must leave a beating verify alone: $out" ;; esac
  kill -0 "$VPID" 2>/dev/null || fail "the verify job must still run after the lease check: $(cat "$HOME_D"/data/trunk/verify-*.log 2>&1)"
  wait "$VPID" 2>/dev/null || :
  unset JG_LOCK_LEASE_WARN_S JG_LOCK_LEASE_END_S JG_LOCK_BEAT_S
  [ "$(cut -f5 "$HOME_D/data/trunk-verify.tsv" | head -n 1)" = green ] || fail "the verify must run to its result: $(cat "$HOME_D"/data/trunk/verify-*.log 2>&1)"
  no_term
  pass 'a verify past its lock lease keeps running through a landing and the lease check, and ends green'
}

# The user manager refuses the unit (a stand-in systemd-run that refuses a unit and, in the second run, also a scope): the tick still
# starts the verify, tries the scope first, logs why the unit was refused, and the verify ends with its own result.
test_a_refused_unit_falls_back_to_a_scope_then_setsid_and_logs_why() {
  local mode log
  for mode in scope-ok all-refused; do
    world "fallback-$mode"; slow_gate
    lane f1 one a.txt >/dev/null; tip_after_land f1 >/dev/null
    # shellcheck disable=SC2016 # the stand-in expands its own arguments
    printf '#!/usr/bin/env bash\necho "$*" >> "%s/sdrun-calls"\nfor a; do [ "$a" = --scope ] && scope=1; done\n[ "${scope:-}" = 1 ] && [ "%s" = scope-ok ] && { while [ "${1#--}" != "$1" ]; do shift; done; exec "$@"; }\necho "Failed to connect to bus: no such file" >&2; exit 1\n' "$W" "$mode" > "$W/fakebin/fake-systemd-run"
    chmod +x "$W/fakebin/fake-systemd-run"
    export JG_TRUNK_SYSTEMD_RUN=$W/fakebin/fake-systemd-run JG_TRUNK_SYSTEMCTL=
    sweep >/dev/null
    unset JG_TRUNK_SYSTEMD_RUN JG_TRUNK_SYSTEMCTL
    log=$HOME_D/data/jg-trunk-landing/unit-verify-proj.log
    assert_contains "$(cat "$log" 2>&1)" "systemd-run refused the unit (Failed to connect to bus" "$mode: the refusal and its reason must be logged"
    [ "$(grep -c -- '--scope' "$W/sdrun-calls")" -ge 1 ] || fail "$mode: a scope must be tried after the unit is refused"
    for _ in $(seq 1 300); do [ -s "$HOME_D/data/trunk-verify.tsv" ] && break; sleep 0.2; done
    [ "$(cut -f5 "$HOME_D/data/trunk-verify.tsv" 2>/dev/null | head -n 1)" = green ] || fail "$mode: the verify must still run to green: $(cat "$log" 2>&1)"
    no_term
  done
  pass 'a refused unit falls back to a scope, then setsid, logs why, and the verify still ends green'
}

test_a_landing_during_a_verify_does_not_stop_it_and_the_newer_tip_is_verified_after_it
test_a_refused_unit_falls_back_to_a_scope_then_setsid_and_logs_why
test_a_group_stop_of_the_tick_does_not_stop_a_running_verify
test_a_verify_past_its_lock_lease_keeps_running_through_a_landing_and_the_lease_check
printf 'jg-trunk-verify-survives: ok\n'

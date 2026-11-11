#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh: a move of the homes never lands on a running gate (jg-7v6uw-s04).
# Through tests/jg-trunk-fixture.sh it runs bin/jg-trunk.sh over a real project and trunk, with a landing whose gate waits for a
# file, so a landing is running while each of the three callers of go_live asks for the move: the automatic go-live (autolive),
# the go-live on a word (live) and the pin-back after a red CI result (ci red). For each:
#    the move prints "waiting" and makes no move while the gate runs, a second landing's gate does not start while the move is
#    pending, and once the running gate ends the move happens, before that second gate starts.
JG_TRUNK_FIXTURE_CACHE=1
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# The landing gate: it logs its start and end in $W/events and runs while $W/hold exists. The live hook logs each move there too.
# shellcheck disable=SC2016 # the hook's body is written out verbatim and expands when the hook runs
set_gate() {
  printf 'gate-full=echo gate-start >> %s/events; while [ -e %s/hold ]; do sleep 0.1; done; echo gate-end >> %s/events\n' "$W" "$W" "$W" >> "$HOME_D/config/trunk-policy"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$2" >> "%s/live-moves"; echo move >> "%s/events"\n' "$W" "$W" > "$HOME_D/config/live-hook.proj"
}

# wait_for <what> <command...>: poll for up to 20 s
wait_for() {
  local what=$1; shift
  for _ in $(seq 1 200); do "$@" && return 0; sleep 0.1; done
  fail "timed out waiting for $what: $(cat "$W"/land2.out "$W"/move.out 2>&1 | tail -n 8)"
}
gate_running() { compgen -G "$HOME_D/state/.trunk-gate-proj-*.lock" >/dev/null && [ "$(count_of gate-start)" = 1 ]; }
count_of() { grep -c "^$1\$" "$W/events" 2>/dev/null || true; }
events_line() { tr '\n' ' ' < "$W/events"; }

# guard_case <caller> <n>: a landing is running its gate, the caller asks to move the homes, and a later landing asks to start.
guard_case() {
  local caller=$1 n=$2 second=r$2-second late=r$2-late pid1 pid2 pidm
  lane "$second" two "b$n.txt"; : > "$W/hold"; : > "$W/events"; rm -f "$W/live-moves"
  trunk land "$second" > "$W/land2.out" 2>&1 & pid2=$!
  wait_for "the running landing's gate" gate_running
  case $caller in
    autolive) trunk autolive "$PROJ" > "$W/move.out" 2>&1 & pidm=$! ;;
    live)     trunk live "$PROJ" > "$W/move.out" 2>&1 & pidm=$! ;;
    ci)       trunk ci "$PROJ" "$(tip)" red > "$W/move.out" 2>&1 & pidm=$! ;;
  esac
  wait_for "the move to say it waits" grep -q waiting "$W/move.out"
  assert_contains "$(cat "$W/move.out")" "a landing's gate is running" "$caller must say which wait it is in"
  [ ! -e "$W/live-moves" ] || fail "$caller must make no move while a gate runs: $(events_line)"
  kill -0 "$pid2" 2>/dev/null || fail "the move must not end the running landing: $(cat "$W/land2.out")"

  # A landing that starts while the move is pending waits for the move: its gate does not start yet.
  lane "$late" three "c$n.txt"
  trunk land "$late" > "$W/land3.out" 2>&1 & pid1=$!
  sleep 1
  [ "$(count_of gate-start)" = 1 ] || fail "no gate may start while a move is pending: $(events_line)"

  rm -f "$W/hold"
  wait "$pid2" || fail "the running landing must still land: $(cat "$W/land2.out")"
  wait "$pidm" || fail "$caller must complete once the gate ends: $(cat "$W/move.out")"
  wait "$pid1" || fail "the late landing must land after the move: $(cat "$W/land3.out")"
  [ "$(tip)" = "$(git -C "$PROJ" rev-parse "fm/$late")" ] || fail "the late landing must be on the trunk"

  # order: the running gate starts and ends, the move, then the late landing's gate starts (a late gate that the trunk move
  # of the first landing makes run again is the landing's own rule, not the move's)
  [ "$(count_of move)" = 1 ] || fail "the homes move once: $(events_line)"
  case $(events_line) in "gate-start gate-end move gate-start gate-end "*) ;; *) fail "the move must come between the two gates, not inside one: $(events_line)" ;; esac
  [ -z "$(compgen -G "$HOME_D/state/.trunk-move-proj*")" ] || fail "the move must let its place go: $(ls -a "$HOME_D/state")"
  if grep -rl Terminated "$HOME_D/data/jg-trunk-landing" "$HOME_D/data/trunk" 2>/dev/null | grep -q .; then fail "no gate log may end Terminated"; fi
  pass "a running landing is never killed by the $caller move: it waits, then moves before the next gate starts"
}

test_each_go_live_waits_for_a_running_landing() {
  world guard
  lane first one a.txt
  trunk land first >/dev/null 2>&1 || fail "fixture: the first lane must land"
  set_gate
  trunk waiver "$PROJ" --rule owner-rule-test >/dev/null || fail "the waiver must be written"
  printf 'live-quiet-minutes=0\n' >> "$HOME_D/config/trunk-policy"
  guard_case autolive 1
  guard_case live 2
  guard_case ci 3
}

test_each_go_live_waits_for_a_running_landing
printf 'jg-trunk-golive-guard: ok\n'

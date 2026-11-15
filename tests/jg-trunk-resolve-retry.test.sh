#!/usr/bin/env bash
# Integration test for the kept resolution (bin/jg-trunk.sh lane_admit and chain_on), through the real landing check and the real
# admission path over real git repositories (tests/jg-trunk-fixture.sh). The stand-in gate holds one named lane until the case lets
# its n-th run end, so another landing moves the trunk while that lane is gated, with no wall clock in the case.
#
# R1 Single path: a lane the resolver resolved is gated; a landing moves the trunk meanwhile; the lane is admitted again on the new tip.
#    The resolver ran once, the gate twice, the retest twice, and the lane lands.
# R2 Batch path: a resolved lane stacked in a batch whose trunk moves is not returned to its worker (a wait, "lands on next try with the
#    resolution kept"); it lands on the next try with one resolver call.
# R3 A trunk move that edits the resolved lines cannot replay the kept resolution: the resolver runs a second time.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"
# shellcheck disable=SC2034 # read by the fixture
JG_TRUNK_FIXTURE_CACHE=1

# shellcheck disable=SC2016 # the gate body is written out verbatim and expands when the gate runs it
move_world() {  # <name>: a world whose gate holds a lane that has a file $W/hold-<lane> until $W/go-<lane>-<n>
  world "$1"
  ln -sn "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  cat > "$W/hold-gate.sh" <<SH
#!/usr/bin/env bash
id=\$(git log -1 --format=%s | sed 's/^ticket //')
printf 'start %s\n' "\$id" >> "$W/gate-runs"
n=\$(grep -c "^start \$id\$" "$W/gate-runs")
if [ -f "$W/hold-\$id" ]; then for _ in \$(seq 1 300); do [ -f "$W/go-\$id-\$n" ] && break; sleep 0.1; done; fi
printf 'end %s\n' "\$id" >> "$W/gate-runs"
! grep -rq BAD --include='*.txt' .
SH
  printf 'gate-full=bash %s/hold-gate.sh\ngate-slots=1\nretest-runner=true\n' "$W" >> "$HOME_D/config/trunk-policy"
  # shellcheck disable=SC2016 # the resolver expands its own variables; it counts its calls and takes the lane's side of every file
  resolver count 'echo x >> "$0.calls"; while IFS= read -r f; do printf "merged\n" > "$f"; done < "$JG_RESOLVE_CONFLICTS"'
}
runs() { local n; n=$(grep -c "^start $1\$" "$W/gate-runs" 2>/dev/null); echo "${n:-0}"; }  # <lane>: gate runs it has started
kick() { JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" >/dev/null || fail "the check must not fail"; }
wait_for() {  # <what> <command...>: poll a condition for up to 30 seconds
  local what=$1 _; shift
  for _ in $(seq 1 300); do "$@" && return 0; sleep 0.1; done
  fail "never reached: $what"
}
runs_reach() { [ "$(runs "$1")" -ge "$2" ]; }  # <lane> <n>
settled() { [ -z "$(jg_test_detached_alive)" ]; }  # no landing job of the check is alive
trunk_has() { [ "$(git -C "$PROJ" rev-list --count "$1..trunk")" = "$2" ]; }  # <base> <n>
quiet() { rm -f "$HOME_D/state/$1.status"; }  # the lane's done line is taken back: the check never starts it
mover() {  # <id> <file>: a lane that conflicts with nothing lands through the same lander while another lane is gated
  lane "$1" "$1" "$2.txt"; quiet "$1"; trunk land "$1" >/dev/null 2>&1 || fail "mover $1 must land"
}
calls() { local n; n=$(grep -c x "$W/count.sh.calls" 2>/dev/null); echo "${n:-0}"; }  # resolver calls
rows() { local n; n=$(grep -c "$2" "$HOME_D/data/$1" 2>/dev/null); echo "${n:-0}"; }  # <tsv> <state>
attempt_logs() { cat "$HOME_D"/data/jg-trunk-landing/"$1".*.attempt-*/landing.log 2>/dev/null; }

test_a_resolved_lane_is_not_resolved_again_when_the_trunk_moves() {
  local base
  move_world single; base=$(tip)
  lane ca first; lane cb second
  quiet ca; trunk land ca >/dev/null 2>&1 || fail "ca must land"
  : > "$W/hold-cb"
  kick; wait_for 'cb gates after its resolution' runs_reach cb 1
  mover m1 m1; touch "$W/go-cb-1"
  wait_for 'cb gates again' runs_reach cb 2; touch "$W/go-cb-2"
  wait_for 'the check is done' settled; wait_for 'trunk holds ca, m1, cb' trunk_has "$base" 3
  [ "$(calls)" = 1 ] || fail "the resolver runs once, ran $(calls) times"
  [ "$(runs cb)" = 2 ] || fail "the lane is gated twice, ran $(runs cb) times"
  [ "$(rows trunk-landing-phases.tsv retesting)" = 2 ] || fail "two retesting rows, got $(rows trunk-landing-phases.tsv retesting)"
  [ "$(rows trunk-resolving.tsv resolving)" = 1 ] || fail "one resolving row, got $(rows trunk-resolving.tsv resolving)"
  [ "$(git -C "$PROJ" show trunk:work.txt)" = merged ] || fail "the trunk holds the resolved file"
  pass 'a trunk move after a resolution replays the kept resolution: 1 resolver call, 2 gate runs, 2 retests, the lane lands'
}

test_a_resolved_lane_in_a_batch_waits_with_its_resolution_kept() {
  local base out pid
  move_world batch; base=$(tip)
  lane ca first; lane cb second
  quiet ca; trunk land ca >/dev/null 2>&1 || fail "ca must land"
  lane cc other other.txt; quiet cc; quiet cb
  : > "$W/hold-cc"  # the stack gates under the commit on top of it: cc
  out=$(mktemp); trunk land-batch cb cc > "$out" 2>&1 &
  pid=$!
  wait_for 'the stack gates after the resolution' runs_reach cc 1
  mover m1 m1; touch "$W/go-cc-1"; wait_for 'cc gates again on the moved trunk' runs_reach cc 2
  touch "$W/go-cc-2"; wait "$pid" || true
  grep -q 'lands on next try with the resolution kept' "$out" || fail "the lane waits with its resolution kept: $(cat "$out")"
  ! grep -q 'conflicts with trunk' "$out" || fail "the resolved lane is not returned for a conflict: $(cat "$out")"
  grep -q 'refusal-class cb: wait' "$out" || fail "the return is a wait, not a final return: $(cat "$out")"
  [ ! -s "$W/send-calls" ] || fail "the worker is not steered: $(cat "$W/send-calls")"
  trunk land cb > "$out" 2>&1 || fail "the next try lands the lane: $(cat "$out")"
  rm -f -- "$out"
  trunk_has "$base" 4 || fail "trunk holds ca, m1, cc, cb"
  [ "$(calls)" = 1 ] || fail "the resolver runs once, ran $(calls) times"
  pass 'a resolved lane stacked in a moved batch is a wait, not a return, and lands on the next try with one resolver call'
}

test_a_trunk_move_that_edits_the_resolved_lines_is_resolved_again() {
  local base
  move_world edit; base=$(tip)
  lane ca first; lane cb second
  quiet ca; trunk land ca >/dev/null 2>&1 || fail "ca must land"
  : > "$W/hold-cb"
  kick; wait_for 'cb gates after its resolution' runs_reach cb 1
  lane m2 third; quiet m2; git -C "$W/lanes/m2" reset -q --hard trunk
  commit_in "$W/lanes/m2" work.txt edited "ticket m2"; prove m2; trunk land m2 >/dev/null 2>&1 || fail "m2 must land"
  touch "$W/go-cb-1"; wait_for 'cb gates again' runs_reach cb 2; touch "$W/go-cb-2"
  wait_for 'the check is done' settled
  [ "$(calls)" = 2 ] || fail "a move over the resolved lines resolves again: $(calls) calls"
  pass 'a trunk move that edits the resolved lines cannot replay the kept resolution, so the resolver runs again'
}

test_a_resolved_lane_is_not_resolved_again_when_the_trunk_moves
test_a_resolved_lane_in_a_batch_waits_with_its_resolution_kept
test_a_trunk_move_that_edits_the_resolved_lines_is_resolved_again
printf 'jg-trunk-resolve-retry: ok\n'

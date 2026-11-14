#!/usr/bin/env bash
# Integration test for the move `bypass` (bin/jg-proof-bypass-apply.sh, called by bin/jg-delivery-tick.sh; the landing's guard in
# bin/jg-merge-gate-lib.sh). Through tests/jg-trunk-fixture.sh it runs the real tick, the real jg-trunk.sh and the real landing check,
# and stands in for the backlog (it records its calls), the captain hold, send, teardown and done-done.
#
# T1 A ticket under a standing bypass goes from the done line to queued with no done-done run: the tick ends a run under way with
#    abort, makes the move, writes bypassed_at and the record for that exact commit (commit, scope, word id, "no proof ran"); the
#    landing takes the record where it takes a receipt, and the lane lands.
# T2 The same lane with the bypass ended, a ticket outside the scope, and a record written by hand: proved as before, none passes.
# T3 A rebase gives the lane a new commit: the tick writes the record again, with no second move, and the lane lands.
# T4 The worker's own done is accepted while a bypass stands and refused when it has ended.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# A done-done stand-in: it keeps a log of its calls; `status` reports a run under way (exit 4) until `abort` was called.
fake_done_done() {
  cat > "$W/fakebin/done-done" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/done-done-calls"
case "\$1" in
  status) [ -e "$W/aborted" ] && exit 0; exit 4 ;;
  abort) : > "$W/aborted" ;;
esac
SH
  chmod +x "$W/fakebin/done-done"
}
setup() {  # <name>
  world "$1"; cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  fake_done_done
  rm -f "$HOME_D/bin/jg-fleet-ledger.sh"; cp "$W/root/bin/jg-fleet-ledger.sh" "$HOME_D/bin/"
}
# unproved <id> <file>: a lane with one commit and a done line, and none of the proof.
unproved() {
  local id=$1 wt="$W/lanes/$1"
  git -C "$PROJ" worktree add -q -b "fm/$id" "$wt" trunk
  commit_in "$wt" "$2" "the change of $id" "ticket $id"
  jg_write_meta "$HOME_D/state/$id.meta" "project=$PROJ" "mode=local-trunk" "branch=fm/$id" "worktree=$wt" "spawn_gen=g-$id"
  ready "$id"
}
pb() { JG_HOME="$HOME_D" JG_STATE_OVERRIDE="$HOME_D/state" JG_CONFIG_OVERRIDE="$HOME_D/config" JG_DATA_OVERRIDE="$HOME_D/data" bash "$W/root/bin/jg-proof-bypass.sh" "$@"; }
apply() { PATH="$W/fakebin:$PATH" bash "$W/root/bin/jg-proof-bypass-apply.sh" "$HOME_D" >/dev/null; }
tick() {  # one pass of the real tick, then wait for the detached landings it started
  PATH="$W/fakebin:$PATH" bash "$W/root/bin/jg-delivery-tick.sh" "$HOME_D" >/dev/null 2>&1
  for _ in $(seq 1 100); do grep -qs '^running' "$HOME_D"/data/jg-trunk-landing/*.state || break; sleep 0.2; done
}
record() { printf '%s/state/%s.bypass-record.json' "$HOME_D" "$1"; }
moves() { local n; n=$(grep -c "	$1	.*	bypass	" "$HOME_D/data/moves.log" 2>/dev/null); echo "${n:-0}"; }
landed() { git -C "$PROJ" cat-file -e "trunk:$1" 2>/dev/null; }

test_a_ticket_under_a_bypass_skips_proving_and_lands() {
  local id=b1 head out
  setup t1; pb grant --project proj --word owner-rule-t1 >/dev/null || fail "the grant"
  unproved $id b1.txt; head=$(git -C "$PROJ" rev-parse fm/$id)
  out=$(trunk proof $id 2>&1) && fail "without the tick the lane has no proof"
  assert_contains "$out" "no completion receipt" "before the tick the proof is missing"
  tick
  [ -f "$(record $id)" ] || fail "the tick must write the bypass record"
  assert_equals "bypass" "$(jq -r .kind "$(record $id)")" "the record is a bypass"
  assert_equals "$head" "$(jq -r .commit "$(record $id)")" "the record names the exact commit"
  assert_equals "project" "$(jq -r .scope "$(record $id)")" "the record names the scope"
  assert_equals "owner-rule-t1" "$(jq -r .word "$(record $id)")" "the record names the word id"
  assert_equals "no proof ran" "$(jq -r .proof "$(record $id)")" "the record says no proof ran"
  assert_equals 1 "$(moves $id)" "one move bypass is on record"
  assert_contains "$(cat "$W/backlog-calls")" "moment $id bypassed_at" "bypassed_at is written on the ticket's row"
  assert_contains "$(cat "$W/done-done-calls")" "abort" "a run under way is ended with abort"
  ! grep -q '^run' "$W/done-done-calls" || fail "no done-done run may start"
  assert_contains "$(pb list)" "uses=1" "the use is counted"
  landed b1.txt || fail "the bypassed lane must land"
  pass 'a ticket under a bypass goes from the done line to the landing with no done-done run, its record naming commit, scope, word and no proof'
}

test_a_ticket_outside_the_scope_or_after_the_end_is_proved_as_before() {
  local id
  setup t2; pb grant --ticket other-ticket --word owner-rule-t2 >/dev/null || fail "the grant"
  unproved c1 c1.txt; tick
  [ ! -e "$(record c1)" ] || fail "a ticket outside the scope must not get a record"
  assert_equals 0 "$(moves c1)" "no move for a ticket outside the scope"
  trunk proof c1 >/dev/null 2>&1 && fail "a ticket outside the scope is proved as before"
  # The bypass of this ticket ends before its tick: the next done line is proved.
  id=$(pb grant --ticket c2 --word owner-rule-t2 | awk '{ print $2 }'); unproved c2 c2.txt; pb end "$id" >/dev/null; tick
  [ ! -e "$(record c2)" ] || fail "an ended bypass must not get a record"
  trunk proof c2 >/dev/null 2>&1 && fail "a ticket whose bypass ended is proved as before"
  # A record written by hand names no bypass row, so it is no proof.
  unproved c3 c3.txt
  printf '{"kind":"bypass","task":"c3","commit":"%s","bypass":"bp-0-forged","word":"owner-rule-t2"}\n' "$(git -C "$PROJ" rev-parse fm/c3)" > "$(record c3)"
  trunk proof c3 >/dev/null 2>&1 && fail "a record with no bypass row behind it must not pass"
  landed c1.txt && fail "a lane outside the scope must not land"
  pass 'a ticket outside the scope, one whose bypass ended and a hand-written record are all still proved as before'
}

test_a_rebase_writes_the_record_again_for_the_new_commit() {
  local old new
  setup t3; pb grant --project proj --word owner-rule-t3 >/dev/null || fail "the grant"
  unproved d1 d1.txt; old=$(git -C "$PROJ" rev-parse fm/d1)
  apply; assert_equals "$old" "$(jq -r .commit "$(record d1)")" "the record names the commit of the done line"
  # The trunk moves under the lane, which is rebased with git itself.
  git -C "$PROJ" worktree add -q -b fm/d0 "$W/lanes/d0" trunk; commit_in "$W/lanes/d0" d0.txt 'other work' 'ticket d0'
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk "$(git -C "$W/lanes/d0" rev-parse HEAD)"
  git -C "$PROJ" rev-parse trunk > "$HOME_D/state/trunk-tip-proj"
  git -C "$W/lanes/d1" -c user.name=t -c user.email=t@example.invalid rebase -q trunk || fail "the rebase must apply"
  new=$(git -C "$PROJ" rev-parse fm/d1); [ "$new" != "$old" ] || fail "the rebase must give a new commit"
  trunk proof d1 >/dev/null 2>&1 && fail "the old record must not stand for the new commit"
  apply
  assert_equals "$new" "$(jq -r .commit "$(record d1)")" "the record names the rebased commit"
  assert_equals 1 "$(moves d1)" "a rebase makes no second move"
  assert_equals 1 "$(wc -l < "$HOME_D/data/moves.log" | tr -d ' ')" "the move log holds the one move"
  trunk proof d1 >/dev/null 2>&1 || fail "the record of the new commit is the proof"
  tick; landed d1.txt || fail "the rebased lane must land"
  pass 'after a rebase the tick writes the record again for the new commit and makes no second move'
}

test_the_workers_done_is_accepted_only_while_a_bypass_stands() {
  local id out
  setup t4; id=$(pb grant --project proj --word owner-rule-t4 | awk '{ print $2 }'); unproved e1 e1.txt
  out=$(done_gate e1) || fail "the done under a standing bypass must be accepted: $out"
  pb end "$id" >/dev/null
  out=$(done_gate e1) && fail "the done after the bypass ended must be refused: $out"
  assert_contains "$out" "no completion receipt" "the refusal names the missing proof"
  pass "the worker's done passes while a bypass stands and is refused once it has ended"
}

test_a_ticket_under_a_bypass_skips_proving_and_lands
test_a_ticket_outside_the_scope_or_after_the_end_is_proved_as_before
test_a_rebase_writes_the_record_again_for_the_new_commit
test_the_workers_done_is_accepted_only_while_a_bypass_stands

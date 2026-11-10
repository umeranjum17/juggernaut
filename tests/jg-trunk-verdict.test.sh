#!/usr/bin/env bash
# Integration test for the landing check's verdicts (core/trunk-landing/verdict.sh, called by core/trunk-landing/trunk-landing.sh):
# one rule decides wait, retry or final for a single landing and a stack alike, and a stored verdict holds only while its cause stands.
# Through tests/jg-trunk-fixture.sh it runs bin/jg-trunk.sh and the registered check over real git repositories, and stands in for
# bin/jg-captain-hold.sh, bin/jg-send.sh and bin/jg-teardown.sh.
#
# V1 A stack whose decisions read fails once is not final: the other lane lands, the failed one is tried again after its backoff and lands.
# V2 A conflict verdict stored on trunk tip T is skipped while the tip is T (no new attempt, one report); when the tip moves it is tried
#    again once per tip, and the report does not repeat while the reason is the same.
# V3 A conflict whose cause left the trunk (the commit it conflicted with was reverted) lands on the next sweep, and the worker is not
#    steered for the verdict once its tip is gone.
# V4 A conflict verdict written before the tip was stored (9 Nov: gc-a1 held one for a tip that was gone) is judged again.
# V5 A red gate the lane's own change caused stays final for its head when the tip moves: no new gate run, and the worker is still steered.
# V6 A moved-trunk final stored by a home on old code holds only while its tip record stands, then the head is tried again.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# home_world <name>: a fixture world whose home runs the check's scripts from its own bin, as a real home does.
home_world() { world "$1"; cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"; rm -f "$W/send-calls"; }
settle() {  # wait until no landing is running and the last one has let go of its run lock
  local _
  for _ in $(seq 1 600); do
    if ! grep -qs '^running' "$HOME_D"/data/jg-trunk-landing/*.state && ! compgen -G "$HOME_D/state/.trunk-run-*.lock" >/dev/null; then break; fi
    sleep 0.2
  done
}
state_of() { cat "$HOME_D/data/jg-trunk-landing/$1.$2.state" 2>/dev/null; }  # <id> <head>
attempts() { compgen -G "$HOME_D/data/jg-trunk-landing/$1.$2.request-*.log" | grep -c .; }  # landing runs the check started for <id> <head>
steers() { grep -c "^$1"$'\t' "$W/send-calls" 2>/dev/null; }
# The worker's last steer is an hour old, so refusal-reach would steer again now for a verdict that still holds.
age_steer() { local f="$HOME_D/data/jg-trunk-landing/$1.$2.refusal"; [ -f "$f" ] || fail "no refusal record for $1"; awk '{ $3 = 1; print }' "$f" > "$f.n" && mv "$f.n" "$f"; }
# hand_tip <name> <file> <content, or - to delete it>: the trunk moves by one commit the lander did not make (a revert, a hand repair)
# and the lander's own record of the tip follows it, so the next landing accepts the trunk.
hand_tip() {
  local wt="$W/hand-$1"
  git -C "$PROJ" worktree add -q --detach "$wt" trunk
  if [ "$3" = - ]; then git -C "$wt" rm -q "$2"; git -C "$wt" -c user.name=t -c user.email=t@example.invalid commit -q -m "hand $1"
  else commit_in "$wt" "$2" "$3" "hand $1"; fi
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk "$(git -C "$wt" rev-parse HEAD)"
  git -C "$PROJ" rev-parse trunk > "$HOME_D/state/trunk-tip-proj"
}
on_trunk() { [ "$(git -C "$PROJ" show "trunk:$1" 2>/dev/null)" = "$2" ]; }  # <file> <content>
# hold <id>: the lane is not ready yet (its last status line is no longer done); `ready <id>` reports it ready again.
hold() { printf 'working [at=1]: still at it\n' >> "$HOME_D/state/$1.status"; }
# conflict_world <name>: lane c (work.txt "three") off the first tip, then lane a (work.txt "one") lands, so c conflicts with the trunk.
conflict_world() {
  home_world "$1"
  lane c three; hold c; C=$(git -C "$PROJ" rev-parse fm/c)
  lane a one; sweep >/dev/null; settle
  on_trunk work.txt one || fail "lane a must land first"
  ready c
}

test_a_stack_whose_decisions_read_fails_once_is_tried_again_and_lands() {
  local s1 out
  home_world stack
  # The hold reader fails once for s1, as the 10 second backlog read bound did on 9 Nov, then answers.
  cat > "$HOME_D/bin/jg-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = blocking ] || exit 1
f=$JG_STATE_OVERRIDE/read-fails-$2; [ -f "$f" ] || exit 1
rm -f "$f"; echo "jg-captain-hold: backlog show $2 exceeded its 10s backlog read bound" >&2; exit 2
SH
  : > "$HOME_D/state/read-fails-s1"
  lane s1 one work1.txt; s1=$(git -C "$PROJ" rev-parse fm/s1); lane s2 two work2.txt
  out=$(sweep); settle
  on_trunk work2.txt two || fail "the other lane of the stack must land: $(state_of s1 "$s1")"
  case $(state_of s1 "$s1") in final*) fail "a failed read must not be final: $(state_of s1 "$s1")" ;; retry*|wait*) ;; *) fail "s1 must wait to be tried again: $(state_of s1 "$s1")" ;; esac
  assert_not_contains "$out" "s1 not landed" "a failed read is not reported as a refusal"
  touch -d '3 minutes ago' "$HOME_D/data/jg-trunk-landing/s1.$s1.state"
  sweep >/dev/null; settle; sweep >/dev/null; settle
  on_trunk work1.txt one || fail "the lane must land on the next sweep after its backoff: $(state_of s1 "$s1")"
  pass 'a stack whose decisions read fails once is tried again and lands; only its other lane landed on the first sweep'
}

test_a_conflict_verdict_holds_only_while_its_tip_stands() {
  local out n
  conflict_world retip
  out=$(sweep); settle
  case $(state_of c "$C") in final*conflicts*) ;; *) fail "c must be refused for its conflict: $(state_of c "$C")" ;; esac
  out="$out$(sweep)"; settle; out="$out$(sweep)"; settle
  [ "$(attempts c "$C")" = 1 ] || fail "a conflict on an unchanged tip must not be tried again: $(attempts c "$C") attempts"
  [ "$(printf '%s\n' "$out" | grep -c 'c not landed')" = 1 ] || fail "the conflict must be reported once: $out"
  hand_tip other other.txt x
  out=$(sweep); settle
  [ "$(attempts c "$C")" = 2 ] || fail "a moved tip must give the conflict one more attempt: $(attempts c "$C") attempts"
  case $(state_of c "$C") in final*conflicts*) ;; *) fail "c still conflicts on the new tip: $(state_of c "$C")" ;; esac
  out="$out$(sweep)"; settle; out="$out$(sweep)"; settle
  n=$(attempts c "$C"); [ "$n" = 2 ] || fail "the new verdict must hold on its own tip: $n attempts"
  assert_not_contains "$out" "c not landed" "the same conflict on a new tip is not reported again"
  pass 'a conflict verdict is skipped while its tip stands, tried once per tip change, and not reported again for the same reason'
}

test_a_conflict_whose_cause_left_the_trunk_lands_and_its_worker_is_not_steered() {
  local s0 out
  conflict_world revert
  sweep >/dev/null; settle; sweep >/dev/null; settle
  [ "$(steers c)" -ge 1 ] || fail "the worker must be steered while the conflict holds"
  age_steer c "$C"; s0=$(steers c)
  hand_tip undo-a work.txt -
  out=$(sweep); settle
  [ "$(steers c)" = "$s0" ] || fail "no steer for a verdict whose tip is gone: $(tail -n 1 "$W/send-calls")"
  assert_not_contains "$out" "c not landed" "a verdict whose tip is gone is not reported"
  on_trunk work.txt three || fail "the lane must land once the commit it conflicted with left the trunk: $(state_of c "$C")"
  pass 'a conflict whose cause left the trunk lands on the next sweep, and its worker is not steered once the tip is gone'
}

# The record the check wrote before it stored the tip: a conflict final with no tip beside it (9 Nov: gc-a1, tip ddcd9d465 gone).
test_a_conflict_verdict_stored_with_no_tip_is_judged_again() {
  local d
  home_world old-record
  lane o one; d=$(git -C "$PROJ" rev-parse fm/o); mkdir -p "$HOME_D/data/jg-trunk-landing"
  printf 'final REFUSED: fm/o conflicts with trunk (ddcd9d465000) in: work.txt; a lane rebases and fixes it, then reports ready again; it is never landed dirty\n' \
    > "$HOME_D/data/jg-trunk-landing/o.$d.state"
  sweep >/dev/null; settle
  on_trunk work.txt one || fail "a conflict verdict with no stored tip must be judged again: $(state_of o "$d")"
  pass 'a conflict verdict stored with no tip is judged again and the lane lands'
}

test_a_red_gate_the_lane_caused_stays_final_for_its_head() {
  local r s0 out
  home_world red
  lane r BAD; r=$(git -C "$PROJ" rev-parse fm/r)
  sweep >/dev/null; settle
  case $(state_of r "$r") in final*gate*) ;; *) fail "r must be refused by the gate: $(state_of r "$r")" ;; esac
  out=$(sweep); settle
  assert_contains "$out" "r not landed" "the red gate is reported"
  age_steer r "$r"; s0=$(steers r)
  hand_tip other other.txt x
  out=$(sweep); settle
  [ "$(attempts r "$r")" = 1 ] || fail "a red the lane caused is not run again when the tip moves: $(attempts r "$r") attempts"
  case $(state_of r "$r") in final*) ;; *) fail "the red stays final for its head: $(state_of r "$r")" ;; esac
  [ "$(steers r)" -gt "$s0" ] || fail "the worker is still steered: the verdict holds"
  pass 'a red gate the lane caused stays final for its head on a new tip, and its worker is still steered'
}

# A home on the old code stored the moved-trunk refusal as final for the head (byokit, 8 Nov). It holds only while the tip record it was
# judged on stands: once adopt-tip (or any hand repair) changes the record, the head is tried again and lands.
test_a_moved_trunk_verdict_holds_only_while_its_tip_record_stands() {
  local m
  home_world moved
  lane m one; m=$(git -C "$PROJ" rev-parse fm/m); mkdir -p "$HOME_D/data/jg-trunk-landing"
  printf 'final REFUSED: trunk is at 62f4a6457ec2 but the lander last left it at 78c3eba012a0; something else moved it, so nothing lands or releases until that is explained\n' \
    > "$HOME_D/data/jg-trunk-landing/m.$m.state"
  cat "$HOME_D/state/trunk-tip-proj" > "$HOME_D/data/jg-trunk-landing/m.$m.tip"
  sweep >/dev/null; settle; sweep >/dev/null; settle
  [ "$(attempts m "$m")" = 0 ] || fail "a moved-trunk verdict on an unchanged record must not be tried again: $(attempts m "$m") attempts"
  on_trunk work.txt one && fail "the lane must wait while the record stands"
  hand_tip adopted other.txt x
  sweep >/dev/null; settle
  on_trunk work.txt one || fail "the lane must land once the record changed: $(state_of m "$m")"
  pass 'a moved-trunk final holds while its tip record stands and the head is tried again, and lands, once the record changes'
}


test_a_stack_whose_decisions_read_fails_once_is_tried_again_and_lands
test_a_conflict_verdict_holds_only_while_its_tip_stands
test_a_conflict_whose_cause_left_the_trunk_lands_and_its_worker_is_not_steered
test_a_conflict_verdict_stored_with_no_tip_is_judged_again
test_a_red_gate_the_lane_caused_stays_final_for_its_head
test_a_moved_trunk_verdict_holds_only_while_its_tip_record_stands
printf 'jg-trunk-verdict: ok\n'

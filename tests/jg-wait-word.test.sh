#!/usr/bin/env bash
# Slice J9 through the real callers: the wait word replaces the three meanings of `paused`.
#   W1 The status append (bin/jg-lavish-guard.sh --append) refuses a paused line with no wait, a wait with no reason, a word outside
#      the closed lists, and the placeholder date 2026-12-31; each refusal writes nothing and names the new form. A whole line is written.
#   W2 The hold command (bin/jg-backlog.sh hold, on a real Beads store) writes the three wait keys in the same update as today's hold:
#      a parked hold waits on `lead` for `parked` and still has hold_kind `parked`; an owner question (kind captain) waits on `owner`
#      for a `decision`; a hold to a date waits on `outside` for the `date`; unhold writes the wait `none`. hold_kind and hold_reason
#      are what they were before.
#   W3 The quiet rule of jg-7v6uw slice 5 is keyed on reason `parked` (tests/jg-wait-quiet.test.sh and tests/jg-machine-wait.test.sh).
#   W4 The brief holds one rule for waiting, with the wait and reason words, and never the placeholder date.
# W2 needs JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT; without them it skips plainly.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T=$(jg_test_tmproot jg-wait-word)

test_the_status_append_refuses_a_wait_without_its_reason() {
  local state=$T/guard/state line status
  mkdir -p "$state"; status=$state/lane.status; : > "$status"
  append() { RC=0; printf '%s\n' "$1" | JG_HOME="$T/guard" "$ROOT/bin/jg-lavish-guard.sh" --append "$status" 2>"$T/err" || RC=$?; ERR=$(cat "$T/err"); }
  for line in 'paused [at=5]: waiting on the review' \
    'paused [at=5] [wait=lead]: waiting on the review' \
    'paused [at=5] [reason=parked]: set aside' \
    'paused [at=5] [wait=nobody] [reason=parked]: set aside' \
    'paused [at=5] [wait=lead] [reason=whim]: set aside' \
    'paused [at=5] [wait=none] [reason=parked]: set aside' \
    'paused [at=5] [wait=lead] [reason=parked]: parked until 2026-12-31T00:00Z'; do
    append "$line"
    [ "$RC" = 1 ] || fail "'$line' must be refused with exit 1, got $RC"
    assert_contains "$ERR" 'paused [at=<epoch>] [wait=<who>] [reason=<word>]' "the refusal of '$line' names the new form"
    [ ! -s "$status" ] || fail "a refused line must write nothing, found: $(cat "$status")"
  done
  append 'paused [at=5] [wait=lead]: waiting on the review'
  assert_contains "$ERR" 'a wait on lead needs a reason' "a wait with no reason says what is missing"
  append 'paused [at=6] [wait=lead] [reason=parked]: parked until 2026-12-31T00:00Z'
  assert_contains "$ERR" 'placeholder date 2026-12-31' "the placeholder date is named"
  for line in 'paused [at=7] [wait=lead] [reason=parked]: set aside' 'paused [at=8] wait=outside reason=ci: PR checks run' \
    'working [at=9]: not a wait' 'blocked [at=10] [key=k]: waits-for: jg-x1 the ticket'; do
    append "$line"
    [ "$RC" = 0 ] || fail "'$line' must be written, got $RC: $ERR"
  done
  [ "$(wc -l < "$status")" = 4 ] || fail "the four whole lines must be written, found: $(cat "$status")"
  pass 'a paused line with no wait, no reason, a wrong word or the placeholder date is refused and writes nothing; whole lines are written'
}

test_the_hold_command_writes_the_wait_keys_with_the_hold() {
  if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
    printf 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'; return 0
  fi
  local CLI=$ROOT/bin/jg-backlog.sh WRAPPER=$ROOT/bin/jg-beads.sh got
  unset BEADS_DB BEADS_DOLT_SHARED_SERVER BEADS_ACTOR JG_BACKLOG_LANE JG_BACKLOG_SPAWN_GEN JG_BACKLOG_AGENT JG_BACKLOG_LANE_HANDOVER
  mkdir -p "$T/store" "$T/home/config" "$T/home/data" "$T/home/state"
  export TZ=UTC TMPDIR=$T BEADS_DIR=$T/store/.beads JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT
  printf '%s\n' "$BEADS_DIR" > "$T/home/config/beads-dir"
  "$WRAPPER" init --prefix jg >"$T/init.log" 2>&1 || fail "init the store: $(cat "$T/init.log")"
  axi() { JG_HOME="$T/home" "$CLI" "$@"; }
  keys() { "$WRAPPER" show "$1" --json 2>/dev/null | jq -r 'if type == "array" then .[0] else . end | .metadata | [.hold_kind // "-", .wait // "-", .wait_reason // "-"] | join(" ")'; }
  local id
  for id in jw-parked jw-owner jw-date; do axi add "$id" "[feature] fixture $id" --priority 2 --body why >/dev/null || fail "file $id"; done

  axi hold jw-parked --reason 'set aside for later' --kind parked >/dev/null || fail 'parked hold'
  got=$(keys jw-parked); [ "$got" = 'parked lead parked' ] || fail "a parked hold must show hold_kind parked, wait lead, reason parked, got: $got"
  axi hold jw-owner --reason 'which design?' --kind captain >/dev/null || fail 'owner hold'
  got=$(keys jw-owner); [ "$got" = 'captain owner decision' ] || fail "an owner question must show wait owner, reason decision, got: $got"
  axi hold jw-date --reason 'wait for the date' --kind captain --until 2099-01-15 >/dev/null || fail 'dated hold'
  got=$(keys jw-date); [ "$got" = 'captain outside date' ] || fail "a hold to a date must show wait outside, reason date, got: $got"
  "$WRAPPER" show jw-parked --json | jq -e 'if type == "array" then .[0] else . end | .metadata.hold_reason == "set aside for later" and (.metadata.wait_at | test("^[0-9]{4}-"))' >/dev/null \
    || fail 'hold_reason is kept and the wait carries its time'
  axi hold jw-parked --reason 'set aside for later' --kind parked | grep -q 'already held' || fail 'the same hold again changes nothing'

  axi unhold jw-parked >/dev/null || fail 'unhold'
  got=$(keys jw-parked); [ "$got" = '- none ' ] || fail "unhold must clear the hold and end the wait, got: $got"
  pass 'a hold writes the wait keys in the same update and leaves hold_kind and hold_reason as they were; unhold ends the wait'
}

test_the_quiet_rule_is_keyed_on_reason_parked() {
  local table=$ROOT/core/machines/tables/wait.tsv
  grep -q 'reason=parked' "$table" || fail 'the wait table must read reason=parked'
  ! grep -q 'until 2026-12-31' "$table" || fail 'the wait table must not key on the placeholder date'
  grep -q 'reason=parked' "$ROOT/tests/jg-wait-quiet.test.sh" || fail 'the slice 5 journey must park its lane with reason=parked'
  pass 'the wait table and the slice 5 journey key on reason=parked'
}

test_the_brief_holds_one_rule_for_waiting() {
  local home=$T/brief-home brief n
  mkdir -p "$home/data"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" jw-brief some-proj --mode direct-PR >/dev/null 2>&1 || fail 'scaffold a ship brief'
  brief=$home/data/jw-brief/brief.md
  n=$(grep -c 'One rule for every wait' "$brief"); [ "$n" = 1 ] || fail "the brief must hold one wait rule, found $n"
  n=$(grep -c 'append `paused \[at=<epoch>\] \[wait=<who>\] \[reason=<word>\]' "$brief"); [ "$n" = 1 ] || fail "the brief must give the wait form once, found $n"
  assert_not_contains "$(cat "$brief")" '2026-12-31' 'the brief never offers the placeholder date'
  assert_contains "$(cat "$brief")" 'decision, blocker, dependency, quota, ci, approval, review, parked or date' 'the brief lists the reason words'
  pass 'the brief holds one rule for waiting, with the wait and reason words'
}

test_the_status_append_refuses_a_wait_without_its_reason
test_the_hold_command_writes_the_wait_keys_with_the_hold
test_the_quiet_rule_is_keyed_on_reason_parked
test_the_brief_holds_one_rule_for_waiting

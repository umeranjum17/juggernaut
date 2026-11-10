#!/usr/bin/env bash
# Integration test for the hold-record check of bin/jg-lavish-guard.sh --append: a lane's blocked: or needs-decision:
# line that names the captain or Main as its cause must carry the id of a hold that is on record.
# Built from the real line of Main's sign-off lane at 08:12:11Z on 10 Nov ("the open captain decision still bars push,
# landing"): no such hold existed, the guard accepted it, and the lane stopped for hours on a decision that did not exist.
#
# H1 That line, with no id, is refused with exit 1 and "no such hold is on record"; the status file is unchanged.
# H2 The same line naming an id with no hold on record is refused the same way.
# H3 The same line naming an id with a hold on record is written.
# H4 A blocked: line that names neither the captain nor Main, and a working: line that names the captain, go through.
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-hold-record)
W="$TMP_ROOT/w"; STATUS="$W/state/sign-off.status"
mkdir -p "$W/state"; cp -r "$ROOT/bin" "$W/bin"; ln -s "$ROOT/core" "$W/core"; ln -s "$ROOT/policy" "$W/policy"
# The hold reader: only the hold fixture-hold-1 is on record.
cat > "$W/bin/jg-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = open ] && [ "$2" = fixture-hold-1 ]
SH
chmod +x "$W/bin/jg-captain-hold.sh"
: > "$STATUS"

append() {  # <line>: sets RC and ERR
  RC=0
  printf '%s\n' "$1" | JG_HOME="$W" "$W/bin/jg-lavish-guard.sh" --append "$STATUS" 2>"$W/err" || RC=$?
  ERR=$(cat "$W/err")
}
LINE='blocked [at=1794298331]: the open captain decision still bars push, landing'

test_a_hold_with_no_id_is_refused_and_the_status_file_is_unchanged() {
  append "$LINE"
  [ "$RC" = 1 ] || fail "a captain hold with no id must exit 1, got $RC: $ERR"
  assert_contains "$ERR" "no such hold is on record" "the refusal says no hold is on record"
  [ ! -s "$STATUS" ] || fail "a refused line must leave the status file unchanged: $(cat "$STATUS")"
  pass 'a captain-named blocked line with no id is refused and writes nothing'
}

test_an_id_with_no_hold_is_refused() {
  append "needs-decision [at=1794298400]: waiting for Main on no-such-hold-9"
  [ "$RC" = 1 ] || fail "an id with no hold must exit 1, got $RC: $ERR"
  assert_contains "$ERR" "no such hold is on record" "the refusal says no hold is on record"
  pass 'an id with no hold on record is refused'
}

test_an_id_with_a_hold_is_accepted() {
  append "$LINE (fixture-hold-1)"
  [ "$RC" = 0 ] || fail "a line naming a real hold must exit 0, got $RC: $ERR"
  assert_contains "$(cat "$STATUS")" "fixture-hold-1" "the line is written"
  pass 'a line naming a hold on record is written'
}

test_lines_that_name_no_captain_cause_pass() {
  append 'blocked [at=1794298500]: the test runner cannot read its fixture'
  [ "$RC" = 0 ] || fail "a blocked line with no captain or Main cause must pass: $ERR"
  append 'working [at=1794298600]: the captain asked for this fix'
  [ "$RC" = 0 ] || fail "a working line must pass: $ERR"
  pass 'blocked lines without a captain or Main cause, and working lines, go through'
}

test_a_hold_with_no_id_is_refused_and_the_status_file_is_unchanged
test_an_id_with_no_hold_is_refused
test_an_id_with_a_hold_is_accepted
test_lines_that_name_no_captain_cause_pass
printf "jg-lavish-guard-hold-record: ok\n"

#!/usr/bin/env bash
# One quarantine list and one ticket filer (core/trunk-landing/quarantine.sh), through its real caller bin/jg-test-run.sh --gate.
# A lab script that fails every run sits in the lander's flaky ledger three times: the scan lists it with one fix ticket, the
# gate then runs it, records its red and passes; ten green runs in a row take it off the list and it blocks again; a listing
# older than seven days expires, blocks again and notes its ticket; the policy key off keeps today's behaviour; a second
# caller filing for the same script (T5, H41) gets the same ticket, never a second one.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-trunk-quarantine)
export JG_TEST_HOST_SLOTS="$TMP_ROOT/run-slots"

# A fixture repository holding the real runner and the real quarantine script, with a backlog stand-in that keeps tickets as files.
F=$TMP_ROOT/repo
HOME_D=$TMP_ROOT/home
LAB=tests/lab-flaky.test.sh
mkdir -p "$F/tests" "$F/core" "$HOME_D/data/trunk" "$HOME_D/config" "$TMP_ROOT/tickets"
cp -R "$ROOT/bin" "$F/bin"
cp -R "$ROOT/defaults" "$F/defaults"
cp -R "$ROOT/core/trunk-landing" "$F/core/trunk-landing"
cp "$ROOT/tests/git-config-helpers.sh" "$F/tests/"
cat >"$F/bin/jg-backlog.sh" <<'STUB'
#!/usr/bin/env bash
t=$QUARANTINE_TEST_TICKETS
case $1 in
  add) [ ! -e "$t/$2" ] || exit 1; printf '%s\n' "$3" >"$t/$2"; echo "add $2" >>"$t/calls" ;;
  show) [ -e "$t/$2" ] || exit 1; if [ -e "$t/$2.closed" ]; then echo '  closed: 2026-11-01'; else echo '  closed: "-"'; fi ;;
  update) printf '%s\n' "$*" >>"$t/$2.notes" ;;
esac
STUB
chmod +x "$F/bin/jg-backlog.sh"
export QUARANTINE_TEST_TICKETS="$TMP_ROOT/tickets"
export JG_HOME=$HOME_D JG_QUARANTINE_PROJECT=lab
jg_git_init_commit "$F"
git -C "$F" add -A
git -C "$F" -c user.name=t -c user.email=t@example.invalid commit -qm scaffold

Q="$F/core/trunk-landing/quarantine.sh"
LEDGER=$HOME_D/data/trunk/flaky-lab.tsv
LIST=$HOME_D/data/trunk/quarantine-lab.tsv
ID=flaky-lab-lab-flaky

set_lab() {  # <exit code the lab script ends with>
  printf '#!/usr/bin/env bash\necho "ok - lab"\nexit %s\n' "$1" >"$F/$LAB"
  chmod +x "$F/$LAB"
}
gate() { (cd "$F" && bash bin/jg-test-run.sh --gate "$LAB" 2>&1); }
flaky_rows() {  # <n> <age in seconds>
  local i now; now=$(date +%s)
  for ((i = 0; i < $1; i++)); do printf '%s\tabc\t%s\t-\n' "$((now - $2 + i))" "$LAB" >>"$LEDGER"; done
}

test_a_script_flaky_three_times_is_listed_with_one_ticket_and_does_not_block() {
  local out rc=0
  set_lab 1
  flaky_rows 2 3600
  out=$("$Q" scan) && [ -z "$out" ] || fail "two flaky rows listed a script: $out"
  flaky_rows 1 60
  out=$("$Q" scan) || fail "scan failed: $out"
  assert_contains "$out" "entered $LAB ticket=$ID" "the third row lists the script with its ticket"
  [ "$("$Q" scan)" = "" ] || fail "a listed script entered twice"
  [ "$(grep -c "^add $ID\$" "$TMP_ROOT/tickets/calls")" = 1 ] || fail "one ticket expected"
  # The policy key is off: the red still blocks, and the list only keeps the record.
  out=$(gate) || rc=$?
  [ "$rc" = 1 ] || fail "with the key off the red must block: rc=$rc $out"
  printf 'on\n' >"$HOME_D/config/quarantine"
  rc=0; out=$(gate) || rc=$?
  [ "$rc" = 0 ] || fail "a listed script's red blocked the gate: rc=$rc $out"
  assert_contains "$out" "JG_TEST_QUARANTINE_RED $LAB exit=1" "the red is named, not hidden"
  [ "$("$Q" state "$LAB")" = running ] || fail "a recorded red makes the entry running"
  [ "$(grep -c "$(printf '\tred\t')" "$LIST")" = 2 ] || fail "both reds must be recorded: $(cat "$LIST")"
  pass 'a script flaky three times is listed with one ticket; its red runs, is recorded and does not block'
}

test_a_second_filer_for_the_same_script_gets_the_same_ticket() {
  local a b
  a=$("$Q" ticket "$LAB" --why 'T5 found it'); b=$("$Q" ticket "$LAB" --why 'H41 found it')
  [ "$a" = "$ID" ] && [ "$b" = "$ID" ] || fail "tickets differ: $a $b"
  [ "$(grep -c '^add ' "$TMP_ROOT/tickets/calls")" = 1 ] || fail "a second ticket was filed: $(cat "$TMP_ROOT/tickets/calls")"
  pass 'two callers filing for one script make one ticket'
}

test_ten_greens_in_a_row_end_the_listing_and_the_script_blocks_again() {
  local out rc=0 i
  set_lab 0
  for ((i = 0; i < 9; i++)); do gate >/dev/null; done
  [ "$("$Q" state "$LAB")" = running ] || fail "nine greens must not end it: $("$Q" state "$LAB")"
  gate >/dev/null
  [ "$("$Q" state "$LAB")" = left ] || fail "ten greens must end it: $("$Q" state "$LAB")"
  set_lab 1
  out=$(gate) || rc=$?
  [ "$rc" = 1 ] || fail "a script that left the list must block again: rc=$rc $out"
  pass 'ten green runs in a row take the script off the list and it blocks again'
}

test_a_listing_older_than_seven_days_expires_and_notes_its_ticket() {
  local out rc=0
  : >"$LIST"; : >"$LEDGER"
  printf '%s\t%s\tentered\t%s\n' "$(( $(date +%s) - 8 * 86400 ))" "$LAB" "$ID" >"$LIST"
  out=$(gate) || rc=$?
  [ "$rc" = 1 ] || fail "an expired listing must block again: rc=$rc $out"
  [ "$("$Q" state "$LAB")" = expired ] || fail "state must be expired: $("$Q" state "$LAB")"
  assert_contains "$(cat "$TMP_ROOT/tickets/$ID.notes")" "blocks again" "the ticket is raised to its lead"
  pass 'a listing past seven days expires, blocks again and notes its ticket'
}

test_a_closed_ticket_lets_a_new_one_be_filed() {
  local a
  : >"$TMP_ROOT/tickets/$ID.closed"
  a=$("$Q" ticket "$LAB")
  [ "$a" != "$ID" ] && [ -e "$TMP_ROOT/tickets/$a" ] || fail "a flaky script with a closed ticket needs a new one: $a"
  pass 'a closed ticket does not stop a new one'
}

test_a_script_flaky_three_times_is_listed_with_one_ticket_and_does_not_block
test_a_second_filer_for_the_same_script_gets_the_same_ticket
test_ten_greens_in_a_row_end_the_listing_and_the_script_blocks_again
test_a_listing_older_than_seven_days_expires_and_notes_its_ticket
test_a_closed_ticket_lets_a_new_one_be_filed

printf 'all %s\n' 'jg-trunk-quarantine tests passed'

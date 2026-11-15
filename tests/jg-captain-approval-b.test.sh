#!/usr/bin/env bash
# The second half of the captain-approval suite (tests/jg-captain-approval.test.sh owns T1 to T7): the owner's own chat words start a build with no
# second approval (T8, T9), a plan slice starts on its report's recorded answer (T10), a Squad Lead home verifies the owner's signed approval
# through the main home (T11), and a dotted ticket is read by its ticket id (T12). Both parts share tests/jg-captain-approval-fixture.sh.
set -u
JG_CAPTAIN_APPROVAL_SUITE=jg-captain-approval-b
# shellcheck source=tests/jg-captain-approval-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-captain-approval-fixture.sh"

printf 'Build the retry policy as recommended.\n' > "$W/decision.txt"
S="$W/send"
mkdir -p "$S/state" "$S/config" "$S/data"
jg_test_beads_home "$S"
jg_write_meta "$S/state/t1.meta" "window=sess:jg-t1" "kind=ship" "harness=claude"
send() {  # <message>
  PATH="$FAKEBIN:$PATH" JG_ROOT_OVERRIDE="$S" JG_HOME="$S" JG_SEND_SETTLE=0 JG_SEND_LOG="$S/send.log" \
    "$ROOT/bin/jg-send.sh" t1 "$1" 2>&1
}
inbox() {
  PATH="$FAKEBIN:$PATH" JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$HOME_DIR/state" JG_DATA_OVERRIDE="$HOME_DIR/data" \
    JG_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/jg-inbox.sh" "$@" 2>&1
}
plain_out=$(inbox note "an idea that is not the captain's chat")
plain_id=$(printf '%s\n' "$plain_out" | grep -oE '[0-9]{6,}-[A-Za-z0-9]+' | head -1)
[ -n "$plain_id" ] || fail "T8 could not capture a plain note: $plain_out"

# T8: case 1 of D1, an order carrying the owner's words from his channel record.
order_out=$(inbox note $'[chat telegram 42:7]\nBuild the retry policy now, with no second approval.')
order_note=$(printf '%s\n' "$order_out" | grep -oE '[0-9]{6,}-[A-Za-z0-9]+' | head -1)
[ -n "$order_note" ] || fail "T8 could not capture the owner's chat note: $order_out"
order_ticket() {  # <quote> [note]; a [captain-ask] order ticket quoting the note; sets TID
  ticket "[captain-ask] retry policy order" "$(printf '[order] from the owner.\nowner-words: note:%s "%s"' "${2:-$order_note}" "$1")"
  scaffold "$TID" --mode direct-PR || fail "T8 could not scaffold $TID"
}
for bad in "Build the cache now" "uild the retry" "telegram 42" "no second approval.|$plain_id"; do
  order_ticket "${bad%%|*}" "$(case $bad in *'|'*) printf '%s' "${bad##*|}" ;; esac)"
  out=$(spawn "$TID" ship); rc=$?
  expect_code 1 "$rc" "T8 an order quoting '$bad' should be refused: $out"
  refused_clean "$TID"
done
order_ticket "Build the retry policy now"; order=$TID
out=$(spawn "$order" ship); rc=$?
expect_code 0 "$rc" "T8 an order with the owner's words should spawn: $out"
assert_contains "$out" "approval: $order starts on the owner's words in chat note $order_note" "T8 the start does not name the note"
assert_grep 'kind=ship' "$HOME_DIR/state/$order.meta" "T8 the order left no ship task record"
case "$(body_of "$order")" in *'approved-by-captain:'*) fail "T8 the order wrote a second approval record" ;; esac
pass "T8 an order with the owner's own chat words starts on that note alone; other words and notes are refused"

# T9: the same order relayed to a Squad Lead home, whose owner's chat notes live in its parent home.
jg_test_backlog "$S" add jg-sg2 "[captain-ask] relayed order" --priority 0 --kind ship --repo demo \
  --body "$(printf '[order] relayed from the owner.\nowner-words: note:%s "with no second approval"' "$order_note")" >/dev/null 2>&1 \
  || fail "T9 could not file the relayed order"
out=$(send "[order] ticket=jg-sg2 build the relayed order"); rc=$?
expect_code 1 "$rc" "T9 a lead home with no parent must not find the note: $out"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$HOME_DIR" > "$S/.jg-squad-lead-parent"
out=$(send "[order] ticket=jg-sg2 build the relayed order"); rc=$?
expect_code 0 "$rc" "T9 the relayed order should pass on the parent's chat note: $out"
assert_contains "$out" "approval: jg-sg2 starts on the owner's words in chat note $order_note" "T9 the steer does not name the note"
pass "T9 a Squad Lead home reads the owner's chat note in its parent home"

# T10: case 2 of D1, a slice of a report whose build answer is recorded.
ticket "[captain-ask] plan v2: build it?"; report=$TID
captain "$HOME_DIR" hold "$report" --reason "build the plan?" >/dev/null 2>&1 || fail "T10 hold failed"
captain "$HOME_DIR" answer "$report" --decision-file "$W/decision.txt" --release >/dev/null 2>&1 || fail "T10 answer failed"
ticket "[captain-ask] plan v3: build it?"; unanswered=$TID
ticket "[feature] slice of an unanswered report" "$(printf 'born-from: plan\nparent: %s' "$unanswered")"; orphan=$TID
scaffold "$orphan" --mode direct-PR || fail "T10 could not scaffold $orphan"
out=$(spawn "$orphan" ship); rc=$?
expect_code 1 "$rc" "T10 $orphan should be refused: $out"
refused_clean "$orphan"
ticket "[feature] slice S1 of the plan" "$(printf 'Slice S1 of the plan.\nborn-from: plan\nparent: %s' "$report")"; slice=$TID
scaffold "$slice" --mode direct-PR || fail "T10 could not scaffold the slice"
out=$(spawn "$slice" ship); rc=$?
expect_code 0 "$rc" "T10 a slice of an answered report should spawn: $out"
assert_contains "$out" "approval: $slice starts on the captain's recorded approval answer:" "T10 the start does not name the answer"
assert_contains "$out" "on its parent $report" "T10 the start does not name the report"
assert_grep 'kind=ship' "$HOME_DIR/state/$slice.meta" "T10 the slice left no ship task record"
pass "T10 a plan slice starts on its report's recorded answer; an unanswered report does not"

# T11: an approval signed in the main home verifies in a Squad Lead home through the main home.
ticket "[captain-ask] lead-home approval"; lead_t=$TID
captain "$HOME_DIR" hold "$lead_t" --reason "captain must decide" >/dev/null 2>&1 || fail "T11 hold failed"
captain "$HOME_DIR" answer "$lead_t" --decision-file "$W/decision.txt" --release >/dev/null 2>&1 || fail "T11 answer failed"
signed=$(body_of "$lead_t" | grep -o 'approved-by-captain: answer:[A-Za-z0-9._:-]* sig=[0-9a-f]*' | head -1)
[ -n "$signed" ] || fail "T11 the main home wrote no signed line"
# The main home's own verifier: a copy of the shipped lib, as every real home has.
mkdir -p "$HOME_DIR/bin"
cp "$ROOT"/bin/jg-captain-ask-lib.sh "$ROOT"/bin/jg-compat.sh "$ROOT"/bin/jg-squad-lead-parent-lib.sh "$HOME_DIR/bin/" 2>/dev/null
L="$W/lead"
mkdir -p "$L/state" "$L/config" "$L/data"
jg_test_beads_home "$L"
send_l() {
  PATH="$FAKEBIN:$PATH" JG_ROOT_OVERRIDE="$L" JG_HOME="$L" JG_SEND_SETTLE=0 JG_SEND_LOG="$L/send.log" \
    "$ROOT/bin/jg-send.sh" t1 "$1" 2>&1
}
jg_write_meta "$L/state/t1.meta" "window=sess:jg-t1" "kind=ship" "harness=claude"
jg_test_backlog "$L" add jg-ld1 "[captain-ask] signed in main" --priority 0 --kind ship --repo demo --body "$signed" >/dev/null 2>&1 || fail "T11 could not file the ticket"
jg_test_backlog "$L" add jg-ld2 "[captain-ask] written by hand" --priority 0 --kind ship --repo demo \
  --body "approved-by-captain: note:1234 sig=0000000000000000000000000000000000000000000000000000000000000000" >/dev/null 2>&1 || fail "T11 could not file the hand-written ticket"
# The line names $lead_t, so it verifies only for that ticket id; file it under that id in the lead home.
jg_test_backlog "$L" add "$lead_t" "[captain-ask] signed in main" --priority 0 --kind ship --repo demo --body "$signed" >/dev/null 2>&1 || fail "T11 could not file the signed ticket"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$HOME_DIR" > "$L/.jg-squad-lead-parent"
out=$(send_l "[order] ticket=$lead_t build it"); rc=$?
expect_code 0 "$rc" "T11 a line signed in the main home should verify in the lead home: $out"
assert_contains "$out" "starts on the captain's recorded approval" "T11 the start does not name the approval"
out=$(send_l "[order] ticket=jg-ld2 build it"); rc=$?
expect_code 1 "$rc" "T11 a hand-written line should be refused in the lead home: $out"
mv "$HOME_DIR/state/captain-approval.key" "$HOME_DIR/state/captain-approval.key.away"
out=$(send_l "[order] ticket=$lead_t build it"); rc=$?
expect_code 1 "$rc" "T11 with the main home unable to verify the order should wait: $out"
assert_contains "$out" "waits on Main" "T11 the refusal does not say the ticket waits on Main"
mv "$HOME_DIR/state/captain-approval.key.away" "$HOME_DIR/state/captain-approval.key"
pass "T11 a lead home verifies the owner's approval through the main home that signed it; a hand-written line is refused; an away main home is named"

# T12 a dotted [captain-ask] ticket (jg-ap.7 runs as task jg-ap-7) is read by its ticket id: refused without the
# captain's yes, and passing once his answer is recorded on the ticket.
dot=jg-apdot.7; dot_task=${dot//./-}
tasks add "$dot" "[captain-ask] dotted ticket" --priority 0 --kind ship --repo proj --body "Fixture dotted ticket" >"$W/add.out" 2>&1 \
  || fail "T12 could not add the dotted ticket: $(cat "$W/add.out")"
scaffold "$dot_task" --mode direct-PR || fail "T12 could not scaffold"
spawn_dot() {
  local wt="$W/wt-dot-$RANDOM"
  git -C "$PROJ" worktree add -q --detach "$wt" origin/main >/dev/null 2>&1 || fail "T12 could not prepare the isolated copy"
  jg_test_run_spawn "$HOME_DIR" "$wt" "$FAKEBIN" "$dot_task" "$PROJ" codex --mode direct-PR --yolo off --ticket "$dot"
}
out=$(spawn_dot); rc=$?
expect_code 1 "$rc" "T12 a dotted [captain-ask] ticket with no yes should be refused: $out"
assert_contains "$out" "approved-by-captain" "T12 the refusal does not name the missing line"
refused_clean "$dot_task"
printf 'Build the dotted ticket.\n' > "$W/decision-dot.txt"
captain "$HOME_DIR" hold "$dot" --reason "captain must decide" >/dev/null 2>&1 || fail "T12 hold failed"
captain "$HOME_DIR" answer "$dot" --decision-file "$W/decision-dot.txt" --release >/dev/null 2>&1 || fail "T12 answer failed"
out=$(spawn_dot); rc=$?
expect_code 0 "$rc" "T12 the dotted ticket with his recorded yes should spawn: $out"
assert_grep 'kind=ship' "$HOME_DIR/state/$dot_task.meta" "T12 the answered dotted ticket left no ship task record"
pass "T12 a dotted ticket's approval is read by its ticket id: refused unsigned, spawns once signed"

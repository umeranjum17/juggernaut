#!/usr/bin/env bash
# A build of a [captain-ask] ticket, or of one born from a Recon or plan, needs the captain's word on the board.
# Real bin/jg-spawn.sh, bin/jg-send.sh, bin/jg-captain-hold.sh and bin/jg-inbox.sh over a fixture home with a
# Beads backlog; only the terminal, the worktree tool and the model are stand-ins, so a spawn that passes
# the gate is the one that launches and writes its task record.
# The gate they share is bin/jg-captain-ask-lib.sh; this test is its proof.
#
# T1 a ship spawn for a [captain-ask] ticket, or one born from a Recon, is refused and leaves no task record.
# T2 a plain ticket spawns.
# T3 a hand-written approved-by-captain line does not open the gate.
# T4 after bin/jg-captain-hold.sh answer the same spawn passes, and a line copied to another ticket does not.
# T5 an [order] steer that names the ticket is refused the same way, a kind=recon steer is not, and the
#    steer passes after the answer.
# T6 bin/jg-inbox.sh approve writes the line from a captain chat note, and refuses any other note.
# T7 a Recon spawn for a gated ticket stays allowed.
# Decision D1: one record of the owner's yes starts the build, and the start names that record.
# T8 (tests/jg-captain-approval-b.test.sh) an order whose ticket carries the owner's words from his chat note spawns with no approval line;
#    words not in the note, a part of a word, the note's [chat] tag and a note that is not his chat refuse.
# T9 (b) an [order] steer in a Squad Lead home rests on the owner's chat note in its parent home, and only there.
# T10 (b) a plan-born slice of a report starts on the report's recorded answer; a slice of an unanswered report stays
#    refused. (A labelled ticket with a parent is below an ask, not the ask itself: the label goes down to every slice.)
# T11 and T12 (b) a lead home verifies the owner's signed approval through the main home; a dotted ticket is read by its ticket id.
# Each Beads write takes seconds, so the suite is split in two over tests/jg-captain-approval-fixture.sh.
set -u

# shellcheck source=tests/jg-captain-approval-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-captain-approval-fixture.sh"

# T1
ticket "[captain-ask] pick the retry policy"; cask=$TID
scaffold "$cask" --mode direct-PR || fail "T1 could not scaffold"
out=$(spawn "$cask" ship); rc=$?
expect_code 1 "$rc" "T1 a [captain-ask] ship should be refused: $out"
assert_contains "$out" "approved-by-captain" "T1 the refusal does not name the missing line"
refused_clean "$cask"
ticket "[feature] Wire the cache" $'Plan from the Recon.\nborn-from: recon'; recon=$TID
scaffold "$recon" --mode direct-PR || fail "T1 could not scaffold the recon-born ticket"
out=$(spawn "$recon" ship); rc=$?
expect_code 1 "$rc" "T1 a Recon-born ship should be refused: $out"
refused_clean "$recon"
pass "T1 a captain-ask ticket and a Recon-born ticket are refused without the line"

# T2
ticket "[feature] Plain fix"; plain=$TID
scaffold "$plain" --mode direct-PR || fail "T2 could not scaffold"
out=$(spawn "$plain" ship); rc=$?
expect_code 0 "$rc" "T2 a plain ticket should spawn: $out"
pass "T2 a plain ticket is unaffected"

# T3
ticket "[captain-ask] hand-written approval" 'approved-by-captain: note:1234 sig=0000000000000000000000000000000000000000000000000000000000000000'; fake=$TID
scaffold "$fake" --mode direct-PR || fail "T3 could not scaffold"
out=$(spawn "$fake" ship); rc=$?
expect_code 1 "$rc" "T3 a hand-written line should not open the gate: $out"
refused_clean "$fake"
pass "T3 a hand-written approval line is refused"

# T4
printf 'Build the retry policy as recommended.\n' > "$W/decision.txt"
captain "$HOME_DIR" hold "$cask" --reason "captain must decide" >/dev/null 2>&1 || fail "T4 hold failed"
captain "$HOME_DIR" answer "$cask" --decision-file "$W/decision.txt" --release >/dev/null 2>&1 || fail "T4 answer failed"
shown=$(body_of "$cask")
assert_contains "$shown" "approved-by-captain: answer:" "T4 the answer did not write the approval line"
line=$(printf '%s' "$shown" | grep -o 'approved-by-captain: answer:[A-Za-z0-9._:-]* sig=[0-9a-f]*' | head -1)
ticket "[captain-ask] copied approval" "$line"; other=$TID
scaffold "$other" --mode direct-PR || fail "T4 could not scaffold"
out=$(spawn "$other" ship); rc=$?
expect_code 1 "$rc" "T4 a line copied from another ticket should be refused: $out"
refused_clean "$other"
out=$(spawn "$cask" ship); rc=$?
expect_code 0 "$rc" "T4 the answered ticket should spawn: $out"
assert_grep 'kind=ship' "$HOME_DIR/state/$cask.meta" "T4 the answered ticket left no ship task record"
pass "T4 the same spawn passes after the captain's answer, and a copied line stays refused"

# T13: use the real spawn gate even if a brief was prepared before the rules were enabled.
tasks add jg-m7h "[captain-ask] Start repairs automatically" --priority 0 --kind ship --body "Standing repair order" >/dev/null \
  || fail "T13 could not file the standing order"
BEADS_ACTOR=alert:repair tasks add alert-repair-fixture "Repair a failing watcher check" --priority 1 --kind ship --repo proj --body "Alert-filed repair" >/dev/null \
  || fail "T13 could not file the repair"
ticket "Repair a failing watcher check"; lookalike=$TID
scaffold alert-repair-fixture --mode direct-PR || fail "T13 could not scaffold the repair"
scaffold "$lookalike" --mode direct-PR || fail "T13 could not scaffold the lookalike"
: > "$HOME_DIR/config/owner-rules"
out=$(spawn alert-repair-fixture ship); rc=$?
expect_code 1 "$rc" "T13 an unsigned standing order must refuse a repair: $out"
assert_contains "$out" "needs the recorded standing approval on jg-m7h" "T13 the refusal names the standing approval"
refused_clean alert-repair-fixture
captain "$HOME_DIR" hold jg-m7h --reason "approve automatic repair" >/dev/null 2>&1 || fail "T13 hold failed"
captain "$HOME_DIR" answer jg-m7h --decision-file "$W/decision.txt" --release >/dev/null 2>&1 || fail "T13 answer failed"
out=$(spawn "$lookalike" ship); rc=$?
expect_code 1 "$rc" "T13 the human-filed lookalike must be refused: $out"
assert_contains "$out" "owner-rules: no owner ask" "T13 a title does not confer the owner's approval"
refused_clean "$lookalike"
out=$(spawn alert-repair-fixture ship); rc=$?
expect_code 0 "$rc" "T13 the alert repair should start under the standing approval: $out"
assert_contains "$out" "starts on standing repair order jg-m7h" "T13 spawn recognizes the inherited approval"
pass "T13 spawn accepts an alert-filed repair on jg-m7h and refuses a human-filed lookalike"

rm -f -- "$HOME_DIR/config/owner-rules"

# T5
S="$W/send"
mkdir -p "$S/state" "$S/config" "$S/data"
jg_test_beads_home "$S"
jg_test_add "$S" jg-sg1 "[captain-ask] gated send"
jg_write_meta "$S/state/t1.meta" "window=sess:jg-t1" "kind=ship" "harness=claude"
send() {  # <message>
  PATH="$FAKEBIN:$PATH" JG_ROOT_OVERRIDE="$S" JG_HOME="$S" JG_SEND_SETTLE=0 JG_SEND_LOG="$S/send.log" \
    "$ROOT/bin/jg-send.sh" t1 "$1" 2>&1
}
out=$(send "[order] ticket=jg-sg1 build the gated change"); rc=$?
expect_code 1 "$rc" "T5 an order to build a captain-ask ticket should be refused: $out"
assert_contains "$out" "approved-by-captain" "T5 the steer refusal does not name the missing line"
[ ! -e "$S/state/t1.inbox/001.msg" ] || fail "T5 the refused steer was recorded"
out=$(send "[order] ticket=jg-sg1 kind=recon survey the options"); rc=$?
expect_code 0 "$rc" "T5 a Recon steer should pass: $out"
captain "$S" hold jg-sg1 --reason "captain must decide" >/dev/null 2>&1 || fail "T5 hold failed"
captain "$S" answer jg-sg1 --decision-file "$W/decision.txt" --release >/dev/null 2>&1 || fail "T5 answer failed"
out=$(send "[order] ticket=jg-sg1 build the gated change"); rc=$?
expect_code 0 "$rc" "T5 the order should pass after the captain's answer: $out"
pass "T5 a build order is refused until the captain's answer, and a Recon order is never refused"

# T6
inbox() {
  PATH="$FAKEBIN:$PATH" JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$HOME_DIR/state" JG_DATA_OVERRIDE="$HOME_DIR/data" \
    JG_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/jg-inbox.sh" "$@" 2>&1
}
chat_out=$(inbox note "[chat telegram 42] yes, build the cache wiring")
chat_id=$(printf '%s\n' "$chat_out" | grep -oE '[0-9]{6,}-[A-Za-z0-9]+' | head -1)
[ -n "$chat_id" ] || fail "T6 could not capture a chat note: $chat_out"
plain_out=$(inbox note "an idea that is not the captain's chat")
plain_id=$(printf '%s\n' "$plain_out" | grep -oE '[0-9]{6,}-[A-Za-z0-9]+' | head -1)
[ -n "$plain_id" ] || fail "T6 could not capture a plain note: $plain_out"
out=$(inbox approve "$plain_id" "$recon"); rc=$?
[ "$rc" -ne 0 ] || fail "T6 a plain note approved a build: $out"
out=$(spawn "$recon" ship); rc=$?
expect_code 1 "$rc" "T6 the refused approval should leave the Recon-born ticket gated: $out"
out=$(inbox approve "$chat_id" "$recon"); rc=$?
expect_code 0 "$rc" "T6 a chat note should approve: $out"
assert_contains "$(body_of "$recon")" "approved-by-captain: note:$chat_id" "T6 the approval line is missing"
out=$(spawn "$recon" ship); rc=$?
expect_code 0 "$rc" "T6 the approved Recon-born ticket should spawn: $out"
pass "T6 a captain chat note approves a build and any other note does not"

# T7
ticket "[captain-ask] survey first"; gated=$TID
JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$gated" proj --scout >/dev/null 2>&1 || fail "T7 could not scaffold the Recon brief"
sed -i 's/{TASK}/Survey the options./;s/{JUGGERNAUT_SPEC}/Survey the options and report./' "$HOME_DIR/data/$gated/brief.md"
out=$(spawn "$gated" scout); rc=$?
expect_code 0 "$rc" "T7 a Recon spawn must stay allowed: $out"
assert_grep 'kind=scout' "$HOME_DIR/state/$gated.meta" "T7 the Recon left no scout task record"
pass "T7 a Recon spawn for a gated ticket is allowed"

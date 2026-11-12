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
# T8 an order whose ticket carries the owner's words from his chat note spawns with no approval line;
#    words not in the note, a part of a word, the note's [chat] tag and a note that is not his chat refuse.
# T9 an [order] steer in a Squad Lead home rests on the owner's chat note in its parent home, and only there.
# T10 a plan-born slice of a report starts on the report's recorded answer; an unanswered report, or a
#    [captain-ask] ticket that only names an answered parent, stays refused.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v openssl >/dev/null 2>&1 || { echo "skip: openssl not found"; exit 0; }

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-captain-approval)

W="$TMP_ROOT/world"
HOME_DIR="$W/home"
PROJ="$W/proj"
mkdir -p "$W"
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$W/origin.git" "$PROJ" 2>/dev/null
printf 'v1\n' > "$PROJ/AGENTS.md"
git -C "$PROJ" add -A
git -C "$PROJ" commit -qm c1
git -C "$PROJ" push -q origin HEAD:refs/heads/main
git -C "$PROJ" fetch -q
git -C "$PROJ" remote set-head origin main >/dev/null 2>&1 || true

jg_test_spawn_home "$HOME_DIR"
FAKEBIN=$(make_spawn_fakebin "$W/fake")
jg_test_fake_sleep_noop "$FAKEBIN"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$HOME_DIR/config/host-memory"
jg_test_beads_home "$HOME_DIR"

tasks() { jg_test_backlog "$HOME_DIR" "$@"; }
captain() {  # <home> <args...>
  local h=$1
  shift
  PATH="$FAKEBIN:$PATH" JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" \
    JG_DATA_OVERRIDE="$h/data" JG_CONFIG_OVERRIDE="$h/config" "$ROOT/bin/jg-captain-hold.sh" "$@"
}
body_of() { tasks show "$1" --full 2>/dev/null; }

N=0
# ticket <title> [body]: a queued ticket; sets TID.
ticket() {
  N=$((N + 1))
  TID=jg-ap$N
  local prio=2; [[ "$1" == \[captain-ask\]* ]] && prio=0
  tasks add "$TID" "$1" --priority "$prio" --kind ship --repo proj --body "${2:-Fixture ticket $TID}" >"$W/add.out" 2>&1 \
    || fail "could not add the ticket $TID: $(cat "$W/add.out")"
}
scaffold() {  # <id> [brief-args...]
  local id=$1
  shift
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$id" proj --project "$PROJ" "$@" >"$W/scaffold.out" 2>&1 \
    || { cat "$W/scaffold.out" >&2; return 1; }
  sed -i 's/{TASK}/Exercise the approval gate./;s/{JUGGERNAUT_SPEC}/Exercise the approval gate end to end./' "$HOME_DIR/data/$id/brief.md"
}
spawn() {  # <id> <ship|scout>
  local id=$1 wt="$W/wt-$1-$RANDOM"
  git -C "$PROJ" worktree add -q --detach "$wt" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy"
  if [ "$2" = scout ]; then
    jg_test_run_spawn "$HOME_DIR" "$wt" "$FAKEBIN" "$id" "$PROJ" codex --scout
  else
    jg_test_run_spawn "$HOME_DIR" "$wt" "$FAKEBIN" "$id" "$PROJ" codex --mode direct-PR --yolo off
  fi
}
refused_clean() { [ ! -e "$HOME_DIR/state/$1.meta" ] || fail "the refused spawn $1 wrote a task record"; }

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
ticket "[captain-ask] an ask that names a parent" "$(printf 'parent: %s' "$report")"; ask=$TID
for t in "$orphan" "$ask"; do
  scaffold "$t" --mode direct-PR || fail "T10 could not scaffold $t"
  out=$(spawn "$t" ship); rc=$?
  expect_code 1 "$rc" "T10 $t should be refused: $out"
  refused_clean "$t"
done
ticket "[feature] slice S1 of the plan" "$(printf 'Slice S1 of the plan.\nborn-from: plan\nparent: %s' "$report")"; slice=$TID
scaffold "$slice" --mode direct-PR || fail "T10 could not scaffold the slice"
out=$(spawn "$slice" ship); rc=$?
expect_code 0 "$rc" "T10 a slice of an answered report should spawn: $out"
assert_contains "$out" "approval: $slice starts on the captain's recorded approval answer:" "T10 the start does not name the answer"
assert_contains "$out" "on its parent $report" "T10 the start does not name the report"
assert_grep 'kind=ship' "$HOME_DIR/state/$slice.meta" "T10 the slice left no ship task record"
pass "T10 a plan slice starts on its report's recorded answer; an unanswered report or a mere parent line does not"

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

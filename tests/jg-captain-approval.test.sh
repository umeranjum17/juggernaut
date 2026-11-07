#!/usr/bin/env bash
# A build of a [captain-ask] ticket, or of one born from a Recon or plan, needs the captain's word on the board.
# Real bin/jg-spawn.sh, bin/jg-send.sh, bin/jg-captain-hold.sh and bin/jg-inbox.sh over a fixture home with a
# Beads backlog; only the terminal, the worktree tool and the model are stand-ins, so a spawn that passes
# the gate is the one that launches and writes its task record.
#
# T1 a ship spawn for a [captain-ask] ticket, or one born from a Recon, is refused and leaves no task record.
# T2 a plain ticket spawns.
# T3 a hand-written approved-by-captain line does not open the gate.
# T4 after bin/jg-captain-hold.sh answer the same spawn passes, and a line copied to another ticket does not.
# T5 an [order] steer that names the ticket is refused the same way, a kind=recon steer is not, and the
#    steer passes after the answer.
# T6 bin/jg-inbox.sh approve writes the line from a captain chat note, and refuses any other note.
# T7 a Recon spawn for a gated ticket stays allowed.
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
  tasks add "$TID" "$1" --priority $([[ "$1" == \[captain-ask\]* ]] && echo 0 || echo 2) --kind ship --repo proj --body "${2:-Fixture ticket $TID}" >"$W/add.out" 2>&1 \
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

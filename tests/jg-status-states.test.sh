#!/usr/bin/env bash
# One rule per status state in every brief (ticket brief-one-rule-per-state). Real bin/jg-brief.sh, bin/jg-spawn.sh and
# bin/jg-status-states-lint.sh over throwaway homes; only the terminal, the worktree tool and the model are stand-ins.
#
# T1 every scaffold (ship, scout, charter) carries the core contract's States: line and passes the text lint.
# T2 jg-brief.sh refuses a home include that defines a state another way, naming the include's lines, and writes no brief.
# T3 jg-spawn.sh refuses a brief that defines a state another way, naming its lines, and writes no task record; the clean
#    brief spawns.
# T4 a charter written before a state changed is rendered again from the contract at launch (jg_states_render_file).
# T5 a commit that adds or renames a state word without changing the brief text fails; with the brief text, or with no
#    change to the table, it passes.
# T6 a renamed declared-wait verb (JG_CLASSIFY_PAUSED_VERB) is followed by the rendered line and the lint alike.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-status-states)
LINT="$ROOT/bin/jg-status-states-lint.sh"
# shellcheck source=bin/jg-status-states-lib.sh
. "$ROOT/bin/jg-status-states-lib.sh"
WANT=$(jg_states_line)
[ "$WANT" = "States: working, needs-decision, blocked, paused, done, failed." ] || fail "the contract line is '$WANT'"

W="$TMP_ROOT/world"; HOME_DIR="$W/home"; PROJ="$W/proj"
mkdir -p "$W"
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$W/origin.git" "$PROJ" 2>/dev/null
printf 'v1\n' > "$PROJ/AGENTS.md"
git -C "$PROJ" add -A; git -C "$PROJ" commit -qm c1
git -C "$PROJ" push -q origin HEAD:refs/heads/main; git -C "$PROJ" fetch -q
git -C "$PROJ" remote set-head origin main >/dev/null 2>&1 || true
FAKEBIN=$(make_spawn_fakebin "$W/fake")
jg_test_fake_sleep_noop "$FAKEBIN"
jg_test_spawn_home "$HOME_DIR"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$HOME_DIR/config/host-memory"

scaffold() {  # <id> [brief-args...]
  local id=$1; shift
  local pj=(--project "$PROJ"); case " $* " in *" --scout "*) pj=() ;; esac
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$id" proj ${pj[@]+"${pj[@]}"} "$@" >"$W/scaffold.out" 2>&1 || { cat "$W/scaffold.out" >&2; return 1; }
  sed -i 's/{TASK}/Exercise the states check./;s/{JUGGERNAUT_SPEC}/Exercise the states check end to end./' "$HOME_DIR/data/$id/brief.md"
}
spawn() {  # <id>
  local id=$1 wt="$W/wt-$1"
  jg_test_spawn_item "$HOME_DIR" "$id"
  git -C "$PROJ" worktree add -q --detach "$wt" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy"
  jg_test_run_spawn "$HOME_DIR" "$wt" "$FAKEBIN" "$id" "$PROJ" codex --mode direct-PR --yolo off
}

# T1
scaffold st-ship-t1 --mode direct-PR || fail "T1 could not scaffold a ship brief"
scaffold st-scout-t1 --scout || fail "T1 could not scaffold a scout brief"
JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" st-lead-t1 --squad-lead --no-projects >/dev/null 2>&1 || fail "T1 could not scaffold a charter"
for id in st-ship-t1 st-scout-t1 st-lead-t1; do
  f="$HOME_DIR/data/$id/brief.md"
  grep -qxF -- "$WANT" <(sed 's/^ *//' "$f") || fail "T1 $id has no States: line equal to the contract"
  "$LINT" text "$f" || fail "T1 the lint finds the scaffold of $id defining a state another way"
  for s in $(jg_states_words state); do
    grep -v '^ *States:' "$f" | grep -qF -- "$s" || fail "T1 $id never tells its reader how the state $s is written"
  done
done
pass "T1 every scaffold carries the contract's States: line, passes the lint, and names every state"

# T2
mkdir -p "$HOME_DIR/config"
# shellcheck disable=SC2016 # backticks are literal brief text
printf 'Keep it short.\nStates: working, blocked, done.\nWrite `parked [at=<epoch>]: waiting` for a wait.\nUse `paused [at=<epoch>]: waiting` too.\nA wait is `wait is one of worker, outside`.\n' > "$HOME_DIR/config/brief-include.md"
out=$(JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" st-ship-t2 proj --project "$PROJ" --mode direct-PR 2>&1); rc=$?
expect_code 1 "$rc" "T2 a conflicting include must be refused: $out"
for l in 2 3 4 5; do assert_contains "$out" "line $l:" "T2 the refusal does not name include line $l: $out"; done
assert_not_contains "$out" "line 1:" "T2 the refusal names a clean line"
[ ! -e "$HOME_DIR/data/st-ship-t2/brief.md" ] || fail "T2 the refused scaffold left a brief"
printf 'Keep it short.\n' > "$HOME_DIR/config/brief-include.md"
JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" st-ship-t2b proj --project "$PROJ" --mode direct-PR >/dev/null 2>&1 || fail "T2 a clean include was refused"
rm -f "$HOME_DIR/config/brief-include.md"
pass "T2 jg-brief.sh refuses an include that defines a state another way and names its lines"

# T3
scaffold st-spawn-bad --mode direct-PR || fail "T3 could not scaffold"
sed -i 's/^   States: .*/   States: working, done./' "$HOME_DIR/data/st-spawn-bad/brief.md"
out=$(spawn st-spawn-bad); rc=$?
expect_code 1 "$rc" "T3 a brief with another States: list must be refused: $out"
assert_contains "$out" "core contract" "T3 the refusal does not name the contract: $out"
assert_contains "$out" "brief.md:" "T3 the refusal does not name the brief lines: $out"
[ ! -e "$HOME_DIR/state/st-spawn-bad.meta" ] || fail "T3 the refused spawn wrote a task record"
scaffold st-spawn-ok --mode direct-PR || fail "T3 could not scaffold the clean brief"
out=$(spawn st-spawn-ok); rc=$?
expect_code 0 "$rc" "T3 the clean brief should spawn: $out"
pass "T3 jg-spawn.sh refuses a brief that defines a state another way, naming the lines; the clean brief spawns"

# T4
c="$W/charter.md"
printf '# Charter\nStates: working, done.\nkeep this line\n' > "$c"
chg=$(jg_states_render_file "$c") || fail "T4 render failed"
[ "$chg" = 2 ] || fail "T4 the render reports line '$chg', not 2"
[ "$(sed -n 2p "$c")" = "$WANT" ] && [ "$(sed -n 3p "$c")" = "keep this line" ] || fail "T4 the charter was not rendered from the contract"
[ -z "$(jg_states_render_file "$c")" ] || fail "T4 a charter that already matches was rewritten"
pass "T4 a charter's States: line is rendered again from the contract and nothing else changes"

# T4b the real launch: a Squad Lead spawn renders its seeded charter again from the contract. The harness is named, because
# a spawn with none reads the host (config, then detection), and a host with no worker runtime found has none to launch.
sm="$W/lead-home"; mkdir -p "$sm/data" "$sm/bin"
printf '# Juggernaut\n' > "$sm/AGENTS.md"; printf 'st-lead-t4\n' > "$sm/.jg-squad-lead-home"
printf '%s\n' 'projects/' 'state/' 'data/' 'config/' > "$sm/.gitignore"
git -C "$sm" init -q -b main
printf '# Charter\nStates: working, done.\nkeep this line\n' > "$sm/data/charter.md"
jg_test_spawn_brief "$HOME_DIR" st-lead-t4
out=$(jg_test_run_spawn "$HOME_DIR" "$W/lead-pane" "$FAKEBIN" st-lead-t4 "$sm" codex --squad-lead); rc=$?
expect_code 0 "$rc" "T4b the Squad Lead spawn should succeed: $out"
[ "$(sed -n 2p "$sm/data/charter.md")" = "$WANT" ] || fail "T4b the launch left a stale States: line in the charter"
[ "$(sed -n 3p "$sm/data/charter.md")" = "keep this line" ] || fail "T4b the launch changed another charter line"
assert_contains "$out" "rendered again from the core contract" "T4b the launch did not say it re-rendered: $out"
pass "T4b a Squad Lead launch renders its charter's States: line from the contract"

# T5
R="$W/repo"; mkdir -p "$R/bin" "$R/defaults"
cp "$ROOT/bin/jg-status-states-lint.sh" "$ROOT/bin/jg-status-states-lib.sh" "$R/bin/"
cp "$ROOT/defaults/status-states.tsv" "$R/defaults/"
printf '# brief\n' > "$R/bin/jg-brief.sh"
git -C "$R" init -q; git -C "$R" add -A; git -C "$R" commit -qm base
sed -i 's/^state\tfailed\t/state\tabandoned\t/' "$R/defaults/status-states.tsv"
git -C "$R" commit -qam "rename a state only"
out=$("$R/bin/jg-status-states-lint.sh" commit HEAD 2>&1); rc=$?
expect_code 1 "$rc" "T5 a state rename with no brief text change must fail: $out"
assert_contains "$out" "state:abandoned" "T5 the refusal does not name the new word: $out"
assert_contains "$out" "state:failed" "T5 the refusal does not name the old word: $out"
printf '# brief, now teaching abandoned\n' > "$R/bin/jg-brief.sh"
sed -i 's/^state\tabandoned\t/state\tgave-up\t/' "$R/defaults/status-states.tsv"
git -C "$R" commit -qam "rename again, with the brief text"
"$R/bin/jg-status-states-lint.sh" commit HEAD >/dev/null 2>&1 || fail "T5 a rename that updates the brief text was refused"
printf 'x\n' > "$R/other.txt"; git -C "$R" add -A; git -C "$R" commit -qm "unrelated"
"$R/bin/jg-status-states-lint.sh" commit HEAD >/dev/null 2>&1 || fail "T5 a commit that leaves the table alone was refused"
"$R/bin/jg-status-states-lint.sh" commit HEAD~2 >/dev/null 2>&1 && fail "T5 the first bad commit passed when named by revision"
sed -i 's/^wait\t.*/wait\tworker tick lead main owner outside vendor/' "$R/defaults/status-states.tsv"
git -C "$R" commit -qam "add a wait word only"
"$R/bin/jg-status-states-lint.sh" commit HEAD >/dev/null 2>&1 && fail "T5 a new wait word with no brief text change passed"
pass "T5 a commit that adds or renames a status word without the brief text fails; with it, or with the table alone untouched, it passes"

# T6
out=$(JG_CLASSIFY_PAUSED_VERB=holding bash -c '. "$1"; jg_states_line' _ "$ROOT/bin/jg-status-states-lib.sh")
[ "$out" = "States: working, needs-decision, blocked, holding, done, failed." ] || fail "T6 the renamed verb is not rendered: $out"
# shellcheck disable=SC2016 # backticks are literal brief text
printf '   `holding [at=<epoch>] [wait=<who>] [reason=<word>]: x`\n   %s\n' "$out" > "$W/renamed.md"
JG_CLASSIFY_PAUSED_VERB=holding "$LINT" text "$W/renamed.md" || fail "T6 the lint refused the renamed verb's own text"
pass "T6 a renamed declared-wait verb is followed by the rendered line and the lint"

echo "ok: jg-status-states"

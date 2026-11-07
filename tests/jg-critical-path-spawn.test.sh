#!/usr/bin/env bash
# The migration's critical path at spawn: while a part of config/migration-card's critical= list is not
# live, a ship that is off that path is refused before any worktree or task record exists.
# Real bin/jg-brief.sh, bin/jg-spawn.sh and bin/jg-critical-path.sh over a fixture project; only the
# probe (JG_MIGRATION_LIVE_BIN), the terminal and the worktree tool are stand-ins, so a spawn that
# passes the gate is the one that launches and writes its task record.
# tests/jg-critical-path.test.sh owns the gate itself; journeys/critical-path.sh runs both files.
#
# T1 a ship for a row past the first pending part is refused, with the measurement, and leaves no record.
# T2 Migration row accounts, the first part not live, spawns.   T3 Migration row none spawns and is recorded.
# T4 a brief with no Migration row line is refused.
# T5 an override spawns only when the brief quotes the same words, and the task record keeps it.
# T7 a scout spawn refuses --off-critical-path.   T8 a relaunch is not gated again and keeps its decision.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-critical-path-tests)

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

# The probe stand-in: prints the row bin/jg-migration-live.sh prints for one part, with the state
# read from $JG_TEST_PROBE_STATE (one "slug state" per line; a slug not listed is absent).
cat > "$W/probe" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --link ] || { echo "https://board.example/reports/card-live"; exit 0; }
[ -r "${JG_TEST_PROBE_STATE:-}" ] || exit 3
st=$(awk -v s="$1" '$1 == s { print $2 }' "$JG_TEST_PROBE_STATE")
printf 'part %s\t%s\tmeasured %s is %s\thttps://github.com/example/repo/pull/90\n' "$1" "${st:-absent}" "$1" "${st:-absent}"
SH
chmod +x "$W/probe"
export JG_MIGRATION_LIVE_BIN="$W/probe"
export JG_TEST_PROBE_STATE="$W/probe.state"
probe_state() { printf '%s\n' "$@" > "$JG_TEST_PROBE_STATE"; }
probe_state 'nats live' 'accounts pending'
printf 'critical=nats,accounts,wake,inbox\nproject=proj\n' > "$HOME_DIR/config/migration-card"

N=0
fresh() { N=$((N + 1)); id=jg-cp$N; }

# scaffold <id> <brief-args...>: a real brief, filled in.
scaffold() {
  local id=$1
  shift
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$id" proj --mode direct-PR --project "$PROJ" "$@" 2>&1 || return 1
  sed -i 's/{TASK}/Exercise the critical path./;s/{JUGGERNAUT_SPEC}/Exercise the critical path end to end./' "$HOME_DIR/data/$id/brief.md"
}
# spawn <id> <spawn-args...>: a real ship spawn onto its own isolated copy.
spawn() {
  local id=$1 wt="$W/wt-$1"
  shift
  git -C "$PROJ" worktree add -q --detach "$wt" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy"
  jg_test_run_spawn "$HOME_DIR" "$wt" "$FAKEBIN" "$id" "$PROJ" codex --mode direct-PR --yolo off "$@"
}
meta() { cat "$HOME_DIR/state/$1.meta" 2>/dev/null; }
refused_clean() {  # <id>: a refusal leaves no task record
  [ ! -e "$HOME_DIR/state/$1.meta" ] || fail "the refused spawn $1 wrote a task record"
}

# T1
fresh
scaffold "$id" --migration-row deletions >/dev/null || fail "T1 could not scaffold the deletions brief"
grep -qx 'Migration row: deletions' "$HOME_DIR/data/$id/brief.md" || fail "T1 the brief did not record Migration row: deletions"
out=$(spawn "$id"); rc=$?
expect_code 1 "$rc" "T1 a ship for a row past the first pending part should be refused: $out"
assert_contains "$out" "accounts" "T1 the refusal does not name the first part not live"
assert_contains "$out" "measured accounts is pending" "T1 the refusal does not carry what the probe measured"
assert_contains "$out" "https://github.com/example/repo/pull/90" "T1 the refusal does not name the pull request that finishes it"
assert_contains "$out" "https://board.example/reports/card-live" "T1 the refusal does not carry the migration card link"
refused_clean "$id"
pass "T1 a ship for deletions is refused while accounts is not live, with the measurement and the pull request"

# T2
fresh
scaffold "$id" --migration-row accounts >/dev/null || fail "T2 could not scaffold"
out=$(spawn "$id"); rc=$?
expect_code 0 "$rc" "T2 work on the first part not live should spawn: $out"
assert_grep 'migration_row=accounts' "$HOME_DIR/state/$id.meta" "T2 the task record lacks migration_row=accounts"
pass "T2 a ship for the first part not live spawns"

# T3
fresh
scaffold "$id" --migration-row none >/dev/null || fail "T3 could not scaffold"
out=$(spawn "$id"); rc=$?
expect_code 0 "$rc" "T3 declared non-migration work should spawn: $out"
assert_grep 'migration_row=none' "$HOME_DIR/state/$id.meta" "T3 the task record lacks migration_row=none"
pass "T3 Migration row: none spawns and is recorded"

# T4
fresh
scaffold "$id" >/dev/null || fail "T4 could not scaffold"
! grep -q '^Migration row:' "$HOME_DIR/data/$id/brief.md" || fail "T4 the plain brief carries a Migration row line"
out=$(spawn "$id"); rc=$?
expect_code 1 "$rc" "T4 a brief with no Migration row should be refused: $out"
assert_contains "$out" "no Migration row" "T4 the refusal does not say the line is missing"
assert_contains "$out" "accounts" "T4 the refusal does not name the first part not live"
assert_contains "$out" "--migration-row" "T4 the refusal does not say how to add the line"
refused_clean "$id"
pass "T4 a brief with no Migration row is refused"

# T5
fresh
WORDS="captain: run deletions now"
scaffold "$id" --migration-row deletions --off-critical-path "$WORDS" >/dev/null || fail "T5 could not scaffold"
grep -qxF "Critical-path override: $WORDS" "$HOME_DIR/data/$id/brief.md" || fail "T5 the brief did not quote the override"
out=$(spawn "$id" --off-critical-path "$WORDS"); rc=$?
expect_code 0 "$rc" "T5 an overridden ship should spawn: $out"
assert_grep "critical_override=$WORDS" "$HOME_DIR/state/$id.meta" "T5 the task record lacks critical_override="
assert_grep 'migration_row=deletions' "$HOME_DIR/state/$id.meta" "T5 the task record lacks migration_row=deletions"
OVERRIDE_ID=$id
fresh
scaffold "$id" --migration-row deletions >/dev/null || fail "T5 could not scaffold the unquoted brief"
out=$(spawn "$id" --off-critical-path "$WORDS"); rc=$?
expect_code 1 "$rc" "T5 an override the brief does not quote should be refused: $out"
assert_contains "$out" "Critical-path override" "T5 the refusal does not name the missing brief line"
refused_clean "$id"
fresh
scaffold "$id" --migration-row deletions --off-critical-path "$WORDS" >/dev/null || fail "T5 could not scaffold"
out=$(spawn "$id"); rc=$?
expect_code 1 "$rc" "T5 a brief override with no spawn flag should be refused: $out"
refused_clean "$id"
out=$(JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" cp-bad proj --mode direct-PR --project "$PROJ" --off-critical-path '' 2>&1); rc=$?
expect_code 1 "$rc" "T5 an empty override should be refused by the brief: $out"
pass "T5 --off-critical-path admits a ship only with the brief quoting the same words, and records it"

# T8
cp -f "$HOME_DIR/state/$OVERRIDE_ID.meta" "$W/override.meta.before"
out=$(jg_test_run_spawn "$HOME_DIR" "$W/wt-$OVERRIDE_ID" "$FAKEBIN" "$OVERRIDE_ID" "$PROJ" codex --relaunch 2>&1); rc=$?
case "$out" in *"off the critical path"*) fail "T8 a relaunch was gated again: $out" ;; esac
assert_grep "critical_override=$WORDS" "$HOME_DIR/state/$OVERRIDE_ID.meta" "T8 the relaunch lost the recorded override"
assert_grep 'migration_row=deletions' "$HOME_DIR/state/$OVERRIDE_ID.meta" "T8 the relaunch lost the recorded row"
[ "$(grep -c '^critical_override=' "$HOME_DIR/state/$OVERRIDE_ID.meta")" -eq 1 ] || fail "T8 the relaunch duplicated the override line"
out=$(jg_test_run_spawn "$HOME_DIR" "$W/wt-$OVERRIDE_ID" "$FAKEBIN" "$OVERRIDE_ID" "$PROJ" codex --relaunch --off-critical-path words 2>&1); rc=$?
expect_code 1 "$rc" "T8 a relaunch should refuse a new override: $out"
pass "T8 a relaunch is not gated again and keeps the recorded decision"

echo "all jg-critical-path tests passed"
# T7
out=$(jg_test_run_spawn "$HOME_DIR" "$W/wt-$OVERRIDE_ID" "$FAKEBIN" scoutcp "$PROJ" codex --scout --off-critical-path words 2>&1); rc=$?
expect_code 1 "$rc" "T7 a scout spawn should refuse --off-critical-path: $out"
pass "T7 a scout spawn refuses --off-critical-path"

echo "all jg-critical-path spawn tests passed"

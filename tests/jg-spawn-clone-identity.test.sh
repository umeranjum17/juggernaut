#!/usr/bin/env bash
# Real spawn through fixture pools, with a retained dirty foreign copy.
# This test owns journeys/spawn-clone-identity.sh.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(jg_test_tmproot jg-spawn-clone-identity)
make_spawn_case() {
  local name=$1 harness=$2 id=$3 dir home proj wt fake
  dir="$TMP_ROOT/$name"; home="$dir/home"; proj="$dir/project"; wt="$dir/wt"
  fake=$(jg_test_make_spawn_fakebin "$dir/fake")
  jg_test_spawn_home "$home" "$harness"
  jg_git_worktree "$proj" "$wt" "wt-$name"
  jg_test_spawn_brief "$home" "$id"
  printf '%s\n' "$dir|$home|$proj|$wt|$fake|$dir/launch.log"
}
read_case_record() {
  local unused_wt
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR unused_wt FAKEBIN_DIR LAUNCH_LOG <<< "$1"
  : "$unused_wt"
}
run_ship_spawn() {
  local home=$1 wt=$2 fake=$3 log=$4
  shift 4
  : > "$log"
  JG_FAKE_LAUNCH_LOG="$log" jg_test_run_spawn "$home" "$wt" "$fake" "$@" --mode no-mistakes --yolo off
}
test_leased_copy_matches_registered_clone() {
  local rec id out status other pool copy project_common copy_common
  id=clone-mismatch
  rec=$(make_spawn_case clone-mismatch codex "$id")
  read_case_record "$rec"
  other="$CASE_DIR/other"
  git clone -q "$PROJ_DIR" "$other" || fail "clone fixture"
  pool="$CASE_DIR/pool"
  mkdir -p "$pool/1"
  printf '{}\n' > "$pool/treehouse-state.json"
  copy="$pool/1/project"
  git -C "$other" worktree add -q --detach "$copy" || fail "foreign copy fixture"
  printf 'uncommitted evidence\n' > "$copy/dirty.txt"
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
case "$1" in
  get) printf '%s\n' "$JG_FAKE_PANE_PATH" > "$JG_TEST_LEASE"; printf '%s\n' "$JG_FAKE_PANE_PATH" ;;
  return) printf 'returned\n' > "$JG_TEST_LEASE" ;;
esac
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
  export JG_TEST_LEASE="$CASE_DIR/lease"
  project_common=$(git -C "$PROJ_DIR" rev-parse --path-format=absolute --git-common-dir)
  copy_common=$(git -C "$copy" rev-parse --path-format=absolute --git-common-dir)
  out=$(run_ship_spawn "$HOME_DIR" "$copy" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR"); status=$?
  expect_code 1 "$status" "foreign clone must be refused: $out"
  assert_contains "$out" "$project_common" "refusal must name project common directory"
  assert_contains "$out" "$copy_common" "refusal must name leased common directory"
  [ -f "$copy/dirty.txt" ] || fail "refusal changed the leased copy"
  [ "$(cat "$JG_TEST_LEASE")" = "$copy" ] || fail "refusal returned the lease"
  assert_grep "worktree=$copy" "$HOME_DIR/state/$id.meta" "refusal must retain recovery record"
  assert_grep 'cleanup_recovery=treehouse' "$HOME_DIR/state/$id.meta" "refusal must retain lease for recovery"
  [ ! -s "$LAUNCH_LOG" ] || fail "foreign copy launched a worker"
  printf 'foreign copy refused: %s\n' "$out"
  printf 'lease retained: %s; dirty file retained; no worker launch\n' "$(cat "$JG_TEST_LEASE")"
  id=clone-match
  rec=$(make_spawn_case clone-match codex "$id")
  read_case_record "$rec"
  pool="$CASE_DIR/pool"
  mkdir -p "$pool/1"
  printf '{}\n' > "$pool/treehouse-state.json"
  copy="$pool/1/project"
  git -C "$PROJ_DIR" worktree add -q --detach "$copy" || fail "matching copy fixture"
  out=$(run_ship_spawn "$HOME_DIR" "$copy" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR"); status=$?
  expect_code 0 "$status" "matching clone must spawn: $out"
  printf 'matching copy spawned: %s\n' "$out"
  pass "leased copy must belong to the registered clone"
}

test_leased_copy_matches_registered_clone

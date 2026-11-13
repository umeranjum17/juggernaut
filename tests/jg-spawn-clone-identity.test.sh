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

# Two homes, two clones of one origin with the same directory name: the real
# Treehouse must lease each clone a copy of its own clone, from its own pool.
test_each_clone_gets_its_own_pool() {
  command -v treehouse >/dev/null 2>&1 || { printf 'skip: treehouse not installed\n'; return 0; }
  local dir main lead origin mclone lclone mcopy lcopy real_home
  dir="$TMP_ROOT/per-clone-pool"; main="$dir/main"; lead="$dir/lead"; origin="$dir/origin.git"
  mkdir -p "$main/state" "$lead/state" "$main/projects" "$lead/projects" "$dir/home"
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$main" > "$lead/.jg-squad-lead-parent"
  git init -q --bare "$origin" || fail "origin fixture"
  git clone -q "$origin" "$dir/seed" 2>/dev/null || fail "seed clone"
  git -C "$dir/seed" -c user.name=t -c user.email=t@t commit -q --allow-empty -m seed || fail "seed commit"
  git -C "$dir/seed" push -q origin HEAD 2>/dev/null || fail "seed push"
  mclone="$main/projects/pockit"; lclone="$lead/projects/pockit"
  git clone -q "$origin" "$mclone" 2>/dev/null || fail "main clone"
  git clone -q "$origin" "$lclone" 2>/dev/null || fail "lead clone"
  real_home=$HOME
  export HOME="$dir/home" TREEHOUSE_NO_UPDATE_CHECK=1
  # shellcheck source=bin/jg-wake-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/../bin/jg-wake-lib.sh"
  JG_HOME=$main jg_treehouse_clone_pool_prepare "$mclone" || fail "root home prepare"
  JG_HOME=$lead jg_treehouse_clone_pool_prepare "$lclone" || fail "lead home prepare"
  mcopy=$(cd "$mclone" && treehouse get --lease 2>/dev/null) || fail "main lease"
  lcopy=$(cd "$lclone" && treehouse get --lease 2>/dev/null) || fail "lead lease"
  HOME=$real_home
  [ -z "$(git -C "$lclone" status --short)" ] || fail "pool config dirtied the lead clone"
  [ "$(cd "$(git -C "$mcopy" rev-parse --git-common-dir)" && pwd -P)" = "$(cd "$mclone/.git" && pwd -P)" ] \
    || fail "main copy $mcopy is not a copy of the main clone"
  [ "$(cd "$(git -C "$lcopy" rev-parse --git-common-dir)" && pwd -P)" = "$(cd "$lclone/.git" && pwd -P)" ] \
    || fail "lead copy $lcopy is not a copy of the lead clone"
  case "$lcopy" in "$lead"/.treehouse-pool/*) ;; *) fail "lead copy $lcopy is outside the lead pool";; esac
  printf 'main copy %s; lead copy %s\n' "$mcopy" "$lcopy"
  pass "each clone leases from its own pool"
}

test_each_clone_gets_its_own_pool

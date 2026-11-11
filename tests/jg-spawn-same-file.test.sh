#!/usr/bin/env bash
# Two ships naming one file can start together, subject to project capacity.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-spawn-same-file)
W="$TMP_ROOT/world"; HOME_DIR="$W/home"; PROJ="$W/proj"
mkdir -p "$W"
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$W/origin.git" "$PROJ" 2>/dev/null
mkdir -p "$PROJ/bin" "$PROJ/docs"
printf 'v1\n' > "$PROJ/AGENTS.md"; printf 'a\n' > "$PROJ/bin/jg-trunk.sh"; printf 'b\n' > "$PROJ/bin/jg-other.sh"
git -C "$PROJ" add -A; git -C "$PROJ" commit -qm c1
git -C "$PROJ" push -q origin HEAD:refs/heads/main; git -C "$PROJ" fetch -q
git -C "$PROJ" remote set-head origin main >/dev/null 2>&1 || true
FAKEBIN=$(make_spawn_fakebin "$W/fake")
jg_test_fake_sleep_noop "$FAKEBIN"
jg_test_spawn_home "$HOME_DIR"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$HOME_DIR/config/host-memory"

N=0
# lane <task text> [scout]: scaffold a real brief whose task names the text, then spawn it; sets id, out, rc.
lane() {
  local text=$1 kind=${2:-ship} wt
  N=$((N + 1)); id=jg-sf$N; wt="$W/wt-$id"
  jg_test_add "$HOME_DIR" "$id" "[feature] same file $N"
  if [ "$kind" = scout ]; then
    JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$id" proj --scout >/dev/null 2>&1 || fail "could not scaffold the brief for $id"
  else
    JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$id" proj --mode direct-PR --project "$PROJ" --migration-row none >/dev/null 2>&1 \
      || fail "could not scaffold the brief for $id"
  fi
  sed -i "s|{TASK}|$text|;s|{JUGGERNAUT_SPEC}|Exercise concurrent admission.|" "$HOME_DIR/data/$id/brief.md"
  git -C "$PROJ" worktree add -q --detach "$wt" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy"
  if [ "$kind" = scout ]; then
    out=$(jg_test_run_spawn "$HOME_DIR" "$wt" "$FAKEBIN" "$id" "$PROJ" codex --scout); rc=$?
  else
    out=$(jg_test_run_spawn "$HOME_DIR" "$wt" "$FAKEBIN" "$id" "$PROJ" codex --mode direct-PR --yolo off); rc=$?
  fi
}

lane 'Change bin/jg-trunk.sh so the verb works.'
expect_code 0 "$rc" "setup: the first lane should launch: $out"

# A second ship naming the same file must start.
lane 'Also fix bin/jg-trunk.sh:120-140 in the same verb.'
expect_code 0 "$rc" "second ship naming the same file should launch: $out"
[ -e "$HOME_DIR/state/$id.meta" ] || fail "second ship wrote no task record"
echo "ok - two ships naming the same file launched"

# Capacity remains independent of the named files.
printf 'proj 2\n' > "$HOME_DIR/config/project-capacity"
lane 'Change bin/jg-other.sh only.'
expect_code 75 "$rc" "full project capacity should defer: $out"
assert_contains "$out" "deferred:" "capacity deferral missing"
[ ! -e "$HOME_DIR/state/$id.meta" ] || fail "capacity-deferred ship wrote a task record"
row=$(jg_test_backlog "$HOME_DIR" show "$id" 2>&1)
assert_contains "$row" "state: queued" "capacity-deferred ship left the queue"
echo "ok - capacity deferred the third ship with exit 75"

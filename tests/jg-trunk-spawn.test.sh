#!/usr/bin/env bash
# The spawn side of the trunk flow (bin/jg-spawn.sh, bin/jg-trunk.sh): a project with a local trunk takes no
# feature pull request, and a local-only lane starts on the trunk tip so its one commit can land there.
# Real bin/jg-brief.sh and bin/jg-spawn.sh over a fixture project; only the terminal and the worktree tool are
# stand-ins. tests/jg-trunk.test.sh owns landing, going live and the release.
#
# T1 a direct-PR or no-mistakes ship on a project registered local-trunk is refused by name and leaves no task record.
# T2 a local-only ship on that project spawns, and its isolated copy is on the trunk tip, not on the default branch.
# T3 a project registered direct-PR keeps spawning a pull-request lane as before.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-trunk-spawn)
W="$TMP_ROOT/world"; HOME_DIR="$W/home"; PROJ="$W/proj"
mkdir -p "$W"
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$W/origin.git" "$PROJ" 2>/dev/null
printf 'v1\n' > "$PROJ/AGENTS.md"; git -C "$PROJ" add -A; git -C "$PROJ" commit -qm c1
git -C "$PROJ" push -q origin HEAD:refs/heads/main; git -C "$PROJ" fetch -q
git -C "$PROJ" remote set-head origin main >/dev/null 2>&1 || true
jg_test_spawn_home "$HOME_DIR"
FAKEBIN=$(make_spawn_fakebin "$W/fake")
jg_test_fake_sleep_noop "$FAKEBIN"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$HOME_DIR/config/host-memory"

N=0
# ship <mode>: scaffold a real brief and spawn it onto its own isolated copy; sets id, out, rc, wt.
ship() {
  N=$((N + 1)); id=ts$N; wt="$W/wt-$id"
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$id" proj --mode "$1" --project "$PROJ" --migration-row none >/dev/null 2>&1 || fail "could not scaffold the $1 brief"
  sed -i 's/{TASK}/Exercise the trunk spawn./;s/{JUGGERNAUT_SPEC}/Exercise the trunk spawn end to end./' "$HOME_DIR/data/$id/brief.md"
  git -C "$PROJ" worktree add -q --detach "$wt" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy"
  out=$(jg_test_run_spawn "$HOME_DIR" "$wt" "$FAKEBIN" "$id" "$PROJ" codex --mode "$1" --yolo off); rc=$?
}

# T3 first: a direct-PR project spawns a pull-request lane as before (and keeps doing so even with a stray trunk record).
printf -- '- proj [direct-PR] - fixture (added 2026-11-07)\n' > "$HOME_DIR/data/projects.md"
ship direct-PR
expect_code 0 "$rc" "T3 a project with no trunk must keep spawning a pull-request lane: $out"
pass "T3 a direct-PR project keeps its pull-request lane"

# Stray trunk record on a direct-PR project: still no capture.
git -C "$PROJ" branch --no-track trunk origin/main; mkdir -p "$HOME_DIR/state"; git -C "$PROJ" rev-parse trunk > "$HOME_DIR/state/trunk-tip-proj"
ship direct-PR
expect_code 0 "$rc" "T3 a direct-PR project with a stray trunk record must still spawn a pull-request lane: $out"
[ "$(git -C "$wt" rev-parse HEAD)" = "$(git -C "$PROJ" rev-parse origin/main)" ] || fail "T3 a direct-PR lane must not be moved onto a trunk"
git -C "$PROJ" branch -D trunk >/dev/null; rm -f "$HOME_DIR/state/trunk-tip-proj"
printf -- '- proj [local-trunk] - fixture (added 2026-11-07)\n' > "$HOME_DIR/data/projects.md"
# Give the project a trunk one commit ahead of the default branch.
git -C "$PROJ" branch --no-track trunk origin/main
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "landed earlier" --no-verify 2>/dev/null
git -C "$PROJ" branch -f trunk HEAD
mkdir -p "$HOME_DIR/state"; git -C "$PROJ" rev-parse trunk > "$HOME_DIR/state/trunk-tip-proj"

# T1
for mode in direct-PR no-mistakes; do
  ship "$mode"
  expect_code 1 "$rc" "T1 a $mode ship on a project with a trunk must be refused: $out"
  assert_contains "$out" "is registered local-trunk, so it takes no feature pull request" "T1 the refusal must say why"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "T1 the refused spawn wrote a task record"
done
pass "T1 a pull-request lane on a project with a trunk is refused by name"

# T2
ship local-only
expect_code 0 "$rc" "T2 a local-only lane on a project with a trunk must spawn: $out"
[ "$(git -C "$wt" rev-parse HEAD)" = "$(git -C "$PROJ" rev-parse trunk)" ] || fail "T2 the lane's copy must start on the trunk tip"
pass "T2 a local-only lane starts on the trunk tip"
printf 'jg-trunk-spawn: ok\n'

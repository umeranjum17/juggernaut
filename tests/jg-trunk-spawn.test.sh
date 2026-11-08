#!/usr/bin/env bash
# The spawn side of the trunk flow (bin/jg-spawn.sh, bin/jg-trunk.sh): a project with a local trunk takes no
# feature pull request, and a local-trunk lane starts on the trunk tip so its one commit can land there.
# Real bin/jg-brief.sh and bin/jg-spawn.sh over a fixture project; only the terminal and the worktree tool are
# stand-ins. tests/jg-trunk.test.sh owns landing, going live and the release.
#
# T1 a direct-PR or no-mistakes ship on a project registered local-trunk is refused by name and leaves no task record.
# T2 a local-trunk ship on that project spawns, and its isolated copy is on the trunk tip, not on the default branch.
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
jg_test_beads_home "$HOME_DIR"
FAKEBIN=$(make_spawn_fakebin "$W/fake")
jg_test_fake_sleep_noop "$FAKEBIN"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$HOME_DIR/config/host-memory"

N=0
# ship <mode>: scaffold a real brief and spawn it onto its own isolated copy; sets id, out, rc, wt.
ship() {
  N=$((N + 1)); id=jg-ts$N; wt="$W/wt-$id"
  jg_test_add "$HOME_DIR" "$id" "[feature] trunk spawn $N"
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
# Initialize a real trunk one commit ahead of origin/main.
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "landed earlier"
JG_HOME="$HOME_DIR" "$ROOT/bin/jg-trunk.sh" init "$PROJ" HEAD >/dev/null || fail "trunk init"

# T1
for mode in direct-PR no-mistakes; do
  ship "$mode"
  expect_code 1 "$rc" "T1 a $mode ship on a project with a trunk must be refused: $out"
  assert_contains "$out" "is registered local-trunk, so it takes no feature pull request" "T1 the refusal must say why"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "T1 the refused spawn wrote a task record"
done
pass "T1 a pull-request lane on a project with a trunk is refused by name"

# T2
ship local-trunk
expect_code 0 "$rc" "T2 a local-only lane on a project with a trunk must spawn: $out"
[ "$(git -C "$wt" rev-parse HEAD)" = "$(git -C "$PROJ" rev-parse trunk)" ] || fail "T2 the lane's copy must start on the trunk tip"
[ "$(sed -n 's/^mode=//p' "$HOME_DIR/state/$id.meta")" = local-trunk ] || fail "T2 the task record must keep local-trunk"
assert_contains "$(cat "$HOME_DIR/data/$id/launch-brief.md")" "Delivery contract: mode=local-trunk" "T2 the launch contract must keep local-trunk"
pass "T2 a local-trunk lane starts on the trunk tip with its mode intact"
# Continue that real task through publication, automatic landing and real unforced cleanup.
# Only terminal/pool endpoints are fixtures; the repository, store, receipt and cleanup are real.
branch=$(sed -n 's/^branch=//p' "$HOME_DIR/state/$id.meta")
git -C "$wt" checkout -q -b "$branch"
printf 'Umer\n' > "$wt/work.txt"; git -C "$wt" add work.txt
git -C "$wt" commit -qm "ticket $id: local-trunk journey"
head=$(git -C "$wt" rev-parse HEAD)
cp -R "$ROOT/bin" "$HOME_DIR/bin"; ln -s "$ROOT/core" "$HOME_DIR/core"; ln -s "$ROOT/policy" "$HOME_DIR/policy"; ln -s "$ROOT/toolchain.versions" "$HOME_DIR/toolchain.versions"
# shellcheck disable=SC2016 # expanded by the gate in the candidate clone
printf 'gate-lint=test -s work.txt\ngate-full=test "$(cat work.txt)" = Umer\n' > "$HOME_DIR/config/trunk-policy"
printf 'real task journey; commit and receipt; no live or release requested\n' > "$HOME_DIR/data/$id/evidence.txt"
JG_HOME="$HOME_DIR" "$ROOT/core/receipts/bin/jg-run-receipt.sh" "$id" PASS "$HOME_DIR/data/$id/evidence.txt" "$wt" >/dev/null || fail "real receipt publisher"
[ "$(jq -r .mode "$HOME_DIR/state/$id.run-receipt.json")" = local-trunk ] || fail "receipt mode changed"
[ -z "$(git -C "$PROJ" for-each-ref --format='%(refname)' refs/remotes/origin/release/)" ] || fail "fixture must have no remote release ref"
JG_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_DIR" >/dev/null
for _ in $(seq 1 150); do
  [ ! -s "$HOME_DIR/data/jg-trunk-landing/outbox" ] || break
  grep -qE '^(final|wait) ' "$HOME_DIR/data/jg-trunk-landing/$id.$head.state" && break
  sleep 0.2
done
out=$(JG_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_DIR")
[ "$(git -C "$PROJ" rev-parse trunk)" = "$head" ] || fail "automatic landing did not select the exact proved head: $out"
assert_contains "$out" "(local-trunk)" "landing outcome must retain the mode"
assert_contains "$out" "cleaned up" "real cleanup must succeed with no release ref"
[ ! -e "$HOME_DIR/state/$id.meta" ] || fail "real cleanup must remove the task record"
assert_contains "$(jg_test_backlog "$HOME_DIR" show "$id")" "local-trunk" "completed task must retain its delivery identity"
snapshot=$(JG_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$ROOT/bin/jg-fleet-snapshot.sh" --json)
[ "$(jq -r --arg id "$id" '.backlog.records[] | select(.id == $id) | .local_note' <<<"$snapshot")" = local-trunk ] || fail "completed fleet status must retain local-trunk"
pass "T2 the exact proved local-trunk head lands and cleans up without a remote release ref"

ship local-only
expect_code 0 "$rc" "T2 legacy local-only task contracts must still launch: $out"
[ "$(sed -n 's/^mode=//p' "$HOME_DIR/state/$id.meta")" = local-only ] || fail "T2 legacy task records must not be rewritten"
printf 'jg-trunk-spawn: ok\n'

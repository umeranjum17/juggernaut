#!/usr/bin/env bash
# A held task-set lock is a wait, not a verdict: a fresh spawn that finds this home's task set locked defers with exit 75 and a
# deferred: line (the same deferral as a full pool), creates nothing and leaves its backlog item queued, so the dispatch check
# resumes it under the same approval. Real bin/jg-brief.sh and bin/jg-spawn.sh over a fixture project; only the terminal and the
# worktree tool are stand-ins. Spawn is run twice for the same ticket: while the lock is held, and after its holder lets go.
#
# T1 the task set is locked by another operation: exit 75, one deferred: line that names the lock, no task record, still queued.
# T2 the lock is released: the same ticket spawns on the next try with no other change.
# T3 core/auto-dispatch/dispatch.sh reads the real spawn's exit 75 as a deferral and starts the ticket under the same approval.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/jg-wake-lib.sh
. "$ROOT/bin/jg-wake-lib.sh"

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-spawn-lock-deferral)
W="$TMP_ROOT/world"; HOME_DIR="$W/home"; PROJ="$W/proj"
mkdir -p "$W"
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$W/origin.git" "$PROJ" 2>/dev/null
printf 'v1\n' > "$PROJ/AGENTS.md"; git -C "$PROJ" add -A; git -C "$PROJ" commit -qm c1
git -C "$PROJ" push -q origin HEAD:refs/heads/main; git -C "$PROJ" fetch -q
git -C "$PROJ" remote set-head origin main >/dev/null 2>&1 || true
FAKEBIN=$(make_spawn_fakebin "$W/fake")
jg_test_fake_sleep_noop "$FAKEBIN"
jg_test_spawn_home "$HOME_DIR"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$HOME_DIR/config/host-memory"

id=jg-ld1; wt="$W/wt-$id"
jg_test_add "$HOME_DIR" "$id" "[feature] lock deferral"
JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$id" proj --mode direct-PR --project "$PROJ" --migration-row none >/dev/null 2>&1 \
  || fail "could not scaffold the brief for $id"
sed -i 's/{TASK}/Exercise the lock deferral./;s/{JUGGERNAUT_SPEC}/Exercise the lock deferral end to end./' "$HOME_DIR/data/$id/brief.md"
git -C "$PROJ" worktree add -q --detach "$wt" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy"
try_spawn() { out=$(jg_test_run_spawn "$HOME_DIR" "$wt" "$FAKEBIN" "$id" "$PROJ" codex --mode direct-PR --yolo off); rc=$?; }

# T1: another operation holds the task set.
LOCK=$(jg_task_set_lock_path "$HOME_DIR/state")
jg_lock_try_acquire "$LOCK" || fail "setup: could not take the task-set lock"
try_spawn
expect_code 75 "$rc" "T1 a spawn that finds the task set locked should defer: $out"
assert_contains "$out" "deferred: this home's task set is locked by another operation" "T1 the deferral does not name the lock"
assert_contains "$out" "stays queued" "T1 the deferral does not say the task stays queued"
case $out in *"error:"*) fail "T1 a lock deferral must not read as an error: $out" ;; esac
[ ! -e "$HOME_DIR/state/$id.meta" ] || fail "T1 the deferred spawn wrote a task record"
row=$(jg_test_backlog "$HOME_DIR" show "$id" 2>&1)
assert_contains "$row" "state: queued" "T1 the backlog item left the queue"
pass "T1 a locked task set defers the spawn with exit 75, creates nothing and leaves the ticket queued"

# T2: the holder lets go; the same ticket spawns with nothing else changed.
jg_lock_release "$LOCK" || fail "setup: could not release the task-set lock"
try_spawn
expect_code 0 "$rc" "T2 the same spawn should start once the lock is free: $out"
[ -f "$HOME_DIR/state/$id.meta" ] || fail "T2 the spawn left no lane record"
pass "T2 the same spawn starts once the lock is free"

# T3: the dispatch check reads that exit 75 as a deferral and resumes it under the same approval. A second ticket, spawned by the
# real spawn through the check's own wrapper, while the lock is held and after.
id2=jg-ld2; wt2="$W/wt-$id2"
jg_test_add "$HOME_DIR" "$id2" "[feature] lock deferral two"
JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$id2" proj --mode direct-PR --project "$PROJ" --migration-row none >/dev/null 2>&1 \
  || fail "could not scaffold the brief for $id2"
rec="$HOME_DIR/data/auto-dispatch/$id2.start.1"
mkdir -p "$HOME_DIR/data/auto-dispatch"
printf 'attempt=1\ntask=%s\napproved-at=1\nlaunched-at=%s\nroute=codex x x\n' "$id2" "$(date +%s)" > "$rec"
git -C "$PROJ" worktree add -q --detach "$wt2" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy"
jg_lock_try_acquire "$LOCK" || fail "setup: could not take the task-set lock"
# The wrapper is the check's own: it runs the real spawn and writes what it did into the record.
wrap() { JG_HOME="$HOME_DIR" bash "$ROOT/core/auto-dispatch/dispatch.sh" run "$HOME_DIR" "$rec" "$id2" "$W/spawn2.log" "$@"; }
spawn2_cmd=(env JG_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$ROOT/bin/jg-spawn.sh" "$id2" "$PROJ" codex --mode direct-PR --yolo off --ticket "$id2")
wrap "${spawn2_cmd[@]}"
assert_contains "$(cat "$rec")" "result=deferred" "T3 the wrapper records the real spawn's exit 75 as a deferral"
assert_contains "$(cat "$rec")" "rc=75" "T3 the record holds the real exit code"
assert_contains "$(cat "$rec")" "reason=deferred: this home's task set is locked" "T3 the record holds the spawn's own words"
pass "T3 the dispatch wrapper records the real spawn's lock deferral as a deferral"
jg_lock_release "$LOCK" || true

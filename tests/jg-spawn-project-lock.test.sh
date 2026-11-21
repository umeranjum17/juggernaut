#!/usr/bin/env bash
# A spawn that finds the machine-wide project lock held waits its turn: it is a wait, not an error. Real bin/jg-brief.sh and
# bin/jg-spawn.sh over a fixture project; only the terminal and the worktree tool are stand-ins.
#
# T1 ten fresh spawns of one project at once: ten records, every exit 0, at least one "waiting:" line; the wall time is printed.
# T2 another process holds the project lock for the whole test and JG_SPAWN_PROJECT_LOCK_WAIT=2: the spawn exits 75 with the
#    "deferred:" line 2 to 4 s after its "waiting:" line and creates no record.
# T3 JG_SPAWN_PROJECT_LOCK_WAIT=0 with the lock held: exit 1 and the single-try "refusing to race it" line.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/jg-wake-lib.sh
. "$ROOT/bin/jg-wake-lib.sh"

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-spawn-project-lock)
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

# New fresh task <id> of the one project, with its brief and its isolated copy.
prepare() {  # <id>
  local id=$1
  jg_test_add "$HOME_DIR" "$id" "[feature] project lock $id"
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$id" proj --mode direct-PR --project "$PROJ" --migration-row none >/dev/null 2>&1 \
    || fail "could not scaffold the brief for $id"
  sed -i 's/{TASK}/Exercise the project lock./;s/{JUGGERNAUT_SPEC}/Exercise the project lock end to end./' "$HOME_DIR/data/$id/brief.md"
  git -C "$PROJ" worktree add -q --detach "$W/wt-$id" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy for $id"
}

# T1: ten fresh spawns of one project at once.
T1_IDS=(jg-pl01 jg-pl02 jg-pl03 jg-pl04 jg-pl05 jg-pl06 jg-pl07 jg-pl08 jg-pl09 jg-pl10)
T1_OUT="$W/t1"; mkdir -p "$T1_OUT"
for id in "${T1_IDS[@]}"; do prepare "$id"; done
t1_start=$(date +%s)
for id in "${T1_IDS[@]}"; do
  ( o=$(jg_test_run_spawn "$HOME_DIR" "$W/wt-$id" "$FAKEBIN" "$id" "$PROJ" codex --mode direct-PR --yolo off 2>&1); rc=$?
    printf '%s\n' "$o" > "$T1_OUT/$id.out"; printf '%s\n' "$rc" > "$T1_OUT/$id.rc" ) &
done
wait
t1_took=$(( $(date +%s) - t1_start ))
for id in "${T1_IDS[@]}"; do
  [ "$(cat "$T1_OUT/$id.rc" 2>/dev/null)" = 0 ] || fail "T1 the parallel spawn of $id should exit 0: $(cat "$T1_OUT/$id.out" 2>/dev/null)"
  [ -f "$HOME_DIR/state/$id.meta" ] || fail "T1 the parallel spawn of $id left no task record"
done
grep -q '^waiting: the project lock for ' "$T1_OUT"/*.out || fail "T1 no spawn reported waiting for the project lock"
echo "T1 wall time for ${#T1_IDS[@]} spawns: ${t1_took}s"
[ "$t1_took" -lt 60 ] || fail "T1 ten spawns took ${t1_took}s, over the 60 s bound"
pass "T1 ten fresh spawns of one project at once all wait their turn and publish a record"

# T2, T3: another process holds the project lock.
id2=jg-pl-held; prepare "$id2"
LOCK=$(JG_HOME="$HOME_DIR" jg_treehouse_project_lock_path "$PROJ") || fail "setup: could not resolve the project lock"
jg_lock_try_acquire "$LOCK" || fail "setup: could not take the project lock"
# The holder is this shell, so a spawn child sees a live foreign owner.
# Each output line is stamped in ms as it arrives, so the wait is timed from the "waiting:" line to the "deferred:" line and
# the spawn's own start-up work, which a loaded runner slows, is not counted in it.
JG_SPAWN_PROJECT_LOCK_WAIT=2 jg_test_run_spawn "$HOME_DIR" "$W/wt-$id2" "$FAKEBIN" "$id2" "$PROJ" codex --mode direct-PR --yolo off 2>&1 \
  | while IFS= read -r line; do printf '%s %s\n' "$(date +%s%3N)" "$line"; done > "$W/t2.stamped"
rc=${PIPESTATUS[0]}
out=$(cut -d' ' -f2- "$W/t2.stamped")
stamp_of() { awk -v p="$1" 'index(substr($0, index($0, " ") + 1), p) == 1 { print $1; exit }' "$W/t2.stamped"; }
t2_waiting=$(stamp_of "waiting: the project lock for "); t2_deferred=$(stamp_of "deferred: the project lock for ")
t2_took=$(( ${t2_deferred:-0} - ${t2_waiting:-0} ))
expect_code 75 "$rc" "T2 a spawn whose wait ran out should defer: $out"
assert_contains "$out" "waiting: the project lock for " "T2 the first failed try did not say it waits"
assert_contains "$out" "deferred: the project lock for " "T2 the deferral does not name the project lock"
assert_contains "$out" "was not created and stays queued" "T2 the deferral does not say the task stays queued"
case $out in *"error:"*) fail "T2 a lock deferral must not read as an error: $out" ;; esac
[ -n "$t2_waiting" ] && [ -n "$t2_deferred" ] || fail "T2 the waiting and deferred lines were not both stamped: $(cat "$W/t2.stamped")"
[ "$t2_took" -ge 2000 ] && [ "$t2_took" -le 4000 ] || fail "T2 the spawn waited ${t2_took} ms for the lock, not 2 to 4 s"
[ ! -e "$HOME_DIR/state/$id2.meta" ] || fail "T2 the deferred spawn wrote a task record"
pass "T2 a spawn whose wait ran out defers with exit 75 after waiting ${t2_took} ms for the lock and creates nothing"

out=$(JG_SPAWN_PROJECT_LOCK_WAIT=0 jg_test_run_spawn "$HOME_DIR" "$W/wt-$id2" "$FAKEBIN" "$id2" "$PROJ" codex --mode direct-PR --yolo off 2>&1); rc=$?
jg_lock_release "$LOCK" || true
expect_code 1 "$rc" "T3 a zero wait should keep the single try and exit 1: $out"
assert_contains "$out" "refusing to race it" "T3 the single-try refusal line is gone"
assert_not_contains "$out" "waiting:" "T3 a zero wait must not wait"
pass "T3 JG_SPAWN_PROJECT_LOCK_WAIT=0 keeps the single try and its exit 1"

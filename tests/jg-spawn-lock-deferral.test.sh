#!/usr/bin/env bash
# A held task-set lock is a wait, not a verdict: a fresh spawn that finds this home's task set locked defers with exit 75 and a
# deferred: line (the same deferral as a full pool), creates nothing and leaves its backlog item queued, so the dispatch check
# resumes it under the same approval. Real bin/jg-brief.sh and bin/jg-spawn.sh over a fixture project; only the terminal and the
# worktree tool are stand-ins. Spawn is run twice for the same ticket: while the lock is held, and after its holder lets go.
#
# T1 the task set is locked by another operation: exit 75, one deferred: line that names the lock, no task record, still queued.
# T2 the lock is released: the same ticket spawns on the next try with no other change.
# T3 core/auto-dispatch/dispatch.sh reads the real spawn's exit 75 as a deferral and starts the ticket under the same approval.
# T4 five fresh spawns at once in one home (each for its own project) all pass the task-set lock: five records, no lock deferral.
# T5 a forced teardown holds the lock: a spawn defers at once, naming "a forced teardown", and creates no record.
# T6 a joined entry of a live process is listed by jg_task_set_live_joiners; once that process is gone the entry is dropped.
# T7 the forced-teardown check refuses while a live joiner exists and goes on with none.
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
# A lock with no role is not a forced teardown, so a spawn waits the join wait for it; keep that short here.
export JG_TASK_SET_JOIN_WAIT=1
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

# A fixture project of its own: its own origin, because the project lock is keyed by the origin.
own_project() {  # <name>
  local n=$1
  git clone -q --bare "$W/origin.git" "$W/origin-$n.git" 2>/dev/null
  git clone -q "$W/origin-$n.git" "$W/proj-$n" 2>/dev/null
  git -C "$W/proj-$n" remote set-head origin main >/dev/null 2>&1 || true
}

# T4: five fresh spawns at once, each for its own project so no project lock is shared. Before the join they excluded each other
# on the task-set lock: one record and four "task set is locked" deferrals.
unset JG_TASK_SET_JOIN_WAIT
T4_IDS=(jg-ld41 jg-ld42 jg-ld43 jg-ld44 jg-ld45)
T4_OUT="$W/t4"; mkdir -p "$T4_OUT"
for t4 in "${T4_IDS[@]}"; do
  p4="$W/proj-$t4"; wt4="$W/wt-$t4"
  own_project "$t4"
  jg_test_add "$HOME_DIR" "$t4" "[feature] parallel spawn $t4"
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$t4" "proj-$t4" --mode direct-PR --project "$p4" --migration-row none >/dev/null 2>&1 \
    || fail "could not scaffold the brief for $t4"
  sed -i 's/{TASK}/Exercise the parallel spawn./;s/{JUGGERNAUT_SPEC}/Exercise the parallel spawn end to end./' "$HOME_DIR/data/$t4/brief.md"
  git -C "$p4" worktree add -q --detach "$wt4" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy for $t4"
done
for t4 in "${T4_IDS[@]}"; do
  ( o=$(jg_test_run_spawn "$HOME_DIR" "$W/wt-$t4" "$FAKEBIN" "$t4" "$W/proj-$t4" codex --mode direct-PR --yolo off 2>&1); rc=$?
    printf '%s\n' "$o" > "$T4_OUT/$t4.out"; printf '%s\n' "$rc" > "$T4_OUT/$t4.rc" ) &
done
wait
for t4 in "${T4_IDS[@]}"; do
  [ "$(cat "$T4_OUT/$t4.rc" 2>/dev/null)" = 0 ] || fail "T4 the parallel spawn of $t4 should exit 0: $(cat "$T4_OUT/$t4.out" 2>/dev/null)"
  [ -f "$HOME_DIR/state/$t4.meta" ] || fail "T4 the parallel spawn of $t4 left no task record"
done
case $(cat "$T4_OUT"/*.out) in *"task set is locked"*) fail "T4 a parallel spawn deferred on the task-set lock" ;; esac
pass "T4 five fresh spawns at once all pass the task-set lock and publish a record"

# T5: a forced teardown holds the lock and says so; a spawn does not wait for it.
id5=jg-ld5; p5="$W/proj-$id5"; wt5="$W/wt-$id5"
own_project "$id5"
jg_test_add "$HOME_DIR" "$id5" "[feature] spawn under a forced teardown"
JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$id5" "proj-$id5" --mode direct-PR --project "$p5" --migration-row none >/dev/null 2>&1 \
  || fail "could not scaffold the brief for $id5"
git -C "$p5" worktree add -q --detach "$wt5" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy for $id5"
jg_lock_try_acquire "$LOCK" || fail "setup: could not take the task-set lock"
jg_lock_set_role "$LOCK" forced-teardown || fail "setup: could not set the forced-teardown role"
t5_start=$(date +%s)
out=$(jg_test_run_spawn "$HOME_DIR" "$wt5" "$FAKEBIN" "$id5" "$p5" codex --mode direct-PR --yolo off 2>&1); rc=$?
t5_took=$(( $(date +%s) - t5_start ))
jg_lock_release "$LOCK" || true
expect_code 75 "$rc" "T5 a spawn under a forced teardown should defer: $out"
[ "$t5_took" -lt 2 ] || fail "T5 the spawn waited ${t5_took}s for a forced teardown instead of deferring at once"
assert_contains "$out" "deferred: this home's task set is locked by a forced teardown" "T5 the deferral does not name the forced teardown"
[ ! -e "$HOME_DIR/state/$id5.meta" ] || fail "T5 the deferred spawn wrote a task record"
pass "T5 a spawn defers at once, naming the forced teardown, and creates nothing"

# T6: a joined entry of a live process is listed; once the process is gone the entry is dropped.
sleep 30 & sleeper=$!
disown "$sleeper" 2>/dev/null || true
if [ -r "/proc/$sleeper/stat" ]; then
  sleeper_stat=$(cat "/proc/$sleeper/stat"); sleeper_start=$(printf '%s\n' "${sleeper_stat##*) }" | awk '{print $20}')
else
  sleeper_start=$(ps -o lstart= -p "$sleeper" | sed 's/^ *//')
fi
mkdir -p "$LOCK.joined"
printf 'pid=%s\nstart=%s\n' "$sleeper" "$sleeper_start" > "$LOCK.joined/jg-ld6"
live=$(jg_task_set_live_joiners "$LOCK")
assert_contains "$live" "jg-ld6" "T6 a live joined entry is not listed"
kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null || true
live=$(jg_task_set_live_joiners "$LOCK")
[ -z "$live" ] || fail "T6 a joined entry of a dead process is still listed: $live"
[ ! -e "$LOCK.joined/jg-ld6" ] || fail "T6 the entry of a dead process was not removed"
pass "T6 live joiners are listed and a dead joiner's entry is dropped"

# T7: the check the forced teardown makes, with and without a live joiner. The teardown calls the same function and refuses on
# any id it prints; bin/jg-teardown.sh carries the refusal text.
sleep 30 & sleeper=$!
disown "$sleeper" 2>/dev/null || true
if [ -r "/proc/$sleeper/stat" ]; then
  sleeper_stat=$(cat "/proc/$sleeper/stat"); sleeper_start=$(printf '%s\n' "${sleeper_stat##*) }" | awk '{print $20}')
else
  sleeper_start=$(ps -o lstart= -p "$sleeper" | sed 's/^ *//')
fi
printf 'pid=%s\nstart=%s\n' "$sleeper" "$sleeper_start" > "$LOCK.joined/jg-ld7"
[ -n "$(jg_task_set_live_joiners "$LOCK")" ] || fail "T7 the teardown check does not see a live joiner"
# shellcheck disable=SC2016 # The text to find holds a literal $joiners.
grep -qF 'is publishing a task right now ($joiners)' "$ROOT/bin/jg-teardown.sh" || fail "T7 the teardown does not carry the joiner refusal"
kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null || true
[ -z "$(jg_task_set_live_joiners "$LOCK")" ] || fail "T7 the teardown check refuses with no live joiner"
pass "T7 the teardown check refuses with a live joiner and goes on with none"

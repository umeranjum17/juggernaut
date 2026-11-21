#!/usr/bin/env bash
# A fresh spawn of a project with no declared capacity holds the shared Treehouse project lock only from the capacity lookup
# through the lease and the slot owner claim (and, for a project that is not local-trunk, through the base refresh's fetches);
# everything after that runs while the project's other spawns lease their copies. Real bin/jg-brief.sh and bin/jg-spawn.sh over
# fixture projects whose pool slots are real git worktrees of one clone; only the terminal and the worktree tool are stand-ins.
# The test hook JG_SPAWN_TEST_AFTER_LEASE runs right after the lock is let go (after the claim for a local-trunk project, after
# the base refresh for any other), so `sleep 2` there is what the other spawns overlap. Before it sleeps, the hook records
# whether its own spawn (the hook's parent process) still owns a project lock, so the span is checked by the lock's owner and not
# by a wall time a loaded runner stretches.
#
# T1 overlap: 8 spawns of one project with no declared capacity, at once: all publish, and no spawn owns the project lock in
#    its hook (the wall time is printed: about 8 s measured; one at a time they take over 23 s).
# T1b the same for a local-trunk project, whose lock is let go right after the claim.
# T2 capacity: the same with a declared capacity of 3: 3 publish and 5 defer with exit 75 (the lock still spans publication).
# T3 full: JG_SPAWN_PROJECT_LOCK_SPAN=full: all 8 publish, every spawn owns the project lock in its hook, and the wall time is
#    16 s or more.
# T4 failure after the lease: a hook that exits 1 fails the spawn, keeps its copy leased with a recovery record, frees the lock.
# T5 return during a spawn: while spawn A sleeps in the hook (lock free, no record yet), a cleanup of another task returns its
#    own slot: A's slot is not returned, A's claim stays, and A publishes its record.
# T6 fetch stays serial: a project with an origin, 3 branches and no trunk, whose origin moves while 8 spawns fetch it: all
#    publish, none prints "could not fetch", and no spawn owns the project lock in the hook after the base refresh. With the
#    release moved before the base refresh, 5 of the 8 spawns refuse to fetch.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-spawn-project-lock-span)
W="$TMP_ROOT/world"; HOME_DIR="$W/home"
mkdir -p "$W"
REAL_SLEEP=$(command -v sleep)
FAKEBIN=$(make_spawn_fakebin "$W/fake" gh gh-axi)
jg_test_fake_sleep_noop "$FAKEBIN"
# The worktree tool: `get --lease` answers the spawn's own pane path (its pool slot), `return` is logged.
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get) printf '%s\n' "${JG_FAKE_PANE_PATH:-}" ;;
  return) printf 'return %s\n' "$*" >> "$JG_TH_LOG" ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/treehouse"
export JG_TH_LOG="$W/treehouse.log"; : > "$JG_TH_LOG"
jg_test_spawn_home "$HOME_DIR"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$HOME_DIR/config/host-memory"
: > "$HOME_DIR/data/projects.md"
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$W/origin.git" "$W/seed" 2>/dev/null
printf 'v1\n' > "$W/seed/AGENTS.md"; git -C "$W/seed" add -A; git -C "$W/seed" commit -qm c1
git -C "$W/seed" push -q origin HEAD:refs/heads/main

now_ms() { date +%s%3N; }

# make_case <name> <count> [trunk]: project <name> with its own origin (the project lock is keyed by the origin), <count>
# pool slots that are real worktrees of its one clone, and <count> scaffolded tasks jg-sl<name>-1.. each on its own slot.
make_case() {
  local name=$1 n=$2 trunk=${3:-} i p id mode=direct-PR
  p="$W/$name"
  git clone -q --bare "$W/origin.git" "$W/origin-$name.git" 2>/dev/null
  git clone -q "$W/origin-$name.git" "$p" 2>/dev/null
  git -C "$p" remote set-head origin main >/dev/null 2>&1 || true
  if [ -n "$trunk" ]; then
    mode=local-trunk
    git -C "$p" branch release/v12 origin/main
    git -C "$p" rev-parse release/v12 > "$HOME_DIR/state/trunk-tip-$name"
    printf 'release/v12\n' > "$HOME_DIR/state/trunk-branch-$name"
  fi
  printf -- '- %s [%s] - fixture (added 2026-11-20)\n' "$name" "$mode" >> "$HOME_DIR/data/projects.md"
  mkdir -p "$W/pool-$name"
  printf '{"worktrees":[]}\n' > "$W/pool-$name/treehouse-state.json"
  for i in $(seq 1 "$n"); do
    id="jg-sl$name-$i"
    mkdir -p "$W/pool-$name/$i"
    git -C "$p" worktree add -q --detach "$W/pool-$name/$i/repo" origin/main >/dev/null 2>&1 || fail "could not prepare slot $i of $name"
    jg_test_add "$HOME_DIR" "$id" "[feature] project lock span $name $i"
    JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$id" "$name" --mode "$mode" --project "$p" --migration-row none >/dev/null 2>&1 \
      || fail "could not scaffold the brief for $id"
    sed -i 's/{TASK}/Exercise the lock span./;s/{JUGGERNAUT_SPEC}/Exercise the lock span end to end./' "$HOME_DIR/data/$id/brief.md"
  done
  CASE_MODE=$mode
}

# spawn_one <name> <index> <outdir>: one real spawn of task jg-sl<name>-<index>; writes <outdir>/<id>.out and .rc.
spawn_one() {
  local name=$1 i=$2 outdir=$3 id="jg-sl$1-$2" o rc
  o=$(jg_test_run_spawn "$HOME_DIR" "$W/pool-$name/$i/repo" "$FAKEBIN" "$id" "$W/$name" codex --mode "$CASE_MODE" --yolo off 2>&1); rc=$?
  printf '%s\n' "$o" > "$outdir/$id.out"; printf '%s\n' "$rc" > "$outdir/$id.rc"
}

# run_case <name> <count>: all spawns at once; CASE_OUT is the output directory, CASE_WALL the wall time in ms.
run_case() {
  local name=$1 n=$2 i start
  CASE_OUT="$W/out-$name"; mkdir -p "$CASE_OUT"
  : > "$JG_HOOK_LOG"
  start=$(now_ms)
  local pids=()
  for i in $(seq 1 "$n"); do spawn_one "$name" "$i" "$CASE_OUT" & pids+=($!); done
  wait "${pids[@]}"
  CASE_WALL=$(( $(now_ms) - start ))
}

# count_rc <outdir> <name> <code>: how many of the case's spawns exited <code>.
count_rc() { grep -lx "$3" "$1"/jg-sl"$2"-*.rc 2>/dev/null | wc -l | tr -d ' '; }
published() { local c=0 f; for f in "$HOME_DIR"/state/jg-sl"$1"-*.meta; do [ -f "$f" ] && c=$((c + 1)); done; printf '%s\n' "$c"; }
all_out() { cat "$1"/*.out 2>/dev/null; }

# hook_count <word>: how many hooks of the last run_case recorded <word>: "held" (the spawn owned a project lock in its hook)
# or "free".
hook_count() { grep -cx "$1" "$JG_HOOK_LOG" 2>/dev/null || true; }

export JG_HOOK_LOG="$W/hook.log" JG_LOCK_ROOT="$HOME_DIR/state"
# shellcheck disable=SC2016 # The hook's own shell expands these.
export JG_SPAWN_TEST_AFTER_LEASE='s=free; for l in "$JG_LOCK_ROOT"/.treehouse-project-*.lock; do [ "$(cat "$l/pid" 2>/dev/null)" = "$PPID" ] && s=held; done; echo "$s" >> "$JG_HOOK_LOG"; '"$REAL_SLEEP"' 2'

# T1: eight spawns of one project with no declared capacity overlap in the hook.
make_case t1 8
run_case t1 8
[ "$(count_rc "$CASE_OUT" t1 0)" = 8 ] || fail "T1 all 8 spawns should exit 0: $(all_out "$CASE_OUT")"
[ "$(published t1)" = 8 ] || fail "T1 8 records should be published, found $(published t1)"
[ "$(hook_count free)" = 8 ] && [ "$(hook_count held)" = 0 ] || fail "T1 a spawn still owned the project lock in its hook: $(hook_count held) held, $(hook_count free) free"
pass "T1 eight spawns of one project overlap after the lease: 8 records in ${CASE_WALL} ms"

# T1b: the same for a local-trunk project, whose lock is let go right after the claim.
make_case t1b 8 trunk
run_case t1b 8
[ "$(count_rc "$CASE_OUT" t1b 0)" = 8 ] || fail "T1b all 8 spawns should exit 0: $(all_out "$CASE_OUT")"
[ "$(published t1b)" = 8 ] || fail "T1b 8 records should be published, found $(published t1b)"
[ "$(hook_count free)" = 8 ] && [ "$(hook_count held)" = 0 ] || fail "T1b a spawn still owned the project lock in its hook: $(hook_count held) held, $(hook_count free) free"
pass "T1b eight spawns of a local-trunk project overlap after the claim: 8 records in ${CASE_WALL} ms"

# T2: a declared capacity keeps the span: the lock covers publication, so 3 publish and 5 defer.
make_case t2 8
printf 't2 3\n' > "$HOME_DIR/config/project-capacity"
run_case t2 8
rm -f "$HOME_DIR/config/project-capacity"
[ "$(count_rc "$CASE_OUT" t2 0)" = 3 ] || fail "T2 3 spawns should publish: $(all_out "$CASE_OUT")"
[ "$(count_rc "$CASE_OUT" t2 75)" = 5 ] || fail "T2 5 spawns should exit 75: $(all_out "$CASE_OUT")"
[ "$(published t2)" = 3 ] || fail "T2 3 records should be published, found $(published t2)"
assert_contains "$(all_out "$CASE_OUT")" "deferred: project t2 admits 3 worker(s) at once on this machine" "T2 the deferral line is not today's"
pass "T2 a declared capacity of 3 keeps today's span: 3 publish and 5 defer with exit 75"

# T3: the full span keeps today's behaviour.
make_case t3 8
JG_SPAWN_PROJECT_LOCK_SPAN=full run_case t3 8
[ "$(count_rc "$CASE_OUT" t3 0)" = 8 ] || fail "T3 all 8 spawns should exit 0: $(all_out "$CASE_OUT")"
[ "$(published t3)" = 8 ] || fail "T3 8 records should be published, found $(published t3)"
[ "$(hook_count held)" = 8 ] || fail "T3 every spawn of the full span should own the project lock in its hook: $(hook_count held) held, $(hook_count free) free"
[ "$CASE_WALL" -ge 16000 ] || fail "T3 the full span took ${CASE_WALL} ms: 8 spawns with a 2 s hook should run one at a time (16 s)"
pass "T3 JG_SPAWN_PROJECT_LOCK_SPAN=full keeps one spawn at a time: ${CASE_WALL} ms"

# T4: a failure after the lease. The copy stays leased with a recovery record, the lock is free, and the project spawns on.
make_case t4 2
CASE_OUT="$W/out-t4"; mkdir -p "$CASE_OUT"
JG_SPAWN_TEST_AFTER_LEASE='exit 1' spawn_one t4 1 "$CASE_OUT"
[ "$(cat "$CASE_OUT/jg-slt4-1.rc")" = 1 ] || fail "T4 a failing hook should fail the spawn: $(cat "$CASE_OUT/jg-slt4-1.out")"
assert_contains "$(cat "$CASE_OUT/jg-slt4-1.out")" "JG_SPAWN_TEST_AFTER_LEASE" "T4 the failure does not name the hook"
grep -q '^return' "$JG_TH_LOG" && fail "T4 the failed spawn returned a copy: $(cat "$JG_TH_LOG")"
grep -qx 'cleanup_recovery=treehouse' "$HOME_DIR/state/jg-slt4-1.meta" 2>/dev/null || fail "T4 the failed spawn left no recovery record for its leased copy"
for l in "$HOME_DIR"/state/.treehouse-project-*.lock; do [ -d "$l" ] && fail "T4 the project lock is still held after the failed spawn"; done
JG_SPAWN_TEST_AFTER_LEASE=: spawn_one t4 2 "$CASE_OUT"
[ "$(cat "$CASE_OUT/jg-slt4-2.rc")" = 0 ] || fail "T4 the next spawn of the project should publish: $(cat "$CASE_OUT/jg-slt4-2.out")"
pass "T4 a failure after the lease keeps the copy for recovery, frees the lock and lets the next spawn run"

# T5: a cleanup of another task returns its own slot while spawn A sits in the hook with no record yet.
make_case t5 2
B=jg-slt5-2; A=jg-slt5-1; bslot="$W/pool-t5/2/repo"
git -C "$W/t5" worktree remove --force "$bslot" >/dev/null 2>&1
git -C "$W/t5" worktree add -q -b fm/$B "$bslot" origin/main >/dev/null 2>&1 || fail "T5 could not prepare the other task's copy"
printf '{"worktrees":[{"name":"2","path":"%s"}]}\n' "$bslot" > "$W/pool-t5/treehouse-state.json"
jg_test_backlog "$HOME_DIR" start "$B" >/dev/null || fail "T5 could not start the other task"
jg_write_meta "$HOME_DIR/state/$B.meta" "window=juggernaut:jg-$B" "endpoint_task_id=$B" "worktree=$bslot" "project=$W/t5" \
  "kind=ship" "mode=local-only" "spawn_gen=t5-$B"
printf 'task=%s\nhome=%s\n' "$B" "$HOME_DIR" > "$W/pool-t5/2/.jg-slot-owner"
CASE_OUT="$W/out-t5"; mkdir -p "$CASE_OUT"; rm -f "$W/t5.hooked"
( export JG_SPAWN_TEST_AFTER_LEASE=": > '$W/t5.hooked'; $REAL_SLEEP 6"; spawn_one t5 1 "$CASE_OUT" ) &
a_pid=$!
for _ in $(seq 1 200); do [ -e "$W/t5.hooked" ] && break; "$REAL_SLEEP" 0.1; done
[ -e "$W/t5.hooked" ] || fail "T5 spawn A never reached the hook: $(cat "$CASE_OUT"/*.out 2>/dev/null)"
[ ! -e "$HOME_DIR/state/$A.meta" ] || fail "T5 spawn A published before the hook ended"
for l in "$HOME_DIR"/state/.treehouse-project-*.lock; do [ -d "$l" ] && fail "T5 the project lock is held while spawn A sits in the hook"; done
td_rc=0
env JG_HOME="$HOME_DIR" JG_ROOT_OVERRIDE="$ROOT" JG_STATE_OVERRIDE="$HOME_DIR/state" JG_DATA_OVERRIDE="$HOME_DIR/data" \
  JG_CONFIG_OVERRIDE="$HOME_DIR/config" PATH="$FAKEBIN:$PATH" "$ROOT/bin/jg-teardown.sh" "$B" > "$W/t5.teardown" 2>&1 || td_rc=$?
[ "$td_rc" = 0 ] || fail "T5 the cleanup of the other task exited $td_rc: $(cat "$W/t5.teardown")"
wait "$a_pid"
grep -q "$bslot" "$JG_TH_LOG" || fail "T5 the cleanup did not return its own slot: $(cat "$JG_TH_LOG")"
grep -q "$W/pool-t5/1/repo" "$JG_TH_LOG" && fail "T5 spawn A's slot was returned: $(cat "$JG_TH_LOG")"
[ "$(cat "$CASE_OUT/$A.rc")" = 0 ] || fail "T5 spawn A should publish: $(cat "$CASE_OUT/$A.out")"
[ -f "$HOME_DIR/state/$A.meta" ] || fail "T5 spawn A left no record"
[ "$(sed -n 's/^task=//p' "$W/pool-t5/1/.jg-slot-owner")" = "$A" ] || fail "T5 spawn A's slot claim is gone or changed"
pass "T5 a cleanup returning another task's slot while spawn A sits in the hook leaves A's slot and record alone"

# T6: a project with an origin and no trunk keeps its fetches into the shared refs one at a time, while the origin moves.
make_case t6 8
# Hold each update of origin/main open for 150 ms (the ref's .lock file stays until the transaction ends), so a second
# fetch into the same shared refs that is not kept waiting fails with "cannot lock ref", as it does on a busy host.
mkdir -p "$W/t6/.git/hooks"
cat > "$W/t6/.git/hooks/reference-transaction" <<SH
#!/usr/bin/env bash
[ "\$1" = prepared ] || exit 0
grep -q ' refs/remotes/origin/main$' && $REAL_SLEEP 0.15
exit 0
SH
chmod +x "$W/t6/.git/hooks/reference-transaction"
git -C "$W/origin-t6.git" branch b1 main; git -C "$W/origin-t6.git" branch b2 main
git clone -q "$W/origin-t6.git" "$W/pusher" 2>/dev/null
rm -f "$W/pusher.stop"
(
  n=0
  while [ ! -e "$W/pusher.stop" ]; do
    n=$((n + 1)); printf '%s\n' "$n" > "$W/pusher/moves"
    git -C "$W/pusher" commit -q --allow-empty -m "move $n" && git -C "$W/pusher" push -q origin HEAD:refs/heads/main 2>/dev/null
  done
) &
pusher=$!
run_case t6 8
: > "$W/pusher.stop"; wait "$pusher" 2>/dev/null
moves=$(cat "$W/pusher/moves" 2>/dev/null || echo 0)
case $(all_out "$CASE_OUT") in *"could not fetch"*) fail "T6 a spawn could not fetch while others fetched: $(all_out "$CASE_OUT" | grep 'could not fetch' | head -3)" ;; esac
[ "$(count_rc "$CASE_OUT" t6 0)" = 8 ] || fail "T6 all 8 spawns should exit 0: $(all_out "$CASE_OUT")"
[ "$(published t6)" = 8 ] || fail "T6 8 records should be published, found $(published t6)"
[ "$(hook_count free)" = 8 ] && [ "$(hook_count held)" = 0 ] || fail "T6 a spawn still owned the project lock in the hook after the refresh: $(hook_count held) held, $(hook_count free) free"
pass "T6 eight spawns fetch a moving origin without a refusal and overlap after the refresh: ${CASE_WALL} ms, $moves origin moves"

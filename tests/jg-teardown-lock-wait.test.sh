#!/usr/bin/env bash
# Journey: a cleanup waits for the project's slot lock instead of refusing a landed lane, and the sweep that runs the
# cleanup is its own detached job that no 30-second check limit can end (ticket jg-7v6uw-s03).
#   a) a live holder keeps the project lock for 70 seconds (a cleanup stub): bin/jg-teardown.sh, with its default wait,
#      waits and cleans the lane within that one wait, and the lane's record is gone;
#   b) a lock whose holder is dead is taken over at once, with no wait;
#   c) a live holder that outlasts the wait: the teardown refuses after the wait, names it, and changes nothing;
#   d) core/lead-sweep/lead-sweep.sh check returns at once while its job runs a teardown that takes longer than the
#      watcher's check limit; the next beat prints the job's line; two lanes are swept oldest done line first.
# Usage: tests/jg-teardown-lock-wait.test.sh
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
jg_git_identity fmtest fmtest@example.invalid
TEARDOWN=${JG_TEARDOWN_UNDER_TEST:-$ROOT/bin/jg-teardown.sh}
HOLD_SECONDS=${JG_LOCK_WAIT_TEST_HOLD:-70}
TMP_ROOT=$(jg_test_tmproot jg-teardown-lock-wait)
LOG=${DONE_DONE_EVIDENCE_ROOT:+$DONE_DONE_EVIDENCE_ROOT/jg-teardown-lock-wait.log}
say() { printf '%s\n' "$*" | tee -a "${LOG:-/dev/null}"; }
fails=0
check() { if [ "$2" = "$3" ]; then say "ok: $1"; else say "FAIL: $1 (want: $3, got: $2)"; fails=$((fails + 1)); fi; }

# make_case <name>: a project clone, a task worktree moved into a Treehouse-shaped pool slot, work already on main,
# stubs for the commands teardown calls after its checks. Prints the case dir.
make_case() {
  local c=$TMP_ROOT/$1 fb
  fb=$c/fakebin
  mkdir -p "$c/state" "$c/config" "$c/data" "$fb"
  # Teardown closes the task's own backlog row, so the case home holds a real store with the task in flight.
  if [ ! -d "$TMP_ROOT/seeded-store" ]; then
    jg_test_beads_home "$c"
    jg_test_backlog "$c" add task-x1 "[feature] lock wait fixture task" --priority 1 --kind ship --repo demo --body "fixture" >/dev/null
    jg_test_backlog "$c" start task-x1 >/dev/null
    cp -a "$c-store" "$TMP_ROOT/seeded-store"
  else
    jg_test_beads_home "$c"; rm -rf "$c-store"; cp -a "$TMP_ROOT/seeded-store" "$c-store"
  fi
  for t in treehouse tmux gh no-mistakes; do printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/$t"; done
  # shellcheck disable=SC2016 # the stub body is written literally
  printf '#!/usr/bin/env bash\ncase "${1:-} ${2:-}" in "pr list") printf "count: 0\\npull_requests[]: []\\n" ;; esac\nexit 0\n' > "$fb/gh-axi"
  chmod +x "$fb"/*
  git init -q --bare "$c/origin.git"; git -C "$c/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$c/origin.git" "$c/seed" 2>/dev/null
  git -C "$c/seed" commit -q --allow-empty -m base; git -C "$c/seed" push -q origin main; rm -rf "$c/seed"
  git clone -q "$c/origin.git" "$c/project"; git -C "$c/project" remote set-head origin main 2>/dev/null || true
  git -C "$c/project" worktree add -q -b fm/task-x1 "$c/wt" main
  git -C "$c/wt" commit -q --allow-empty -m "lane work"
  git -C "$c/project" update-ref refs/heads/main "$(git -C "$c/wt" rev-parse HEAD)"
  mkdir -p "$c/pool/1"
  git -C "$c/project" worktree move "$c/wt" "$c/pool/1/repo"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$c/pool/1/repo" > "$c/pool/treehouse-state.json"
  jg_write_meta "$c/state/task-x1.meta" "window=juggernaut:jg-task-x1" "endpoint_task_id=task-x1" \
    "worktree=$c/pool/1/repo" "project=$c" "kind=ship" "mode=local-only" "spawn_gen=lock-wait-task-x1"
  sed -i "s#^project=.*#project=$c/project#" "$c/state/task-x1.meta"
  touch "$c/state/.last-watcher-beat"
  printf '%s\n' "$c"
}
# lock_path <case>: the project's slot lock, derived by the same function teardown uses.
lock_path() {
  JG_HOME=$1 JG_STATE_OVERRIDE=$1/state bash -c '. "$1/bin/jg-wake-lib.sh"; jg_treehouse_project_lock_path "$2"' _ "$ROOT" "$1/project"
}
# hold <case> <seconds>: a live process takes the lock, keeps it that long, releases it (the other cleanup's work).
hold() {
  local lock; lock=$(lock_path "$1")
  JG_HOME=$1 JG_STATE_OVERRIDE=$1/state bash -c '. "$1/bin/jg-wake-lib.sh"; jg_lock_try_acquire "$2" || exit 9; sleep "$3"; jg_lock_release "$2"' _ "$ROOT" "$lock" "$2" &
  HOLD_PID=$!
  local i=0; while [ ! -e "$lock/pid" ] && [ ! -L "$lock" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
}
run_teardown() {  # <case> [env...]
  local c=$1; shift
  env JG_HOME="$c" JG_ROOT_OVERRIDE="$ROOT" JG_STATE_OVERRIDE="$c/state" JG_DATA_OVERRIDE="$c/data" JG_CONFIG_OVERRIDE="$c/config" \
    PATH="$c/fakebin:$PATH" "$@" "$TEARDOWN" task-x1
}

# a) the 70-second holder, default wait, started first so it overlaps the other cases.
A=$(make_case hold70); hold "$A" "$HOLD_SECONDS"; A_HOLD=$HOLD_PID
( s=$SECONDS; run_teardown "$A" > "$A/out" 2> "$A/err"; echo $? > "$A/rc"; echo $((SECONDS - s)) > "$A/secs" ) &
A_RUN=$!

# b) a dead holder: the lock names a pid that no longer runs.
B=$(make_case dead); lockB=$(lock_path "$B")
sleep 0 & dead=$!; wait "$dead"
mkdir -p "$lockB"; printf '%s\n' "$dead" > "$lockB/pid"
s=$SECONDS; run_teardown "$B" > "$B/out" 2> "$B/err"; rcB=$?; secsB=$((SECONDS - s))
check "b: a dead holder is taken over and the lane is cleaned" "$rcB|$(test -e "$B/state/task-x1.meta" && echo kept || echo gone)" "0|gone"
check "b: no wait for a dead holder (under 10 s)" "$([ "$secsB" -lt 10 ] && echo yes || echo "no:$secsB")" yes

# c) a live holder that outlasts the wait: refused after the wait, nothing changed.
C=$(make_case outlast); hold "$C" 20
s=$SECONDS; run_teardown "$C" JG_TEARDOWN_LOCK_WAIT=3 > "$C/out" 2> "$C/err"; rcC=$?; secsC=$((SECONDS - s))
check "c: a holder that outlasts the wait refuses" "$rcC|$(grep -c 'REFUSED: another Treehouse slot allocation or return is in progress for .*(waited 3s); nothing was changed' "$C/err")" "1|1"
check "c: it waited for the deadline before it refused" "$([ "$secsC" -ge 3 ] && [ "$secsC" -lt 15 ] && echo yes || echo "no:$secsC")" yes
check "c: nothing was changed: the record and the worktree stay" "$(test -e "$C/state/task-x1.meta" && test -d "$C/pool/1/repo" && echo kept || echo gone)" kept
kill "$HOLD_PID" 2>/dev/null; wait "$HOLD_PID" 2>/dev/null

# d) the sweep is its own job. Stub teardown takes 35 s (over the watcher's 30-second check limit) and records its order.
D=$TMP_ROOT/sweep; mkdir -p "$D/state" "$D/data" "$D/bin" "$D/proj"
cp "$ROOT"/bin/jg-*.sh "$D/bin/" 2>/dev/null
git -C "$D/proj" init -q; git -C "$D/proj" commit -q --allow-empty -m base
git -C "$D/proj" rev-parse HEAD > "$D/state/trunk-tip-proj"
for id in newer older; do
  printf 'kind=ship\nproject=%s\nbranch=fm/%s\n' "$D/proj" "$id" > "$D/state/$id.meta"
  git -C "$D/proj" branch "fm/$id" HEAD
  printf 'done [at=1]: ready\n' > "$D/state/$id.status"
done
touch -d '2 hours ago' "$D/state/older.status"; touch -d '1 hour ago' "$D/state/newer.status"
cat > "$D/teardown" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$(date +%s)" >> "$STUB_LOG"
sleep "${STUB_SLEEP:-35}"
rm -f "$JG_STATE_OVERRIDE/$1.meta"
STUB
chmod +x "$D/teardown"
export STUB_LOG=$D/calls STUB_SLEEP=35 JG_LEAD_SWEEP_TEARDOWN=$D/teardown
s=$SECONDS; timeout 30 "$ROOT/core/lead-sweep/lead-sweep.sh" check "$D" > "$D/beat1" 2>&1; rc=$?; secs=$((SECONDS - s))
check "d: the check returns at once and is not ended by the 30-second limit" "$rc|$([ "$secs" -lt 5 ] && echo yes || echo "no:$secs")" "0|yes"
check "d: the first beat prints nothing yet" "$(cat "$D/beat1")" ""
i=0; while [ "$(find "$D/data/lead-sweep" -maxdepth 1 -name 'results.*' 2>/dev/null | wc -l)" -lt 1 ] && [ "$i" -lt 100 ]; do sleep 1; i=$((i + 1)); done
check "d: the job cleaned both lanes, oldest done line first" "$(awk '{printf "%s ", $1}' "$STUB_LOG")" "older newer "
"$ROOT/core/lead-sweep/lead-sweep.sh" check "$D" > "$D/beat2" 2>&1
check "d: the next beat prints both results" "$(grep -c '^lead-sweep: \(older\|newer\) cleaned up' "$D/beat2")" 2
check "d: no results are left to print twice" "$(find "$D/data/lead-sweep" -maxdepth 1 -name 'results.*' 2>/dev/null | wc -l)" 0
sleep 1

# a) result: the 70-second wait finished inside the one wait.
wait "$A_RUN"; wait "$A_HOLD" 2>/dev/null
check "a: the cleanup waited for the 70-second holder and cleaned the lane" "$(cat "$A/rc")|$(test -e "$A/state/task-x1.meta" && echo kept || echo gone)" "0|gone"
check "a: it waited at least the holder's hold" "$([ "$(cat "$A/secs")" -ge $((HOLD_SECONDS - 5)) ] && echo yes || echo "no:$(cat "$A/secs")")" yes
check "a: no refusal was printed" "$(grep -c REFUSED "$A/err")" 0

[ "$fails" -eq 0 ] || { say "$fails check(s) failed"; exit 1; }
say "all checks passed"

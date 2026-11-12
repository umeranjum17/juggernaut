#!/usr/bin/env bash
# Tests for bin/jg-teardown.sh: the shared project pool lock is held only for the
# slot-owner checks and the slot return, never for the slow cleanup work around it.
#
# Cleanups and spawns of one project take the same lock (jg_treehouse_project_lock_path).
# While a cleanup held it for its whole run, a slow step (the landed-work proof, the
# pipeline-spend lookup, the pane close, the final-outcome delivery) made every other cleanup of
# the project refuse with "slot allocation or return in progress" and delayed spawns.
#
# Driven through the real bin/jg-teardown.sh against a Treehouse-shaped pool slot.
# Stubs record, at the moment each external command runs, whether the lock is held:
#   (a) slow step BEFORE the return (pipeline-spend lookup) -> lock free
#   (b) the treehouse return itself                     -> lock held
#   (c) slow step AFTER the return (pane close)         -> lock free
#   (d) the lock is held for under 5 s while the cleanup around it takes much longer
#       (the stubs sleep JG_LOCK_HOLD_SLOW_SECS, default 6 s; the audit's 60 s stub
#       differs only in length, since the hold does not depend on it)
#   (e) a slot reassigned to another task DURING a slow step before the lock is
#       caught by the owner check repeated inside the lock: the slot is not returned
#       and the other task's claim is untouched
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
jg_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/jg-teardown.sh"
TMP_ROOT=$(jg_test_tmproot jg-teardown-lock-hold)
SLOW_SECS=${JG_LOCK_HOLD_SLOW_SECS:-6}

# One sandbox: a project with an origin, a task copy moved into pool/7/repo, and
# stubs that log the lock state when they run. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin dest
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"
  touch "$case_dir/state/.last-watcher-beat"
  : > "$case_dir/config/pipeline-spend"
  jg_test_beads_home "$case_dir"
  jg_test_backlog "$case_dir" add task-x1 "[feature] lock hold fixture" --priority 1 --kind ship --repo demo \
    --body "Lock hold fixture" >/dev/null
  jg_test_backlog "$case_dir" start task-x1 >/dev/null

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" commit -q --allow-empty -m baseline
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  dest="$case_dir/pool/7/repo"
  mkdir -p "$case_dir/pool/7"
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$dest" main
  printf '{"worktrees":[{"name":"7","path":"%s"}]}\n' "$dest" > "$case_dir/pool/treehouse-state.json"

  jg_write_meta "$case_dir/state/task-x1.meta" \
    "window=juggernaut:jg-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$dest" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "spawn_gen=lock-hold-task-x1"

  # Every stub logs "<name> held|free" from the lock directory's presence.
  cat > "$fakebin/probe" <<'SH'
#!/usr/bin/env bash
# probe <name>: append the pool lock state to the case log.
state=free
for l in "$JG_HOME"/state/.treehouse-project-*.lock; do
  [ -d "$l" ] && state=held
done
printf '%s %s\n' "$1" "$state" >> "$JG_LOCK_LOG"
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
"$(dirname "$0")/probe" "treehouse-$1"
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = kill-window ]; then
  "$(dirname "$0")/probe" tmux-kill-window
  sleep "$JG_LOCK_HOLD_SLOW_SECS"
fi
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
# The pipeline-spend lookup (jg-pipeline-spend.sh record, run when config/pipeline-spend
# exists) before the return: it may reassign the slot, and is slow.
# (The caller bounds it, so the claim is written before the sleep.)
if [ "${1:-}" = axi ]; then
  "$(dirname "$0")/probe" pipeline-spend-lookup
  if [ -n "${JG_LOCK_HOLD_REASSIGN_TO:-}" ]; then
    printf 'task=%s\nhome=%s\n' "$JG_LOCK_HOLD_REASSIGN_TO" /elsewhere > "$JG_LOCK_HOLD_SLOT_MARKER"
  fi
  sleep "$JG_LOCK_HOLD_SLOW_SECS"
fi
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cp "$fakebin/gh-axi" "$fakebin/gh"
  chmod +x "$fakebin"/*
  printf '%s\n' "$case_dir"
}

# run_teardown <case-dir> [VAR=value ...]: the real script; prints its exit code.
run_teardown() {
  local case_dir=$1 rc=0
  shift
  env JG_HOME="$case_dir" JG_ROOT_OVERRIDE="$ROOT" \
    JG_STATE_OVERRIDE="$case_dir/state" JG_DATA_OVERRIDE="$case_dir/data" \
    JG_CONFIG_OVERRIDE="$case_dir/config" \
    JG_LOCK_LOG="$case_dir/lock.log" JG_LOCK_HOLD_SLOW_SECS="$SLOW_SECS" \
    JG_LOCK_HOLD_SLOT_MARKER="$case_dir/pool/7/.jg-slot-owner" \
    PATH="$case_dir/fakebin:$PATH" "$@" \
    "$TEARDOWN" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  printf '%s\n' "$rc"
}

# Sample the lock's presence until the teardown ends; write "<first> <last>" epoch
# milliseconds of the sightings to <case-dir>/hold.span.
watch_lock() {
  local case_dir=$1 first='' last='' now l seen
  while [ ! -e "$case_dir/watch.stop" ]; do
    seen=0
    for l in "$case_dir"/state/.treehouse-project-*.lock; do
      [ -d "$l" ] && seen=1
    done
    if [ "$seen" = 1 ]; then
      now=$(date +%s%3N)
      [ -n "$first" ] || first=$now
      last=$now
    fi
    sleep 0.05
  done
  printf '%s %s\n' "${first:-0}" "${last:-0}" > "$case_dir/hold.span"
}

test_lock_is_held_only_for_the_slot_return() {
  local case_dir rc wpid start end first last hold total
  case_dir=$(make_case hold)
  : > "$case_dir/lock.log"
  watch_lock "$case_dir" &
  wpid=$!
  start=$(date +%s%3N)
  rc=$(run_teardown "$case_dir")
  end=$(date +%s%3N)
  : > "$case_dir/watch.stop"
  wait "$wpid"

  [ "$rc" = 0 ] || fail "hold: teardown exited $rc: $(cat "$case_dir/stderr")"
  [ -z "${JG_LOCK_HOLD_DEBUG:-}" ] || { echo "--- lock.log"; cat "$case_dir/lock.log"; echo "--- stderr"; cat "$case_dir/stderr"; } >&2
  assert_grep 'pipeline-spend-lookup free' "$case_dir/lock.log" \
    "hold: the slow pipeline-spend lookup ran while the pool lock was held"
  assert_grep 'treehouse-return held' "$case_dir/lock.log" \
    "hold: the slot return ran without the pool lock"
  assert_grep 'tmux-kill-window free' "$case_dir/lock.log" \
    "hold: the slow pane close ran while the pool lock was held"
  read -r first last < "$case_dir/hold.span"
  [ "$first" != 0 ] || fail "hold: the pool lock was never seen held; the sampler or the lock path is wrong"
  hold=$((last - first))
  total=$((end - start))
  [ "$total" -ge $((SLOW_SECS * 1000)) ] \
    || fail "hold: the slow stubs did not run (total ${total} ms)"
  [ "$hold" -lt 5000 ] \
    || fail "hold: the pool lock was held ${hold} ms of a ${total} ms cleanup (limit 5000 ms)"
  assert_absent "$case_dir/state/task-x1.meta" "hold: the task record was not removed"
  pass "the pool lock is held ${hold} ms of a ${total} ms cleanup, only around the slot return"
}

test_owner_check_is_repeated_inside_the_lock() {
  local case_dir rc
  case_dir=$(make_case reassigned)
  : > "$case_dir/lock.log"
  rc=$(run_teardown "$case_dir" JG_LOCK_HOLD_REASSIGN_TO=task-other)
  [ "$rc" = 0 ] || fail "reassigned: teardown exited $rc: $(cat "$case_dir/stderr")"
  [ -z "${JG_LOCK_HOLD_DEBUG:-}" ] || { echo "--- lock.log"; cat "$case_dir/lock.log"; echo "--- stderr"; grep -v '●' "$case_dir/stderr"; } >&2
  assert_no_grep 'treehouse-return' "$case_dir/lock.log" \
    "reassigned: a slot claimed by another task during the slow step was returned"
  assert_grep 'was reassigned to task task-other' "$case_dir/stderr" \
    "reassigned: no reassignment warning from the owner check inside the lock"
  [ "$(sed -n 's/^task=//p' "$case_dir/pool/7/.jg-slot-owner")" = task-other ] \
    || fail "reassigned: the other task's slot claim was changed"
  assert_absent "$case_dir/state/task-x1.meta" "reassigned: the task record was not removed"
  pass "a slot reassigned during a slow step is caught by the owner check inside the lock and not returned"
}

test_lock_is_held_only_for_the_slot_return
test_owner_check_is_repeated_inside_the_lock

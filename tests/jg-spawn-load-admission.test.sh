#!/usr/bin/env bash
# Host load admission at spawn: lanes stop piling onto a loaded machine by themselves.
# Real bin/jg-brief.sh and bin/jg-spawn.sh over a fixture project; only the terminal and the worktree tool are
# stand-ins, and the host load is a file shaped like /proc/loadavg (JG_REAPER_LOADAVG under the suite's test seam).
# The load history is the record the main home's load alarm keeps (bin/jg-reaper-lib.sh owns it and the limit):
# a fixture writes it as the alarm would, the epoch of the first sample above the limit.
#
# T1 a load history above the limit for 10 minutes: a new lane is deferred with exit 75 and a deferred: line that
#    names the load, leaves no task record, keeps its backlog item queued, and the running lane is untouched.
# T2 the load back under the limit: the spawn proceeds, even before the alarm's next sample clears the history.
# T3 config/reaper-load-minutes sets the window and config/reaper-load-factor the limit; config/reaper-off defers nothing.
# T4 a lead home reads the main home's history, because the main home alone samples the machine.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-spawn-load-admission)
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
fixture_home() {  # <home>
  jg_test_spawn_home "$1"
  printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$1/config/host-memory"
}
fixture_home "$HOME_DIR"

# The default limit is 2 times the cores (64 on 32 cores): one over it is loaded, the limit itself is not.
CORES=$(nproc 2>/dev/null || echo 1)
printf '%s.0 1.0 1.0 9/999 42\n' "$((CORES * 2 + 1))" > "$W/load-high"
printf '%s.0 1.0 1.0 9/999 42\n' "$((CORES * 2))" > "$W/load-at-limit"
export JG_REAPER_LOADAVG="$W/load-high"
history_since() {  # <home> <seconds ago>: the alarm's episode record, first sample above the limit that long ago
  printf '%s\n' "$(($(date +%s) - $2))" > "$1/state/.browser-reaper-load"
}

N=0
# ship <home>: scaffold a real brief on its own isolated copy and spawn it; sets id, out, rc.
ship() {
  local home=$1 wt
  N=$((N + 1)); id=jg-la$N; wt="$W/wt-$id"
  jg_test_add "$home" "$id" "[feature] load admission $N"
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" "$id" proj --mode direct-PR --project "$PROJ" --migration-row none >/dev/null 2>&1 \
    || fail "could not scaffold the brief for $id"
  sed -i 's/{TASK}/Exercise the load admission./;s/{JUGGERNAUT_SPEC}/Exercise the load admission end to end./' "$home/data/$id/brief.md"
  git -C "$PROJ" worktree add -q --detach "$wt" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy"
  out=$(jg_test_run_spawn "$home" "$wt" "$FAKEBIN" "$id" "$PROJ" codex --mode direct-PR --yolo off); rc=$?
}
queued() {  # <home> <id>: the backlog item is still queued, never in flight or blocked
  local row
  row=$(jg_test_backlog "$1" show "$2" 2>&1)
  assert_contains "$row" "state: queued" "the backlog item $2 left the queue"
  assert_contains "$row" "blocked: no" "the backlog item $2 was marked blocked"
  assert_contains "$row" "held: no" "the backlog item $2 was held"
}

# A lane already running before the load rose.
ship "$HOME_DIR"
expect_code 0 "$rc" "setup: the first lane should launch on a quiet machine: $out"
RUNNING=$id
cp "$HOME_DIR/state/$RUNNING.meta" "$W/running.meta"

# T1
history_since "$HOME_DIR" 700
ship "$HOME_DIR"
expect_code 75 "$rc" "T1 a new lane on a machine loaded for 10 minutes should be deferred: $out"
assert_contains "$out" "deferred: machine load $((CORES * 2 + 1)).0 above $((CORES * 2)) over $CORES cores for 11 min" \
  "T1 the deferral does not name the load, the limit and how long"
assert_contains "$out" "stays queued" "T1 the deferral does not say the task stays queued"
case $out in *"error:"*) fail "T1 a load deferral must not read as an error: $out" ;; esac
[ ! -e "$HOME_DIR/state/$id.meta" ] || fail "T1 the deferred lane wrote a task record"
[ ! -e "$HOME_DIR/state/$id.status" ] || fail "T1 the deferred lane wrote a status file"
queued "$HOME_DIR" "$id"
cmp -s "$W/running.meta" "$HOME_DIR/state/$RUNNING.meta" || fail "T1 the running lane's record changed"
DEFERRED=$id
pass "T1 a machine loaded for 10 minutes defers a new lane with exit 75, leaves it queued and the running lane untouched"

# T2
JG_REAPER_LOADAVG="$W/load-at-limit"
export JG_REAPER_LOADAVG
id=$DEFERRED
out=$(jg_test_run_spawn "$HOME_DIR" "$W/wt-$id" "$FAKEBIN" "$id" "$PROJ" codex --mode direct-PR --yolo off); rc=$?
expect_code 0 "$rc" "T2 the deferred lane should launch once the load is back under the limit: $out"
[ -e "$HOME_DIR/state/$id.meta" ] || fail "T2 the launched lane has no task record"
pass "T2 the load back under the limit lets the deferred lane launch"

# T3
JG_REAPER_LOADAVG="$W/load-high"
export JG_REAPER_LOADAVG
history_since "$HOME_DIR" 700
printf '20\n' > "$HOME_DIR/config/reaper-load-minutes"
ship "$HOME_DIR"
expect_code 0 "$rc" "T3 a 20 minute window should admit after 11 minutes: $out"
printf '3\n' > "$HOME_DIR/config/reaper-load-factor"
history_since "$HOME_DIR" 1500
ship "$HOME_DIR"
expect_code 0 "$rc" "T3 a factor of 3 should put the limit above the load: $out"
rm -f "$HOME_DIR/config/reaper-load-factor"
ship "$HOME_DIR"
expect_code 75 "$rc" "T3 25 minutes above the default limit with a 20 minute window should defer: $out"
assert_contains "$out" "for 25 min" "T3 the deferral does not name the configured episode length"
: > "$HOME_DIR/config/reaper-off"
ship "$HOME_DIR"
expect_code 0 "$rc" "T3 a record left behind once the sampler is off should defer nothing: $out"
rm -f "$HOME_DIR/config/reaper-load-minutes" "$HOME_DIR/config/reaper-off"
pass "T3 the window and the limit come from config/reaper-load-minutes and reaper-load-factor; reaper-off defers nothing"

# T4
LEAD="$W/lead"
fixture_home "$LEAD"
printf 'lead1\n' > "$LEAD/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$HOME_DIR" > "$LEAD/.jg-squad-lead-parent"
history_since "$HOME_DIR" 700
ship "$LEAD"
expect_code 75 "$rc" "T4 a lead's new lane should be deferred by the main home's load history: $out"
[ ! -e "$LEAD/state/$id.meta" ] || fail "T4 the lead's deferred lane wrote a task record"
rm -f "$HOME_DIR/state/.browser-reaper-load"
ship "$LEAD"
expect_code 0 "$rc" "T4 a lead's lane should launch when the main home has no load history: $out"
pass "T4 a lead home is deferred by the main home's load history"

echo "all jg-spawn-load-admission tests passed"

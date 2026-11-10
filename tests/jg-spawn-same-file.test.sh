#!/usr/bin/env bash
# Two lanes on one shared file do not start at once.
# Real bin/jg-brief.sh and bin/jg-spawn.sh over a fixture project; only the terminal and the worktree tool are
# stand-ins. A lane's file list is the repo paths its brief's `# Task` section names (bin/jg-brief.sh --task-files).
#
# T1 a second lane whose brief names a file the running lane's brief names is deferred with exit 75 and a
#    deferred: line that names the file and the running lane; no task record, backlog item stays queued.
# T2 a lane naming other files starts beside the running lane.
# T3 once the first lane's record is gone (it landed and was cleaned up), the deferred lane starts.
# T4 a scout never holds files and is never held back.
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
  sed -i "s|{TASK}|$text|;s|{JUGGERNAUT_SPEC}|Exercise the same-file queue.|" "$HOME_DIR/data/$id/brief.md"
  git -C "$PROJ" worktree add -q --detach "$wt" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy"
  if [ "$kind" = scout ]; then
    out=$(jg_test_run_spawn "$HOME_DIR" "$wt" "$FAKEBIN" "$id" "$PROJ" codex --scout); rc=$?
  else
    out=$(jg_test_run_spawn "$HOME_DIR" "$wt" "$FAKEBIN" "$id" "$PROJ" codex --mode direct-PR --yolo off); rc=$?
  fi
}

lane 'Change bin/jg-trunk.sh so the verb works.'
expect_code 0 "$rc" "setup: the first lane should launch: $out"
FIRST=$id

# T1
lane 'Also fix bin/jg-trunk.sh:120-140 in the same verb.'
expect_code 75 "$rc" "T1 a second lane on the same file should be deferred: $out"
assert_contains "$out" "deferred: bin/jg-trunk.sh is named by running lane $FIRST" "T1 the deferral does not name the file and the running lane"
assert_contains "$out" "stays queued" "T1 the deferral does not say the task stays queued"
case $out in *"error:"*) fail "T1 a same-file deferral must not read as an error: $out" ;; esac
[ ! -e "$HOME_DIR/state/$id.meta" ] || fail "T1 the deferred lane wrote a task record"
row=$(jg_test_backlog "$HOME_DIR" show "$id" 2>&1)
assert_contains "$row" "state: queued" "T1 the backlog item left the queue"
echo "ok - T1 second lane $id deferred (exit $rc, no record, backlog item queued): ${out##*deferred: }"
DEFERRED=$id

# T2
lane 'Change bin/jg-other.sh only.'
expect_code 0 "$rc" "T2 a lane on another file should start beside the running one: $out"
echo "ok - T2 lane $id on another file started beside $FIRST (exit $rc)"

# T4
lane 'Survey bin/jg-trunk.sh and report.' scout
expect_code 0 "$rc" "T4 a scout naming a held file should not be deferred: $out"
echo "ok - T4 scout $id naming bin/jg-trunk.sh started (exit $rc)"

# T3: the first lane landed and its record was cleaned up.
rm -f "$HOME_DIR/state/$FIRST.meta"
wt="$W/wt-$DEFERRED"  # the isolated copy the deferred attempt prepared is still there
out=$(jg_test_run_spawn "$HOME_DIR" "$wt" "$FAKEBIN" "$DEFERRED" "$PROJ" codex --mode direct-PR --yolo off); rc=$?
expect_code 0 "$rc" "T3 the deferred lane should start once the first lane's record is gone: $out"
[ -e "$HOME_DIR/state/$DEFERRED.meta" ] || fail "T3 the started lane wrote no task record"
echo "ok - T3 deferred lane $DEFERRED started (exit $rc, task record written) after $FIRST's record was removed"
echo "all jg-spawn-same-file tests passed"

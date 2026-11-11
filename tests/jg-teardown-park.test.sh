#!/usr/bin/env bash
# Tests for `bin/jg-teardown.sh <id> --park` (bin/jg-teardown-park-lib.sh): a parked lane keeps its branch and one small
# record and gives back its copy and its pane. Every case runs the real script against a real project clone and a real
# worktree; only treehouse and tmux are stubs, as in tests/jg-teardown.test.sh, and the stubs log each call.
#
# The rule under test: a copy is returned only when it is clean and its HEAD is the tip of the lane's branch.
#   (a) clean copy, head on the branch, live worker       -> PARKED: copy returned, pane closed, branch kept, record written
#   (b) same, worker already gone (pane missing)          -> PARKED the same way
#   (c) uncommitted tracked change                        -> REFUSED, nothing changed
#   (d) untracked file that is not the fleet's own        -> REFUSED, nothing changed
#   (e) the fleet's own untracked hook file only          -> PARKED
#   (f) HEAD detached at a commit that is not the tip     -> REFUSED, nothing changed
#   (g) HEAD detached at the tip                          -> PARKED (the branch holds the commit)
#   (h) the recorded branch does not exist                -> REFUSED, nothing changed
#   (i) --park with --force                               -> invalid request, nothing changed
#   (j) a Recon (scout)                                   -> REFUSED, nothing changed
#   (k) an unlanded commit that no remote holds           -> PARKED (park keeps the branch; no landed-work test)
#   (l) a park that stopped after the copy was returned   -> the rerun finishes it
#   (m) an Orca lane                                      -> REFUSED, nothing changed
# Every parked case also checks that the status log, the steering inbox and data/<id>/ are kept.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
jg_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/jg-teardown.sh"
TMP_ROOT=$(jg_test_tmproot jg-teardown-park)
ID=task-p1
RC=0

# make_case <name>: a project clone with a lane branch checked out in a worktree, a lane record, and the stubs.
make_case() {
  local c="$TMP_ROOT/$1" fb
  fb="$c/fakebin"
  mkdir -p "$c/state" "$c/config" "$c/data/$ID" "$fb"
  jg_test_beads_home "$c"
  jg_test_backlog "$c" add "$ID" "[feature] park fixture task" --priority 1 --kind ship --repo demo --body "Park fixture" > /dev/null
  jg_test_backlog "$c" start "$ID" > /dev/null
  git init -q --bare "$c/origin.git"
  git -C "$c/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$c/origin.git" "$c/_seed" 2>/dev/null
  git -C "$c/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "origin baseline"
  git -C "$c/_seed" push -q origin main
  rm -rf "$c/_seed"
  git clone -q "$c/origin.git" "$c/project"
  git -C "$c/project" remote set-head origin main 2>/dev/null || true
  git -C "$c/project" worktree add -q -b "fm/$ID" "$c/wt" main
  git -C "$c/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "lane work"
  printf '#!/usr/bin/env bash\nprintf "treehouse %%s\\n" "$*" >> "%s/calls.log"\nexit 0\n' "$c" > "$fb/treehouse"
  printf '#!/usr/bin/env bash\nprintf "tmux %%s\\n" "$*" >> "%s/calls.log"\nexit 0\n' "$c" > "$fb/tmux"
  chmod +x "$fb/treehouse" "$fb/tmux"
  touch "$c/state/.last-watcher-beat"
  write_meta "$c" ship
  printf 'working [at=1]: on it\npaused [at=2]: parked until 2026-12-31\n' > "$c/state/$ID.status"
  mkdir -p "$c/state/$ID.inbox"
  printf 'a steer\n' > "$c/state/$ID.inbox/001.msg"
  printf 'the brief\n' > "$c/data/$ID/brief.md"
  : > "$c/calls.log"
  printf '%s\n' "$c"
}

write_meta() {  # <case> <kind> [branch]
  local c=$1 kind=$2 branch=${3:-fm/$ID}
  jg_write_meta "$c/state/$ID.meta" \
    "window=juggernaut:jg-$ID" "endpoint_task_id=$ID" "worktree=$c/wt" "project=$c/project" \
    "kind=$kind" "mode=local-trunk" "branch=$branch" "spawn_gen=park-test-$ID"
}

run_park() {  # <case> [args...]: sets RC
  local c=$1
  shift
  RC=0
  JG_ROOT_OVERRIDE="$ROOT" JG_STATE_OVERRIDE="$c/state" JG_DATA_OVERRIDE="$c/data" JG_CONFIG_OVERRIDE="$c/config" \
    PATH="$c/fakebin:$PATH" "$TEARDOWN" "$ID" --park "$@" > "$c/stdout" 2> "$c/stderr" || RC=$?
}

# state_hash <case>: every file of the lane's records (task record, status log, inbox), the branch tip and the copy, so "nothing changed" is a comparison.
state_hash() {
  local c=$1
  {
    # The lane's own records only: the Beads store beside them is a database that may write on any read.
    (cd "$c/state" && find . -type f -name "$ID.*" -exec cksum {} + | sort; [ ! -d "$ID.inbox" ] || find "$ID.inbox" -type f -exec cksum {} + | sort)
    git -C "$c/project" rev-parse "refs/heads/fm/$ID" 2>/dev/null
    [ ! -d "$c/wt" ] || git -C "$c/wt" status --porcelain --untracked-files=all
  } | cksum
}

assert_parked() {  # <case> <name>
  local c=$1 n=$2 head
  head=$(git -C "$c/project" rev-parse "refs/heads/fm/$ID")
  [ -f "$c/state/$ID.parked" ] || fail "$n: no park record"
  assert_grep "branch=fm/$ID" "$c/state/$ID.parked" "$n: the record names the branch"
  assert_grep "head=$head" "$c/state/$ID.parked" "$n: the record names the branch tip"
  assert_grep "project=$c/project" "$c/state/$ID.parked" "$n: the record names the project"
  [ ! -e "$c/state/$ID.meta" ] || fail "$n: the lane's task record still stands, so it still names a copy and a pane"
  grep -q '^treehouse return' "$c/calls.log" || fail "$n: the copy was not returned"
  git -C "$c/project" rev-parse --verify -q "refs/heads/fm/$ID" > /dev/null || fail "$n: the branch was deleted"
  [ -f "$c/state/$ID.status" ] || fail "$n: the status log is gone"
  [ -f "$c/state/$ID.inbox/001.msg" ] || fail "$n: the steering inbox is gone"
  [ -f "$c/data/$ID/brief.md" ] || fail "$n: data/<id>/ is gone"
}

assert_refused() {  # <case> <name> <before-hash> <expected sentence>
  local c=$1 n=$2 before=$3 want=$4
  expect_code 1 "$RC" "$n: refused: $(cat "$c/stderr")"
  assert_grep "REFUSED" "$c/stderr" "$n: says REFUSED"
  assert_grep "$want" "$c/stderr" "$n: names the cause"
  assert_equals "$before" "$(state_hash "$c")" "$n: nothing changed"
  ! grep -q '^treehouse return' "$c/calls.log" || fail "$n: the copy was returned"
  [ ! -e "$c/state/$ID.parked" ] || fail "$n: a park record was written"
}

c=$(make_case live-clean)
run_park "$c"
expect_code 0 "$RC" "a: park succeeds: $(cat "$c/stderr")"
assert_parked "$c" "a (live worker)"
pass "a: a clean copy at its branch tip gives back its copy and keeps the branch and the record"

c=$(make_case no-worker)
# A worker that is gone: closing its window fails with "can't find window", and no window is listed.
# shellcheck disable=SC2016  # the stub script text must keep its $ literal
printf '#!/usr/bin/env bash\nprintf "tmux %%s\\n" "$*" >> "%s/calls.log"\ncase "$1" in kill-window) echo "can'"'"'t find window" >&2; exit 1 ;; esac\nexit 0\n' "$c" > "$c/fakebin/tmux"
run_park "$c"
expect_code 0 "$RC" "b: park without a live worker: $(cat "$c/stderr")"
assert_parked "$c" "b (no worker)"
pass "b: the same lane parks when its worker is already gone"

c=$(make_case dirty-tracked)
echo changed > "$c/wt/file.txt"
git -C "$c/wt" add file.txt
echo more >> "$c/wt/file.txt"
before=$(state_hash "$c")
run_park "$c"
assert_refused "$c" "c" "$before" "uncommitted"
pass "c: a copy with uncommitted changes is refused with nothing changed"

c=$(make_case dirty-untracked)
echo scratch > "$c/wt/notes.txt"
before=$(state_hash "$c")
run_park "$c"
assert_refused "$c" "d" "$before" "notes.txt"
pass "d: an untracked file that is not the fleet's own is refused, and named"

c=$(make_case hook-file-only)
echo t > "$c/wt/.jg-grok-turnend"
run_park "$c"
expect_code 0 "$RC" "e: the fleet's own hook file does not block a park: $(cat "$c/stderr")"
assert_parked "$c" "e"
pass "e: the fleet's own untracked hook file does not block a park"

c=$(make_case head-off-tip)
git -C "$c/wt" checkout -q --detach HEAD~1
before=$(state_hash "$c")
run_park "$c"
assert_refused "$c" "f" "$before" "not at the tip"
pass "f: a head that is not the branch tip is refused with nothing changed"

c=$(make_case head-detached-at-tip)
git -C "$c/wt" checkout -q --detach HEAD
run_park "$c"
expect_code 0 "$RC" "g: a detached head at the tip parks: $(cat "$c/stderr")"
assert_parked "$c" "g"
pass "g: a head detached at the branch tip parks, because the branch holds the commit"

c=$(make_case no-branch)
write_meta "$c" ship fm/no-such-branch
before=$(state_hash "$c")
run_park "$c"
assert_refused "$c" "h" "$before" "does not exist"
pass "h: a recorded branch that does not exist is refused"

c=$(make_case force)
before=$(state_hash "$c")
run_park "$c" --force
expect_code 2 "$RC" "i: --park --force is an invalid request"
assert_equals "$before" "$(state_hash "$c")" "i: nothing changed"
pass "i: --park cannot be combined with --force"

c=$(make_case scout)
write_meta "$c" scout
before=$(state_hash "$c")
run_park "$c"
assert_refused "$c" "j" "$before" "only a ship lane"
pass "j: a Recon is not parked"

c=$(make_case unlanded)
[ -z "$(git -C "$c/project" log --oneline "fm/$ID" --not --remotes)" ] && fail "k: setup: the lane commit is on a remote"
run_park "$c"
expect_code 0 "$RC" "k: an unlanded lane parks: $(cat "$c/stderr")"
assert_parked "$c" "k"
pass "k: a lane whose commit no remote holds parks, because park keeps the branch"

c=$(make_case resume)
git -C "$c/project" worktree remove --force "$c/wt"
run_park "$c"
expect_code 0 "$RC" "l: a park whose copy is already back finishes: $(cat "$c/stderr")"
{ [ -f "$c/state/$ID.parked" ] && [ ! -e "$c/state/$ID.meta" ]; } || fail "l: the rerun did not finish the park"
pass "l: a park that stopped after the copy was returned is finished by the same command"

c=$(make_case orca)
printf 'backend=orca\norca_worktree_id=w1\n' >> "$c/state/$ID.meta"
before=$(state_hash "$c")
run_park "$c"
expect_code 1 "$RC" "m: an Orca lane is refused: $(cat "$c/stderr")"
assert_equals "$before" "$(state_hash "$c")" "m: nothing changed"
pass "m: an Orca lane, whose worktree is removed and not returned, is refused with nothing changed"

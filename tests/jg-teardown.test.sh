#!/usr/bin/env bash
# Tests for bin/jg-teardown.sh's landed-work safety and stale-lock recovery.
# The already-cleaned-task case is also driven end to end, before and after, by journeys/teardown-missing-record.sh.
#
# The check refuses to tear down a worktree whose work has not LANDED, because
# treehouse return hard-resets the worktree. For a PR-delivered ship task "landed"
# means the forge proves it: GitHub reports its PR merged at a head that contains
# the current local work, or its content is already in the up-to-date default
# branch; a pushed branch is never enough. A local-only task has landed when its
# work is reachable from a remote or merged into local main.
#
# Covers three fixes:
#   - local-only fork-remote: a fork IS a remote, so fork-pushed upstream-
#     contribution PRs are teardown-eligible (the pre-fix code false-refused them).
#   - squash-merge-then-delete-branch: the branch's own commits live nowhere on a
#     remote after a squash merge deletes the head branch, yet the change is fully in
#     main. Reachability alone false-refused this common GitHub flow; the check now
#     recognizes a merged PR head containing the local work (or the content already
#     in main) as landed.
#   - teardown-lock-race: a killed crew process can leave a transient worktree
#     git index.lock that blocks teardown. The return path retries on the lock
#     error signature (even if the lock self-clears mid-check), then only removes a
#     provably stale lock before re-running safety checks.
#
# Matrix:
#   (a) local-only + HEAD on a fork remote-tracking branch     -> ALLOW  (fork fix)
#   (b) local-only + truly unpushed work (no remote, not main) -> REFUSE (safety)
#   (c) local-only + merged into local main, no remote         -> ALLOW  (no regression)
#   (d) no-mistakes + HEAD pushed to origin: open green PR     -> REFUSE (pushed is not merged)
#       same, forge reports the PR merged at that head        -> ALLOW
#       same, GitHub unreadable, content already on main      -> REFUSE
#   (e) no-mistakes + unpushed, no PR, content not in default  -> REFUSE (safety)
#   (f) local-only + truly unpushed + --force                  -> ALLOW  (escape hatch)
#   (g) no-mistakes + squash-merged PR, exact PR head          -> ALLOW  (squash fix)
#   (h) no-mistakes + no PR but content already in default     -> ALLOW  (content fallback)
#   (i) no-mistakes + dirty worktree, even when work landed     -> REFUSE (dirty wins)
#   (j) no-mistakes + gh lookup errors + content not in default -> REFUSE (fail-safe)
#   (k) no-mistakes + merged PR but HEAD moved afterward        -> REFUSE (stale PR)
#   (l) no-mistakes + stale origin/main but fetched content     -> ALLOW  (fresh fetch)
#   (m) no-mistakes + local HEAD ancestor of merged PR head     -> ALLOW  (lagging local)
#   (n) no-mistakes + replayed unpushed patch in merged PR head -> ALLOW  (replayed local)
#   (o) jg-pr-check rerun after HEAD moved                      -> no stale pr_head
#   (p) jg-pr-check when local HEAD lags                        -> record remote PR head
#   (q) no-mistakes + NO pr= recorded, PR discovered by branch  -> ALLOW  (yolo/no-CI merge)
#   (q2) no-mistakes + squash-merged, local followed pipeline rebase -> ALLOW
#   (q3) no-mistakes + squash-merged, same file, different content   -> REFUSE
#   (q4) no-mistakes + squash-merged rebased local plus extra commit -> REFUSE
#   (q5) gh down + squash-merged stale local, content not in default -> REFUSE
#
# Also covers backlog teardown-lock-race: a git index.lock left in the worktree by a
# killed crew process (bin/jg-teardown.sh's teardown_treehouse_return).
#   (r) provably-stale index.lock (old mtime, no live holder) -> lock removed, ALLOW
#   (s) index.lock with a live holder, any age                -> lock kept, REFUSE
#   (t) lsof error while checking index.lock                  -> lock kept, REFUSE
#   (u) dirty worktree after stale lock cleanup               -> lock removed, REFUSE
#   (v) non-linked repo index.lock                            -> lock removed, ALLOW
#   (w) index.lock mtime read failure                         -> lock kept, REFUSE
#   (x) transient lock cleared after first failed return      -> retry ALLOW
#   (y) persistent lock (never clears, not provably stale)    -> REFUSE loudly
#   (z) stale record + slot reused by a live successor record -> REFUSE, nothing
#       changed, treehouse is never asked to return the slot.
#
# Nested repositories survive Treehouse's own `git clean -fd`:
#   (z1) scout + nested clone + scratch file                 -> no untracked entries
#   (z2) ship + nested clone, no --force                     -> REFUSE, bytes unchanged
#   (z3) return leaves residue                               -> lost-slot warning, cleanup, exit 4
#   (z3b) residue, then a later step refuses                 -> lost-slot warning still printed
#   (z3c) forced squad_lead + child scout nested clone       -> child copy returns clean
#   (z3d) forced squad_lead + child return leaves residue    -> warning, retirement completes, exit 4
#   (z3e) return removes the copy                            -> cannot-verify warning, exit 4
#   (z4) scout + ignored file                                -> ignored file survives
# Run with --local-trunk to exercise only the local-trunk cleanup journey and legacy local-only rules.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
jg_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/jg-teardown.sh"
PR_CHECK="$ROOT/bin/jg-pr-check.sh"
TMP_ROOT=$(jg_test_tmproot jg-teardown-tests)
REAL_GIT_FOR_TEST=$(command -v git)
export REAL_GIT_FOR_TEST
REAL_PS_FOR_TEST=$(command -v ps)
export REAL_PS_FOR_TEST
REAL_LSOF_FOR_TEST=$(command -v lsof)
export REAL_LSOF_FOR_TEST

# Build a fresh sandbox for one test case. Sets up:
#   $CASE/state/        - juggernaut state dir (with a fresh watcher beacon)
#   $CASE/fakebin/      - mocks for treehouse, tmux (PATH-prepended by caller)
#   $CASE/origin.git/   - bare upstream repo (so the project clone has origin)
#   $CASE/project/      - clone of origin; acts as the juggernaut project dir
#   $CASE/wt/           - a worktree of the project (the task worktree)
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"
  jg_test_beads_home "$case_dir"
  # Every case starts with task-x1 In flight, as a spawned task is: the store
  # is seeded once and copied, since each bd call costs a second.
  if [ ! -d "$TMP_ROOT/seeded-store" ]; then
    seed_backlog_in_flight "$case_dir"
    cp -a "$case_dir-store" "$TMP_ROOT/seeded-store"
  else
    rm -rf "$case_dir-store"
    cp -a "$TMP_ROOT/seeded-store" "$case_dir-store"
  fi

  # Mocks for the post-check teardown steps. Refuse logic exits before these
  # run; the ALLOW cases need them so the script can complete cleanly.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# `treehouse return --force <wt>`: succeed silently.
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
# tmux kill-window etc.: succeed silently.
exit 0
SH
  # Default gh-axi mock: no PR is associated with the branch, and viewing any PR
  # number fails. This keeps the landed-work check hermetic (never reaching the real
  # gh-axi) and represents the common "no GitHub PR" baseline. Tests that need a
  # merged PR or a lookup error override this file with the helpers below.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  # Default hermetic no-mistakes stub: the bare `axi` overview answers
  # JG_FAKE_AXI_OVERVIEW verbatim (empty by default, so no repository resolves
  # and the pipeline-spend record is written as unavailable). Without it,
  # `command -v no-mistakes` would fall through to whatever real binary is on
  # the test runner's own PATH.
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = axi ] && [ -z "${2:-}" ] && printf '%s\n' "${JG_FAKE_AXI_OVERVIEW:-}"
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes"

  # Bare origin so the clone has an `origin` remote and origin/HEAD.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  # Seed origin with one commit BEFORE cloning so the clone is not empty.
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  # Clone as the project; give it a `main` branch and an origin/HEAD.
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  # Add a worktree on a fresh task branch; that branch is where the operator commits.
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  # Fresh watcher beacon so jg-guard stays quiet.
  touch "$case_dir/state/.last-watcher-beat"

  printf '%s\n' "$case_dir"
}

# Write a meta file for the task. Args: case_dir mode kind [worktree]
write_meta() {
  local case_dir=$1 mode=$2 kind=$3
  local wt=${4:-$case_dir/wt}
  jg_write_meta "$case_dir/state/task-x1.meta" \
    "window=juggernaut:jg-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "spawn_gen=teardown-test-task-x1"
}

# Commit something on the worktree's task branch. Args: case_dir [message]
wt_commit() {
  local case_dir=$1 msg=${2:-wt work}
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "$msg"
}

# Add a fork bare repo and register it as a remote on the project, then push
# the worktree's task branch to it and fetch into the project so the worktree
# sees the remote-tracking ref. Args: case_dir
add_fork_with_pushed_branch() {
  local case_dir=$1
  git init -q --bare "$case_dir/fork.git"
  git -C "$case_dir/project" remote add fork "$case_dir/fork.git"
  # Push the task branch from the worktree to the fork, then fetch into project
  # so refs/remotes/fork/jg-task-x1 is visible from the worktree (shared object db).
  git -C "$case_dir/wt" push -q fork fm/task-x1
  git -C "$case_dir/project" fetch -q fork
}

# Commit a real file change on the worktree's task branch (unlike wt_commit, which
# makes an empty commit). A non-empty tree is what the content-in-default check
# inspects. Args: case_dir file content [message]
wt_commit_file() {
  local case_dir=$1 file=$2 content=$3 msg=${4:-add $2}
  printf '%s\n' "$content" > "$case_dir/wt/$file"
  git -C "$case_dir/wt" add -- "$file"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "$msg"
}

# Land <file>=<content> as a single commit on origin's default branch, simulating a
# squash merge whose net change matches the task branch but whose commit differs.
# After this, the branch's content is in origin/main even though the branch's own
# commits are not reachable from it. Args: case_dir file content
land_on_origin_main() {
  local case_dir=$1 file=$2 content=$3 tmp
  tmp="$case_dir/_land"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash $file"
  git -C "$tmp" push -q origin HEAD:main
  rm -rf "$tmp"
}

# Override GitHub lookups to report PR 7 with the supplied head, merged unless a
# state (OPEN, CLOSED) is given.
add_gh_pr_merged_for_head() {
  local case_dir=$1 head=$2 state=${3:-MERGED} lower
  lower=$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')
  cat > "$case_dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr list")
    printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,$lower" ; exit 0 ;;
  "pr view")
    printf '%s\n' "pull_request:" "  number: 7" "  state: $lower" ; exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid,url"*) printf '%s\t%s\t%s\n' '$state' '$head' 'https://github.com/example/repo/pull/7' ; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Squash-merged history whose pipeline rebased the branch onto a newer main that
# edited the same shared file. A local copy left behind by that rebase holds
# different content for the shared file, so its per-commit patch ids against the
# PR head differ and merge-tree against main conflicts; teardown refuses it on
# purpose rather than reading a shared path as proof the local content landed.
# local_mode: rebased | stale | rebased-plus-unlanded
# Echoes: <pr_head>
setup_squash_rebased_history() {
  local case_dir=$1 local_mode=$2 tmp local_head pr_head
  tmp="$case_dir/_shared_base"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' base > "$tmp/shared.txt"
  git -C "$tmp" add -- shared.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "shared base"
  git -C "$tmp" push -q origin main
  git -C "$case_dir/wt" fetch -q origin
  git -C "$case_dir/wt" reset -q --hard origin/main
  rm -rf "$tmp"

  wt_commit_file "$case_dir" feature.txt hello "add feature"
  printf '%s\n' base feature-edit > "$case_dir/wt/shared.txt"
  git -C "$case_dir/wt" add -- shared.txt
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q -m "edit shared from feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  tmp="$case_dir/_main_move"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' base main-edit > "$tmp/shared.txt"
  git -C "$tmp" add -- shared.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "main edits shared"
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"

  tmp="$case_dir/_pipeline"
  git clone -q "$case_dir/origin.git" "$tmp"
  git -C "$tmp" checkout -q -b fm/task-x1
  printf '%s\n' hello > "$tmp/feature.txt"
  git -C "$tmp" add -- feature.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "add feature"
  printf '%s\n' base main-edit feature-edit > "$tmp/shared.txt"
  git -C "$tmp" add -- shared.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t \
    commit -q -m "edit shared from feature"
  pr_head=$(git -C "$tmp" rev-parse HEAD)
  git -C "$tmp" push -q origin "HEAD:refs/pull/7/head"
  git -C "$tmp" checkout -q main
  git -C "$tmp" merge -q --squash fm/task-x1 >/dev/null
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "feat: squash (#7)"
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"

  git -C "$case_dir/project" fetch -q origin
  git -C "$case_dir/wt" fetch -q origin "refs/pull/7/head:refs/jg-test/pr-head"
  case "$local_mode" in
    rebased)
      git -C "$case_dir/wt" reset -q --hard "$pr_head"
      ;;
    stale)
      git -C "$case_dir/wt" reset -q --hard "$local_head"
      ;;
    rebased-plus-unlanded)
      git -C "$case_dir/wt" reset -q --hard "$pr_head"
      wt_commit_file "$case_dir" later.txt local-only "local follow-up"
      ;;
    *)
      fail "setup_squash_rebased_history: unknown local_mode $local_mode"
      ;;
  esac
  printf '%s\n' "$pr_head"
}

# A refusal must leave every recovery route intact: the isolated copy, its task
# branch still at the unlanded commit, and the durable task record. A completed
# teardown detaches and deletes that branch and removes the record, so these hold
# only while nothing destructive ran before the refusal was reported.
# Args: case_dir label head-before-teardown
assert_refusal_retained_task_state() {
  local case_dir=$1 label=$2 head=$3
  [ -d "$case_dir/wt" ] || fail "$label: refusal removed the isolated copy"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = fm/task-x1 ] \
    || fail "$label: refusal dropped the task branch"
  [ "$(git -C "$case_dir/wt" rev-parse HEAD 2>/dev/null)" = "$head" ] \
    || fail "$label: refusal moved the task branch off the unlanded commit"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "$label: refusal erased the durable task record"
}

append_pr_meta_for_current_head() {
  local case_dir=$1 head
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$head" >> "$case_dir/state/task-x1.meta"
}

append_pr_meta_url() {
  local case_dir=$1
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
}

commit_tree_from_wt_head() {
  local case_dir=$1 parent=$2 msg=$3 tree
  tree=$(git -C "$case_dir/wt" rev-parse "$parent^{tree}") || return 1
  printf '%s\n' "$msg" | git -C "$case_dir/wt" commit-tree "$tree" -p "$parent"
}

land_equivalent_patch_on_origin_branch() {
  local case_dir=$1 branch=$2 file=$3 content=$4 msg=$5 tmp
  tmp="$case_dir/_equiv"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "$msg"
  git -C "$tmp" push -q origin "HEAD:refs/heads/$branch"
  git -C "$case_dir/project" fetch -q origin "$branch"
  rm -rf "$tmp"
  git -C "$case_dir/project" rev-parse "refs/remotes/origin/$branch"
}

# Override gh-axi so every call fails, simulating an API/network error.
add_gh_axi_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "error: gh-axi unavailable" >&2
exit 1
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: gh unavailable" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Override fakebin/treehouse so `treehouse return --force <wt>` fails with a
# git "file exists" lock error whenever the worktree's real index.lock is
# present, and succeeds once it is gone. This drives the lock through
# jg-teardown.sh's own retry-then-stale-cleanup logic (teardown_treehouse_return
# in bin/jg-teardown.sh) rather than hand-simulating that logic in the test.
add_lock_aware_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return fails once with the index.lock signature, then clears the lock
# (simulating a dying crew git process finishing) so the next retry succeeds.
# The first failure always reports the lock path even if the file is removed in
# the same attempt - matching the production race where the lock self-clears
# between the failed return and the supervisor's existence check.
add_transient_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  count_file="${TREEHOUSE_ATTEMPT_FILE:?}"
  count=0
  if [ -f "$count_file" ]; then
    count=$(cat "$count_file")
  fi
  count=$(( count + 1 ))
  printf '%s\n' "$count" > "$count_file"
  if [ "$count" -eq 1 ]; then
    # Emit the real git signature, then drop the lock so a lock-existence-only
    # recovery path would wrongly abort without retrying.
    if [ -n "$lock" ]; then
      echo "fatal: Unable to create '$lock': File exists." >&2
      rm -f "$lock"
    else
      echo "fatal: Unable to create 'index.lock': File exists." >&2
    fi
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return always fails with the lock signature while the lock file
# remains; used to assert exhausted retries still refuse loudly.
add_persistent_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -z "$lock" ]; then
    lock="index.lock"
  fi
  echo "fatal: Unable to create '$lock': File exists." >&2
  exit 128
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

git_index_lock_path() {
  local dir=$1 lock abs_dir
  lock=$(git -C "$dir" rev-parse --git-path index.lock)
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(cd "$dir" && pwd -P)
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# fakebin/lsof stub: no process ever holds anything open (lsof's not-found exit
# code), so a lock's staleness is decided by age alone. The cwd scan is a
# separate successful empty query.
add_lsof_no_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) exit 0 ;;
esac
exit 1
SH
  chmod +x "$case_dir/fakebin/lsof"
}

# fakebin/lsof stub: a live process holds every queried path open, so a lock is
# never judged stale regardless of its age.
add_lsof_live_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_lsof_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
echo "lsof: simulated failure for ${1:-unknown}" >&2
exit 2
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_stat_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
echo "stat: simulated failure" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/stat"
}

add_git_status_lock_failure() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
dir=
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      dir=$2
      args+=("$1" "$2")
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
if [ -n "$dir" ] && [ "${args[2]:-}" = status ] && [ "${args[3]:-}" = --porcelain ]; then
  lock=$("$real" -C "$dir" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$dir/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
fi
exec "$real" "${args[@]}"
SH
  chmod +x "$case_dir/fakebin/git"
}

# Run teardown with PATH mocking. Args: case_dir [extra args...]
run_teardown() {
  local case_dir=$1; shift
  # JG_DATA_OVERRIDE is pinned to the case dir because teardown closes this
  # home's backlog item itself; without it $DATA would resolve to the real
  # repo's own home and a test could mutate live records.
  JG_ROOT_OVERRIDE="$ROOT" \
  JG_STATE_OVERRIDE="$case_dir/state" \
  JG_DATA_OVERRIDE="$case_dir/data" \
  JG_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:${JG_TEARDOWN_TEST_PATH:-$PATH}" \
    "$TEARDOWN" task-x1 "$@"
}

# Seed a real backlog carrying task-x1 as In flight, so a teardown in this case
# has a row to close.
seed_backlog_in_flight() {
  local case_dir=$1 kind=${2:-ship}
  [ -z "$(backlog_row_state "$case_dir")" ] || return 0
  jg_test_backlog "$case_dir" add task-x1 "[feature] teardown fixture task" --priority 1 --kind "$kind" --repo demo \
    --body "Teardown fixture task" >/dev/null
  jg_test_backlog "$case_dir" start task-x1 >/dev/null
}

backlog_row_state() {
  local case_dir=$1
  jg_test_backlog "$case_dir" show task-x1 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

# The whole row, links and body included, as a file the grep assertions can read.
backlog_dump() {  # <case-dir>: prints the file's path
  jg_test_backlog "$1" show task-x1 --full > "$1/data/backlog.dump" 2>&1 || true
  printf '%s\n' "$1/data/backlog.dump"
}

# Build the teardown test's executable search path without lsof, regardless of
# whether the host installs it in /usr/bin, /usr/sbin, or a package-manager bin.
make_path_without_lsof() {  # <case-dir>
  local case_dir=$1 path_dir="$1/path-without-lsof" cmd resolved
  mkdir -p "$path_dir"
  for cmd in awk python3 jq bash basename cat chmod cp cut date dirname env find git go grep head hostname id ln \
    mkdir mktemp mv perl ps readlink realpath rm sed sh sha1sum sha256sum shasum sleep sort stat tail timeout tr uname wc xargs; do
    resolved=$(command -v "$cmd" 2>/dev/null) || continue
    if [ "$cmd" = python3 ]; then
      resolved=$("$resolved" -c 'import sys; print(sys.executable)') || return 1
    fi
    case "$resolved" in /*) ln -sf "$resolved" "$path_dir/$cmd" ;; esac
  done
  printf '%s\n' "$path_dir"
}

test_local_only_fork_remote_allows() {
  local case_dir rc
  case_dir=$(make_case fork-allow)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"
  # The supervision branch's bounded per-task outcome cache is a footprint of
  # the retired task, not a record anything reads after it is gone.
  printf 'jg-branch-outcome-index-v1\t5\t0\t-\n' > "$case_dir/state/.task-x1.branch-outcome-index"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "fork-allow: teardown should succeed when HEAD is on a fork remote"
  ! grep -q REFUSED "$case_dir/stderr" || fail "fork-allow: teardown printed a REFUSED line"
  [ ! -e "$case_dir/state/.task-x1.branch-outcome-index" ] \
    || fail "fork-allow: teardown left the task's branch outcome index behind"
  # The supervision branch reports the teardown it just performed AFTER the
  # task's records are gone (bin/jg-branch-prompt.sh); that report must be
  # stored, must publish its ready sequence, and must not recreate the index.
  post_seq=$(JG_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/jg-branch-outcome.sh" append \
    --task task-x1 --verdict captain --summary 'PR merged and cleaned up') \
    || fail "fork-allow: post-teardown branch report was refused"
  [ "$post_seq" = 1 ] || fail "fork-allow: post-teardown branch report got seq $post_seq, expected 1"
  grep -q '"task":"task-x1"' "$case_dir/state/branch-outcomes.jsonl" \
    || fail "fork-allow: post-teardown branch report was not stored"
  [ ! -e "$case_dir/state/.task-x1.branch-outcome-index" ] \
    || fail "fork-allow: post-teardown branch report recreated the retired task index"
  [ "$(cat "$case_dir/state/.branch-outcome-index-ready")" = 1 ] \
    || fail "fork-allow: post-teardown branch report did not publish its ready sequence"
  jq -e --arg id task-x1 '
    .schema == "jg-squad-lead-home-summary.v1"
    and all(.endpoints[]; .id != $id)
  ' "$case_dir/state/home-summary.json" >/dev/null \
    || fail "successful task teardown did not publish the task's removal from the home summary ledger"
  pass "local-only worktree with HEAD on a fork remote is torn down and the home summary is refreshed"
}

# The per-task file kinds that bin/jg-task-files-lib.sh lists (the state folder diet): a teardown leaves none of them.
seed_task_file_kinds() {  # <case dir>
  local kind
  # shellcheck source=bin/jg-task-files-lib.sh disable=SC1091
  . "$ROOT/bin/jg-task-files-lib.sh"
  for kind in $JG_TASK_FILE_KINDS_RETIRED; do printf '1\n' > "$1/state/task-x1.$kind"; done
  for kind in $JG_TASK_DIR_KINDS_RETIRED; do mkdir "$1/state/task-x1.$kind"; : > "$1/state/task-x1.$kind/commit-msg"; chmod a-w "$1/state/task-x1.$kind"; done
}
assert_task_file_kinds_gone() {  # <case dir> <what ran>
  local kind
  for kind in $JG_TASK_FILE_KINDS_RETIRED $JG_TASK_DIR_KINDS_RETIRED; do assert_absent "$1/state/task-x1.$kind" "$2 left the $kind file"; done
}

test_teardown_of_an_already_cleaned_task_says_so() {
  local case_dir out rc
  case_dir=$(make_case already-cleaned)
  rm -f "$case_dir/state/task-x1.meta"
  : > "$case_dir/state/task-x1.run-receipt.json"
  seed_task_file_kinds "$case_dir"
  rc=0; out=$(run_teardown "$case_dir" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "already-cleaned teardown exited $rc: $out"
  printf '%s\n' "$out" | grep -F 'already cleaned up' >/dev/null \
    || fail "already-cleaned teardown did not say so: $out"
  printf '%s\n' "$out" | grep -F 'not a regular file' >/dev/null \
    && fail "already-cleaned teardown gave the wrong refusal: $out"
  assert_absent "$case_dir/state/task-x1.run-receipt.json" "leftover receipt kept"
  assert_task_file_kinds_gone "$case_dir" "already-cleaned teardown"
  # A record that exists but is not a regular file keeps its refusal.
  mkdir "$case_dir/state/task-x1.meta"
  rc=0; out=$(run_teardown "$case_dir" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "non-regular task record was accepted: $out"
  printf '%s\n' "$out" | grep -F 'not a regular file' >/dev/null \
    || fail "non-regular task record lost its refusal: $out"
  pass "teardown of an already-cleaned task says so and exits 0"
}

# H13: through the real caller. A clean copy that never left its starting commit holds no work. While
# its ticket is open teardown refuses it with the reason empty-lane; once the ticket is closed teardown
# cleans it as dropped, and the ticket is not marked landed (no PR or landing note on its row).
test_empty_lane_of_a_closed_ticket_is_dropped() {
  local case_dir rc
  case_dir=$(make_case empty-lane)
  write_meta "$case_dir" no-mistakes ship
  printf 'base=%s\n' "$(git -C "$case_dir/wt" rev-parse HEAD)" >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "empty-lane: an empty lane of an open ticket is refused"
  grep -F 'cleanup refused, reason: empty-lane' "$case_dir/stderr" >/dev/null \
    || fail "empty-lane: the refusal names no reason from the closed list: $(cat "$case_dir/stderr")"
  [ -d "$case_dir/wt" ] || fail "empty-lane: the refusal removed the copy"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] || fail "empty-lane: the refusal changed the ticket"

  jg_test_backlog "$case_dir" "done" task-x1 --note "dropped by the lead" >/dev/null \
    || fail "empty-lane: the fixture could not close its ticket"
  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "empty-lane: an empty lane of a closed ticket is cleaned: $(cat "$case_dir/stderr")"
  ! grep -q REFUSED "$case_dir/stderr" || fail "empty-lane: the dropped lane printed a refusal: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.meta" "empty-lane: the task record stayed"
  [ "$(backlog_row_state "$case_dir")" = "done" ] || fail "empty-lane: the ticket is not closed"
  ! grep -q 'local-trunk\|pull/' "$(backlog_dump "$case_dir")" || fail "empty-lane: the ticket row carries a landing"
  pass "an empty lane of a closed ticket is cleaned as dropped, and an open one is refused with its reason"
}

test_teardown_closes_the_backlog_item_itself() {
  local case_dir out
  case_dir=$(make_case backlog-close)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  seed_task_file_kinds "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with a real backlog"
  assert_task_file_kinds_gone "$case_dir" "a landed teardown"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "teardown returned success while its backlog item was still open: $(backlog_row_state "$case_dir")"
  assert_grep 'https://github.com/example/repo/pull/7' "$(backlog_dump "$case_dir")" \
    "closed backlog item did not record the task's PR"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "a landed close left its pending-close record behind"
  printf '%s\n' "$out" | grep -F 'bin/jg-backlog.sh ready' >/dev/null \
    || fail "teardown dropped the dependency-cleared follow-up: $out"
  printf '%s\n' "$out" | grep -F 'check date gates' >/dev/null \
    || fail "teardown did not preserve date-gate check: $out"
  printf '%s\n' "$out" | grep -F 'Run jg-backlog.sh done' >/dev/null \
    && fail "teardown still asked a later turn to close the item it already closed: $out"
  pass "teardown closes its own backlog item before reporting success"
}

test_local_only_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case truly-unpushed)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"
  # No fork, no push to origin, not merged into main.

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "truly-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "truly-unpushed: no REFUSED line in stderr"
  pass "local-only worktree with truly unpushed work is refused (safety preserved)"
}

test_local_only_merged_to_local_main_allows() {
  local case_dir rc
  case_dir=$(make_case merged-main)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  # Fast-forward the project's main to the worktree's HEAD commit so HEAD is
  # reachable from main. update-ref works whether or not main is checked out,
  # and the worktree shares the project's object db so the commit is visible.
  local wt_head
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "merged-main: teardown should succeed when work is merged into local main"
  ! grep -q REFUSED "$case_dir/stderr" || fail "merged-main: teardown printed a REFUSED line"
  pass "local-only worktree with work merged into local main is torn down (no regression)"
}

# The reported failure: a direct-PR or no-mistakes worker pushes its branch and
# opens a PR, so HEAD is on a remote-tracking branch while the PR is still open and
# green. A pushed branch is a claim, not a landing; only the forge proves the merge.
test_pushed_branch_needs_forge_merge_proof() {
  local case_dir rc head
  # Open, green PR at the exact pushed head: cleanup refuses and keeps everything.
  case_dir=$(make_case nm-pushed-open)
  write_meta "$case_dir" direct-PR ship
  seed_backlog_in_flight "$case_dir"
  wt_commit_file "$case_dir" feature.txt hello "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$head" OPEN
  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "nm-pushed-open: teardown must refuse while the PR is open"
  grep -F 'no merge proved on the forge: the forge reports PR https://github.com/example/repo/pull/7 as OPEN, not merged' \
    "$case_dir/stderr" >/dev/null || fail "nm-pushed-open: refusal does not name the open PR: $(cat "$case_dir/stderr")"
  assert_refusal_retained_task_state "$case_dir" nm-pushed-open "$head"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "nm-pushed-open: refusal closed the backlog item"

  # The forge reports that PR merged at the pushed head: cleanup proceeds.
  case_dir=$(make_case nm-pushed-merged)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  add_gh_pr_merged_for_head "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"
  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "nm-pushed-merged: teardown should succeed once the forge shows the merge"
  ! grep -q REFUSED "$case_dir/stderr" || fail "nm-pushed-merged: teardown printed a REFUSED line"
  grep -F 'blockers are gone and date is due' "$case_dir/stdout" >/dev/null \
    || fail "nm-pushed-merged: teardown manual prompt did not preserve date-gate check"

  # GitHub cannot be read: cleanup refuses rather than assume, even though the same
  # content already sits on origin's main, because only the forge proves this PR.
  case_dir=$(make_case nm-pushed-unreadable)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  wt_commit_file "$case_dir" feature.txt hello "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  land_on_origin_main "$case_dir" feature.txt hello
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_axi_error "$case_dir"
  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "nm-pushed-unreadable: teardown must refuse when the forge cannot be read"
  grep -F "no merge proved on the forge: the forge could not be read for PR https://github.com/example/repo/pull/7; and this copy's HEAD is not on origin/main." \
    "$case_dir/stderr" >/dev/null || fail "nm-pushed-unreadable: refusal does not name the unread forge: $(cat "$case_dir/stderr")"
  assert_refusal_retained_task_state "$case_dir" nm-pushed-unreadable "$head"
  pass "pushed branch tears down only when the forge proves the merge (open PR and unreadable forge refuse)"
}

test_no_mistakes_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case nm-unpushed)
  write_meta "$case_dir" no-mistakes ship
  # Real content that is not pushed, has no PR (default gh-axi mock), and never
  # landed on origin/main: genuinely unlanded work that must still refuse.
  wt_commit_file "$case_dir" feature.txt hello "unpushed work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nm-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "nm-unpushed: no REFUSED line in stderr"
  pass "no-mistakes worktree with genuinely unlanded work is refused (safety preserved)"
}

test_squash_merged_branch_deleted_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-merged)
  write_meta "$case_dir" no-mistakes ship
  # Real branch content that is NOT pushed and NOT on origin/main: a squash merge
  # rewrote it into a different commit on main and auto-deleted the head branch, so
  # HEAD is unreachable from every remote-tracking branch. The matching merged PR is
  # the only signal that the work landed.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-merged: teardown should succeed when the PR is merged"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-merged: teardown printed a REFUSED line"
  pass "squash-merged + deleted-branch worktree (PR merged) is torn down (the fix)"
}

test_squash_merged_pr_allows_when_head_ancestor_of_pr_head() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case squash-ancestor)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-ancestor: teardown should succeed when local HEAD is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-ancestor: teardown printed a REFUSED line"
  pass "squash-merged PR accepts a local HEAD that is an ancestor of the final PR head"
}

# A cross-repo lane records a PR outside the worktree's origin repository, whose
# head cannot be fetched here: teardown proves this copy against its own
# branch's same-repo PR, and still refuses unlanded work.
test_cross_repo_lane_proves_own_landing() {
  local case_dir rc head
  case_dir=$(make_case cross-repo-merged)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$head"
  # The recorded fork PR merged at a head this repository never had.
  mv "$case_dir/fakebin/gh" "$case_dir/fakebin/gh-same-repo"
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *example/forked/pull/7*) printf 'MERGED\t18ef3b73a1b2c3d4e5f60718293a4b5c6d7e8f90\t%s\n' "$3" ; exit 0 ;;
esac
exec "$(dirname "$0")/gh-same-repo" "$@"
SH
  chmod +x "$case_dir/fakebin/gh"
  git -C "$case_dir/wt" remote set-url origin git@github.com:example/addons.git
  printf '%s\n' "pr=https://github.com/example/forked/pull/7" >> "$case_dir/state/task-x1.meta"
  set +e
  GIT_SSH_COMMAND=false run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "cross-repo-merged: teardown should prove the same-repo PR"
  pass "cross-repo lane with both PRs merged tears down via its own same-repo PR"

  case_dir=$(make_case cross-repo-unlanded)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "unlanded work"
  cp "$TMP_ROOT/cross-repo-merged/fakebin/gh" "$case_dir/fakebin/gh"
  git -C "$case_dir/wt" remote set-url origin git@github.com:example/addons.git
  printf '%s\n' "pr=https://github.com/example/forked/pull/7" >> "$case_dir/state/task-x1.meta"
  set +e
  GIT_SSH_COMMAND=false run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "cross-repo-unlanded: teardown should still refuse unlanded work"
  grep -q REFUSED "$case_dir/stderr" || fail "cross-repo-unlanded: no REFUSED line in stderr"
  pass "cross-repo lane whose worktree HEAD is not landed is still refused"
}

test_no_pr_recorded_discovers_merged_pr_by_branch_allows() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case no-pr-branch-discovery)
  write_meta "$case_dir" no-mistakes ship
  # Reproduces the real false-refusal report exactly, with NO pr=/pr_head=
  # recorded in meta at all (jg-pr-check.sh was never run, e.g. a yolo merge on
  # a repo with no PR CI so the "checks green" trigger that fires it never
  # happened): a branch with a commit, a no-mistakes auto-fix commit pushed on
  # top that never made it back into the local worktree, a squash merge onto
  # main under a brand-new SHA, and the head branch deleted (simulated here by
  # never pushing fm/task-x1 at all, so no refs/remotes/origin/fm/task-x1
  # exists to make HEAD "reachable").
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes auto-fix")
  land_on_origin_main "$case_dir" feature.txt hello
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  seed_backlog_in_flight "$case_dir"
  # No append_pr_meta_* call: state/task-x1.meta has no pr= or pr_head= line.

  ! grep -qE '^(pr|pr_head)=' "$case_dir/state/task-x1.meta" \
    || fail "no-pr-branch-discovery: test setup bug, meta unexpectedly has a pr= line"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-pr-branch-discovery: teardown should succeed by discovering the merged PR from the branch name"
  ! grep -q REFUSED "$case_dir/stderr" || fail "no-pr-branch-discovery: teardown printed a REFUSED line"
  assert_grep 'https://github.com/example/repo/pull/7' "$(backlog_dump "$case_dir")" \
    "no-pr-branch-discovery: resolved PR URL was not recorded on completion"
  pass "teardown discovers a merged PR by branch name and tears down when no pr= was ever recorded"
}

test_squash_merged_pr_allows_replayed_unpushed_patch() {
  local case_dir rc parent_head pr_head
  case_dir=$(make_case squash-replayed-patch)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" local-parent.txt parent "local parent"
  parent_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin "$parent_head:refs/heads/fm/task-x1"
  git -C "$case_dir/project" fetch -q origin fm/task-x1
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  pr_head=$(land_equivalent_patch_on_origin_branch "$case_dir" pr-head feature.txt hello "add feature")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-replayed-patch: teardown should succeed when unpushed local patch is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-replayed-patch: teardown printed a REFUSED line"
  pass "squash-merged PR accepts replayed unpushed local patches contained in the PR head"
}

test_merged_pr_with_later_local_commit_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case stale-pr-head)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-pr-head: teardown should refuse when HEAD moved after PR recording"
  grep -q REFUSED "$case_dir/stderr" || fail "stale-pr-head: no REFUSED line in stderr"
  pass "merged PR does not allow teardown after a later local commit"
}

test_squash_merged_rebased_branch_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-rebased)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_squash_rebased_history "$case_dir" rebased)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-rebased: teardown should succeed when the worktree followed the pipeline rebase"$'\n'"$(cat "$case_dir/stderr")"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-rebased: teardown printed a REFUSED line"
  pass "squash-merged task whose local branch followed the pipeline rebase is torn down"
}

# Override tea to answer one login for git.example.org and a pull request
# read through "tea api" with the supplied merged flag and head.
add_tea_pull_for_head() {
  local case_dir=$1 merged=$2 head=$3
  cat > "$case_dir/fakebin/tea" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/tea.log"
if [ "\${1:-} \${2:-}" = "login list" ]; then
  printf '[\n  {\n    "name": "fj",\n    "url": "https://git.example.org"\n  }\n]\n'
  exit 0
fi
[ "\${1:-}" = api ] || exit 1
printf '{"state":"closed","merged":%s,"head":{"sha":"%s"}}\n' '$merged' '$head'
SH
  chmod +x "$case_dir/fakebin/tea"
}

# A Forgejo task whose default branch moved on after the squash merge, editing
# the same lines, leaves the content check inconclusive, so only the forge's
# merged record can prove the work landed. With the record merged teardown
# proceeds; with it unmerged the same history refuses.
test_squash_merged_forgejo_pr_allows_when_main_moved_on() {
  local case_dir rc pr_head tmp merged expected
  for merged in true false; do
    case_dir=$(make_case "forgejo-merged-$merged")
    write_meta "$case_dir" no-mistakes ship
    pr_head=$(setup_squash_rebased_history "$case_dir" rebased)
    tmp="$case_dir/_main_later"
    git clone -q "$case_dir/origin.git" "$tmp"
    printf '%s\n' base main-edit feature-edit-reworded > "$tmp/shared.txt"
    git -C "$tmp" add -- shared.txt
    git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "main rewords shared"
    git -C "$tmp" push -q origin main
    rm -rf "$tmp"
    printf '%s\n' \
      'pr=https://git.example.org/team/repo/pulls/7' \
      "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
    add_gh_axi_error "$case_dir"
    add_tea_pull_for_head "$case_dir" "$merged" "$pr_head"

    set +e
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expected=1
    [ "$merged" = false ] || expected=0
    expect_code "$expected" "$rc" "forgejo-merged-$merged: teardown exit"$'\n'"$(cat "$case_dir/stderr")"
    grep -qF -- 'api --login fj --repo team/repo /repos/{owner}/{repo}/pulls/7' "$case_dir/tea.log" \
      || fail "forgejo-merged-$merged: teardown did not read the Forgejo pull request through tea"
  done
  pass "teardown proves a Forgejo task landed from the merged pull request when the content check is inconclusive"
}

test_squash_merged_same_file_different_content_refuses() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-same-path-diverged)
  write_meta "$case_dir" no-mistakes ship
  # The pipeline rebase produced a different blob for shared.txt than the stale
  # local still holds, then squash-merged. Same path is not proof the local
  # content landed.
  pr_head=$(setup_squash_rebased_history "$case_dir" stale)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-same-path-diverged: teardown should refuse when the same file has different content"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-same-path-diverged: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" squash-same-path-diverged "$local_head"
  pass "squash-merged same-path different content still refuses"
}

# The local branch followed the pipeline rebase, so without later.txt this is the
# q2 ALLOW case exactly. The one unlanded follow-up commit is the sole difference
# and must be the sole reason teardown refuses.
test_squash_merged_rebased_local_with_unlanded_commit_refuses() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-rebased-unlanded)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_squash_rebased_history "$case_dir" rebased-plus-unlanded)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-rebased-unlanded: teardown should refuse extra local commits that never landed"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-rebased-unlanded: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" squash-rebased-unlanded "$local_head"
  pass "squash-merged rebased local still refuses a genuinely unlanded follow-up commit"
}

test_squash_merged_stale_local_refuses_when_forge_unreachable() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-stale-offline)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_squash_rebased_history "$case_dir" stale)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-stale-offline: teardown should refuse when the forge is down and trees conflict"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-stale-offline: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" squash-stale-offline "$local_head"
  pass "squash-merged stale local still refuses when the forge is unreachable"
}

test_pr_check_does_not_refresh_stale_pr_head() {
  local case_dir rc pr_head new_head count
  case_dir=$(make_case pr-check-stale)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  JG_ROOT_OVERRIDE="$ROOT" \
  JG_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  new_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  JG_ROOT_OVERRIDE="$ROOT" \
  JG_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  count=$(grep -c '^pr_head=' "$case_dir/state/task-x1.meta" || true)
  expect_code 1 "$count" "pr-check-stale: stale rerun should not append a second pr_head"
  ! grep -qxF "pr_head=$new_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-stale: stale rerun recorded the later local HEAD"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-check-stale: teardown should refuse after a later local commit"
  grep -q REFUSED "$case_dir/stderr" || fail "pr-check-stale: no REFUSED line in stderr"
  pass "jg-pr-check does not refresh PR head after HEAD moves"
}

test_pr_check_records_remote_head_when_local_lags() {
  local case_dir local_head pr_head
  case_dir=$(make_case pr-check-local-lags)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  JG_ROOT_OVERRIDE="$ROOT" \
  JG_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  grep -qxF "pr_head=$pr_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: did not record GitHub PR head"
  ! grep -qxF "pr_head=$local_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: recorded local HEAD instead of remote PR head"
  pass "jg-pr-check records the remote PR head when the local worktree lags"
}

test_content_in_default_fallback_allows() {
  local case_dir rc
  case_dir=$(make_case content-landed)
  write_meta "$case_dir" no-mistakes ship
  # No pr= recorded and the default gh-axi mock reports no PR, so the merged-PR path
  # cannot fire and the content check must carry it. The branch adds feature.txt, and
  # the same net change has independently landed on origin/main via a squash commit.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${JG_TEST_TREEHOUSE_LOG:?}"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  JG_TEST_TREEHOUSE_LOG="$case_dir/treehouse.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-landed: teardown should succeed when content is already in the default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-landed: teardown printed a REFUSED line"
  assert_present "$case_dir/treehouse.log" \
    "content-landed: teardown never reached destructive worktree cleanup"
  assert_absent "$case_dir/state/task-x1.meta" \
    "content-landed: teardown left task metadata after destructive cleanup"
  pass "worktree whose content already landed in the default branch is torn down (content fallback)"
}

# A task recording base_branch= landed when its content reached that branch, not
# the default branch: a squash merge into the base branch is the landing.
test_content_fallback_uses_recorded_base_branch() {
  local case_dir rc landed tmp
  for landed in base default; do
    case_dir=$(make_case "content-base-$landed")
    write_meta "$case_dir" direct-PR ship
    printf 'base_branch=feature/hub\n' >> "$case_dir/state/task-x1.meta"
    tmp="$case_dir/_hub"
    git clone -q "$case_dir/origin.git" "$tmp"
    git -C "$tmp" push -q origin HEAD:refs/heads/feature/hub
    rm -rf "$tmp"
    wt_commit_file "$case_dir" feature.txt hello "add feature"
    if [ "$landed" = base ]; then
      tmp="$case_dir/_land"
      git clone -q "$case_dir/origin.git" "$tmp"
      git -C "$tmp" checkout -q feature/hub
      printf 'hello\n' > "$tmp/feature.txt"
      git -C "$tmp" add feature.txt
      git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash feature.txt"
      git -C "$tmp" push -q origin HEAD:feature/hub
      rm -rf "$tmp"
    else
      land_on_origin_main "$case_dir" feature.txt hello
    fi
    cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$case_dir/fakebin/treehouse"

    set +e
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    if [ "$landed" = base ]; then
      expect_code 0 "$rc" "content-base: content squashed into the recorded base branch should count as landed"
      assert_absent "$case_dir/state/task-x1.meta" "content-base: teardown kept the record of landed work"
    else
      [ "$rc" -ne 0 ] || fail "content-base: content only on the default branch passed for a task based on feature/hub"
      assert_present "$case_dir/state/task-x1.meta" "content-base: a refused teardown removed the task record"
    fi
  done
  pass "the content-landed fallback checks a task's recorded base branch, not the default branch"
}

test_content_fallback_refreshes_stale_origin_ref() {
  local case_dir rc
  case_dir=$(make_case content-stale-ref)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  git -C "$case_dir/project" config --unset-all remote.origin.fetch
  git -C "$case_dir/project" config --add remote.origin.fetch '+refs/heads/not-main:refs/remotes/origin/not-main'
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-stale-ref: teardown should use the freshly fetched default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-stale-ref: teardown printed a REFUSED line"
  pass "content fallback refreshes origin default before comparing trees"
}

test_dirty_worktree_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case dirty-wt)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # The committed work has fully landed (merged PR + content in default), but an
  # uncommitted edit remains. Dirtiness must refuse regardless: the reset would
  # discard those changes.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  printf '%s\n' "uncommitted edit" > "$case_dir/wt/feature.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-wt: teardown should refuse a dirty worktree even when the committed work has landed"
  grep -q REFUSED "$case_dir/stderr" || fail "dirty-wt: no REFUSED line in stderr"
  grep -q "uncommitted changes" "$case_dir/stderr" || fail "dirty-wt: refusal did not cite uncommitted changes"
  pass "dirty worktree is refused even when its committed work has landed (dirty always wins)"
}

assert_dirty_diagnostic() {
  local kind=$1 mode=$2 case_dir rc before n
  case_dir=$(make_case "dirty-$kind-$mode")
  write_meta "$case_dir" "$mode" ship
  wt_commit_file "$case_dir" feature.txt hello
  # Exercise both dirty refusal sites: remote-reachable work and local-only
  # work merged into local main but absent from every remote.
  if [ "$mode" = local-only ]; then
    git -C "$case_dir/project" merge -q --ff-only fm/task-x1
  else
    git -C "$case_dir/wt" push -q origin fm/task-x1
  fi
  if [ "$kind" != untracked ]; then
    printf '%s\n' 'uncommitted edit' > "$case_dir/wt/feature.txt"
    # Cover index edits as well as unstaged edits.
    [ "$mode" != local-only ] || git -C "$case_dir/wt" add feature.txt
  fi
  if [ "$kind" != tracked ]; then
    mkdir "$case_dir/wt/00 proof scratch"
    printf '%s\n' 'manual server log' > "$case_dir/wt/00 proof scratch/server.log"
    for n in 01 02 03 04 05 06 07 08 09 10 11; do
      touch "$case_dir/wt/$n-scratch.txt"
    done
    # Preserve the existing exemptions without counting them as leftovers.
    mkdir "$case_dir/wt/.claude"
    touch "$case_dir/wt/.claude/settings.local.json" "$case_dir/wt/.jg-grok-turnend"
  fi
  before=$(git -C "$case_dir/wt" status --porcelain)
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "$kind/$mode: dirty teardown must still refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "$kind/$mode: no refusal"
  if [ "$kind" = untracked ]; then
    grep -Fq 'uncommitted changes present (untracked-only leftovers)' "$case_dir/stderr" \
      || fail "$kind/$mode: missing untracked-only classification"
    ! grep -q 'includes tracked edits' "$case_dir/stderr" || fail "$kind/$mode: misclassified as tracked"
  else
    grep -Fq 'uncommitted changes present (includes tracked edits)' "$case_dir/stderr" \
      || fail "$kind/$mode: missing tracked-edit classification"
    ! grep -q 'untracked-only' "$case_dir/stderr" || fail "$kind/$mode: misclassified as untracked-only"
  fi
  if [ "$kind" != tracked ]; then
    grep -Fq '00 proof scratch/' "$case_dir/stderr" || fail "$kind/$mode: scratch folder not named"
    grep -Fxq '  09-scratch.txt' "$case_dir/stderr" || fail "$kind/$mode: tenth path missing"
    ! grep -q '10-scratch.txt\|11-scratch.txt\|\.claude/\|\.jg-grok-turnend' "$case_dir/stderr" \
      || fail "$kind/$mode: path list exceeded its bound or included exempt files"
    grep -Fq 'additional untracked paths omitted' "$case_dir/stderr" || fail "$kind/$mode: no truncation notice"
  else
    ! grep -q 'untracked paths' "$case_dir/stderr" || fail "$kind/$mode: invented untracked paths"
  fi
  [ -f "$case_dir/state/task-x1.meta" ] || fail "$kind/$mode: task metadata removed"
  [ "$before" = "$(git -C "$case_dir/wt" status --porcelain)" ] || fail "$kind/$mode: worktree changed"
  pass "$kind/$mode: dirty refusal classifies leftovers and preserves work"
}

test_untracked_only_refusal_diagnostic() {
  assert_dirty_diagnostic untracked no-mistakes
  assert_dirty_diagnostic untracked local-only
}

test_tracked_edit_refusal_diagnostic() {
  assert_dirty_diagnostic tracked no-mistakes
  assert_dirty_diagnostic tracked local-only
}

test_mixed_refusal_diagnostic() {
  assert_dirty_diagnostic mixed no-mistakes
  assert_dirty_diagnostic mixed local-only
}

# Treehouse's return runs `git clean -fd` (one -f). A nested repository stays.
add_treehouse_clean_fd() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  if [ -n "$wt" ]; then
    git -C "$wt" clean -fdq || true
  fi
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# Return succeeds, then plants a nested repository the pre-return scrub cannot
# have removed. The post-return check must name that residue.
add_treehouse_that_leaves_residue() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  if [ -n "$wt" ]; then
    git -C "$wt" clean -fdq || true
    git init -q "$wt/left-behind-clone"
    git -C "$wt/left-behind-clone" commit -q --allow-empty -m residue
  fi
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

prepare_scout_teardown() {
  local case_dir=$1
  mkdir -p "$case_dir/data/task-x1"
  printf '%s\n' 'Scout report.' > "$case_dir/data/task-x1/report.md"
  printf '%s\n' 'decisions_reviewed=1' >> "$case_dir/state/task-x1.meta"
}

# Clone a nested repository into the copy and add one plain scratch file.
seed_nested_clone_and_scratch() {
  local case_dir=$1 wt=$2
  git init -q "$case_dir/nested-src"
  printf 'payload\n' > "$case_dir/nested-src/payload.txt"
  git -C "$case_dir/nested-src" add payload.txt
  git -C "$case_dir/nested-src" -c user.email=t@t -c user.name=t commit -q -m payload
  git clone -q "$case_dir/nested-src" "$wt/scratch-clone"
  printf 'scratch\n' > "$wt/scratch.txt"
}

# Move the case worktree to pool/<slot>/repo so teardown sees a Treehouse slot.
move_case_to_pool_slot() {
  local case_dir=$1 slot=$2 dest
  dest="$case_dir/pool/$slot/repo"
  mkdir -p "$case_dir/pool/$slot"
  git -C "$case_dir/project" worktree move "$case_dir/wt" "$dest"
  printf '{"worktrees":[{"name":"%s","path":"%s"}]}\n' "$slot" "$dest" \
    > "$case_dir/pool/treehouse-state.json"
  printf '%s\n' "$dest"
}

test_scout_nested_clone_returns_with_no_untracked_entries() {
  local case_dir wt rc
  case_dir=$(make_case scout-nested-clean)
  wt="$case_dir/wt"
  write_meta "$case_dir" no-mistakes scout
  prepare_scout_teardown "$case_dir"
  seed_nested_clone_and_scratch "$case_dir" "$wt"
  add_treehouse_clean_fd "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "scout-nested-clean: teardown should return the scratch copy"
  [ -z "$(git -C "$wt" status --porcelain --untracked-files=all)" ] \
    || fail "scout-nested-clean: untracked entries remain: $(git -C "$wt" status --porcelain --untracked-files=all)"
  assert_absent "$wt/scratch-clone" "scout-nested-clean: nested clone survived return"
  assert_absent "$wt/scratch.txt" "scout-nested-clean: scratch file survived return"
  pass "scout copy with a nested clone and a scratch file returns with no untracked entries"
}

# A scout that posted a board report page whose opening is a finding instead of
# the report's Answer is refused (bin/jg-report-opening-check.sh); the same page
# reposted under the same key with the Answer in the picture heading is returned.
test_scout_report_page_must_open_with_the_answer() {
  local case_dir rc board
  case_dir=$(make_case scout-page-opening)
  write_meta "$case_dir" no-mistakes scout
  prepare_scout_teardown "$case_dir"
  printf '%s\n' '# Deep Recon design' '' '## 1. Answer (five lines)' '' \
    '1. **Add a depth level to every Recon: quick, standard or deep.** Deep runs a fixed method.' \
    '' '## 2. Evidence' '' 'The Pi-bots page lost most of its report.' > "$case_dir/data/task-x1/report.md"
  board="$case_dir/board.json"
  printf '{"schema":2,"items":[{"key":"deep-page","kind":"report","filer":"task-x1","title":"Deep Recon","visual":{"heading":"The Pi-bots page lost most of its report"},"sections":[{"heading":"Question"}]}]}\n' > "$board"
  mkdir -p "$case_dir/config"
  printf "exec merge-card post --board '%s' \"\$@\"\n" "$board" > "$case_dir/config/post-merge"
  add_treehouse_clean_fd "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "scout-page-opening: a page opening with a finding must be refused"
  grep -q 'does not open with its Answer' "$case_dir/stderr" \
    || fail "scout-page-opening: refusal did not name the Answer: $(cat "$case_dir/stderr")"
  grep -q 'The Pi-bots page lost most of its report' "$case_dir/stderr" \
    || fail "scout-page-opening: refusal did not show the page opening: $(cat "$case_dir/stderr")"

  jq '.items[0].visual.heading = "Add a depth level to every Recon: quick, standard or deep."' "$board" > "$board.new" \
    && mv "$board.new" "$board"
  set +e
  run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 0 "$rc" "scout-page-opening: a page opening with the Answer must be returned: $(cat "$case_dir/stderr2")"
  pass "scout teardown refuses a report page that does not open with its Answer and returns one that does"
}

# A Recon report that names three of the project's stored state-map states and parts
# is refused once the warn week has passed unless it carries the map
# (core/project-state-map/bin/psm-wide-check.sh); with a State map section it is returned.
test_scout_wide_report_must_carry_the_state_map() {
  local case_dir rc psm
  psm="$ROOT/core/project-state-map"
  case_dir=$(make_case scout-wide-report)
  write_meta "$case_dir" no-mistakes scout
  prepare_scout_teardown "$case_dir"
  mkdir -p "$case_dir/state/project-state-map/project"
  bash "$psm/bin/psm-prove.sh" "$psm/tests/fixture-map.json" "$psm/tests/fixture-project" \
    --out "$case_dir/state/project-state-map/project/proved.json"
  echo 1 > "$case_dir/state/project-state-map/wide-since"
  printf '%s\n' '# Wide' '' '## 1. Answer (five lines)' '' '1. The Ticket stage, the Gate state and the Board poll all misbehave.' > "$case_dir/data/task-x1/report.md"
  add_treehouse_clean_fd "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "scout-wide-report: a wide report without the state map must be refused"
  grep -q 'wide report without the project' "$case_dir/stderr" \
    || fail "scout-wide-report: refusal did not name the state map: $(cat "$case_dir/stderr")"

  printf '%s\n' '' '## 2. State map' '' 'See the project card.' >> "$case_dir/data/task-x1/report.md"
  set +e
  run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 0 "$rc" "scout-wide-report: a wide report with the state map must be returned: $(cat "$case_dir/stderr2")"
  pass "scout teardown refuses a wide report without the project's state map and returns one that carries it"
}

# A standard Recon whose report fails the depth gate (bin/jg-recon-gate.sh) is
# refused at cleanup; the same Recon with a quick brief is returned.
test_scout_report_must_pass_the_recon_depth_gate() {
  local case_dir rc
  case_dir=$(make_case scout-depth-gate)
  write_meta "$case_dir" no-mistakes scout
  prepare_scout_teardown "$case_dir"
  printf '%s\n' '# Task' '' '# Recon depth' 'Recon depth: standard' > "$case_dir/data/task-x1/brief.md"
  add_treehouse_clean_fd "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "scout-depth-gate: a shallow standard report must be refused"
  grep -q 'does not pass the Recon depth gate' "$case_dir/stderr" \
    || fail "scout-depth-gate: refusal did not name the gate: $(cat "$case_dir/stderr")"
  grep -q "no section '## 1. Answer'" "$case_dir/stderr" \
    || fail "scout-depth-gate: refusal did not say what is missing: $(cat "$case_dir/stderr")"

  printf '%s\n' '# Task' '' '# Recon depth' 'Recon depth: quick' > "$case_dir/data/task-x1/brief.md"
  set +e
  run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 0 "$rc" "scout-depth-gate: a quick Recon is exempt from the gate: $(cat "$case_dir/stderr2")"
  pass "scout teardown refuses a standard report that fails the depth gate and returns a quick one"
}

test_ship_nested_clone_is_refused_and_bytes_stay() {
  local case_dir wt rc head before after
  case_dir=$(make_case ship-nested-refuse)
  wt="$case_dir/wt"
  write_meta "$case_dir" no-mistakes ship
  seed_nested_clone_and_scratch "$case_dir" "$wt"
  before=$(cksum "$wt/scratch-clone/payload.txt")
  head=$(git -C "$wt" rev-parse HEAD)
  : > "$case_dir/treehouse.log"
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "ship-nested-refuse: teardown should refuse a nested clone"
  assert_grep "REFUSED" "$case_dir/stderr" "ship-nested-refuse: no REFUSED line"
  assert_grep "uncommitted changes" "$case_dir/stderr" \
    "ship-nested-refuse: refusal did not cite uncommitted changes"
  after=$(cksum "$wt/scratch-clone/payload.txt")
  [ "$before" = "$after" ] || fail "ship-nested-refuse: nested clone bytes changed"
  assert_present "$wt/scratch-clone/.git" "ship-nested-refuse: nested repository was removed"
  assert_present "$wt/scratch.txt" "ship-nested-refuse: scratch file was removed"
  [ ! -s "$case_dir/treehouse.log" ] \
    || fail "ship-nested-refuse: refusal returned the copy: $(cat "$case_dir/treehouse.log")"
  assert_refusal_retained_task_state "$case_dir" "ship-nested-refuse" "$head"
  pass "ship copy with a nested clone is refused and its bytes stay"
}

test_dirty_return_warns_which_slot_was_lost() {
  local case_dir wt rc
  case_dir=$(make_case dirty-return)
  wt=$(move_case_to_pool_slot "$case_dir" 9)
  write_meta "$case_dir" no-mistakes scout "$wt"
  prepare_scout_teardown "$case_dir"
  add_treehouse_that_leaves_residue "$case_dir"

  set +e
  JG_HOME="$case_dir" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 4 "$rc" "dirty-return: a lost slot should exit 4 after cleanup"
  assert_grep "pool slot 9" "$case_dir/stderr" "dirty-return: warning did not name the slot"
  assert_grep "left-behind-clone" "$case_dir/stderr" "dirty-return: warning did not name the remaining path"
  assert_grep "lost this slot" "$case_dir/stderr" "dirty-return: warning did not say the pool lost the slot"
  assert_no_grep "teardown task-x1 complete" "$case_dir/stdout" \
    "dirty-return: stdout still reported a clean return"
  assert_grep "Backlog: task-x1" "$case_dir/stdout" \
    "dirty-return: the finished teardown skipped its backlog reminder"
  assert_absent "$case_dir/state/task-x1.meta" "dirty-return: task record was not removed"
  pass "a return that leaves residue names the lost slot and the remaining paths"
}

test_dirty_return_warns_even_when_a_later_step_refuses() {
  local case_dir wt rc
  case_dir=$(make_case dirty-return-later-refusal)
  wt=$(move_case_to_pool_slot "$case_dir" 8)
  write_meta "$case_dir" no-mistakes scout "$wt"
  prepare_scout_teardown "$case_dir"
  add_treehouse_that_leaves_residue "$case_dir"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  kill-window) exit 1 ;;
  list-windows) printf '%s\n' jg-task-x1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  set +e
  JG_HOME="$case_dir" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-return-later-refusal: the endpoint refusal should fail teardown"
  assert_grep "could not be closed" "$case_dir/stderr" \
    "dirty-return-later-refusal: fixture did not reach the endpoint close refusal"
  assert_grep "pool slot 8" "$case_dir/stderr" \
    "dirty-return-later-refusal: a later refusal dropped the lost-slot warning"
  assert_grep "left-behind-clone" "$case_dir/stderr" \
    "dirty-return-later-refusal: a later refusal dropped the remaining paths"
  pass "a dirty return is reported even when a later teardown step refuses"
}

test_forced_squad_lead_child_scout_nested_clone_returns_clean() {
  local case_dir home child_wt rc
  case_dir=$(make_case squad-lead-child-nested-clean)
  write_meta "$case_dir" local-only squad_lead
  home="$case_dir/squad-lead-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.jg-squad-lead-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  child_wt="$case_dir/child-scout-wt"
  git -C "$case_dir/project" worktree add -q -b fm/child-scout "$child_wt" main
  jg_write_meta "$home/state/child-scout.meta" \
    "window=juggernaut:jg-child-scout" \
    "endpoint_task_id=child-scout" \
    "worktree=$child_wt" \
    "project=$case_dir/project" \
    "kind=scout" \
    "mode=local-only"
  seed_nested_clone_and_scratch "$case_dir" "$child_wt"
  add_treehouse_clean_fd "$case_dir"

  rc=0
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "squad-lead-child-nested-clean: forced squad_lead teardown should succeed"
  [ -z "$(git -C "$child_wt" status --porcelain --untracked-files=all)" ] \
    || fail "squad-lead-child-nested-clean: untracked entries remain: $(git -C "$child_wt" status --porcelain --untracked-files=all)"
  assert_absent "$child_wt/scratch-clone" "squad-lead-child-nested-clean: nested clone survived return"
  assert_absent "$child_wt/scratch.txt" "squad-lead-child-nested-clean: scratch file survived return"
  assert_no_grep "lost this slot" "$case_dir/stderr" \
    "squad-lead-child-nested-clean: a clean child return was reported as a lost slot"
  pass "a forced squad_lead teardown returns a child scout copy with a nested clone clean"
}

# Return succeeds but leaves no readable worktree behind to verify.
add_treehouse_that_removes_copy() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  for a in "$@"; do wt=$a; done
  rm -f "$wt/.git"
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# The remote host runs exactly this forced squad_lead teardown for
# `jg-remote-squad-lead-control.sh retire --force`; the local side finishes the
# route, record, and reply-source cleanup when it exits 0 or 4 (lost slot).
test_forced_squad_lead_dirty_child_return_warns_and_completes() {
  local case_dir home child_wt rc
  case_dir=$(make_case squad-lead-child-dirty-return)
  write_meta "$case_dir" local-only squad_lead
  home="$case_dir/squad-lead-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.jg-squad-lead-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  child_wt="$case_dir/pool/6/repo"
  mkdir -p "$case_dir/pool/6"
  git -C "$case_dir/project" worktree add -q -b fm/child-scout "$child_wt" main
  printf '{"worktrees":[{"name":"6","path":"%s"}]}\n' "$child_wt" \
    > "$case_dir/pool/treehouse-state.json"
  jg_write_meta "$home/state/child-scout.meta" \
    "window=juggernaut:jg-child-scout" \
    "endpoint_task_id=child-scout" \
    "worktree=$child_wt" \
    "project=$case_dir/project" \
    "kind=scout" \
    "mode=local-only"
  add_treehouse_that_leaves_residue "$case_dir"

  rc=0
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 4 "$rc" "squad-lead-child-dirty-return: a lost child slot should exit 4 after retirement"
  assert_grep "lost this slot" "$case_dir/stderr" \
    "squad-lead-child-dirty-return: no lost-slot warning for the dirty child return"
  assert_grep "left-behind-clone" "$case_dir/stderr" \
    "squad-lead-child-dirty-return: warning did not name the remaining path"
  assert_absent "$case_dir/state/task-x1.meta" "squad-lead-child-dirty-return: task record was not removed"
  assert_absent "$home" "squad-lead-child-dirty-return: squad_lead home was not removed"
  pass "a forced squad_lead teardown warns about a dirty child return and still completes"
}

test_return_that_removes_copy_warns_cannot_verify() {
  local case_dir wt rc
  case_dir=$(make_case return-removes-copy)
  wt=$(move_case_to_pool_slot "$case_dir" 7)
  write_meta "$case_dir" no-mistakes scout "$wt"
  prepare_scout_teardown "$case_dir"
  add_treehouse_that_removes_copy "$case_dir"

  rc=0
  JG_HOME="$case_dir" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 4 "$rc" "return-removes-copy: an unverified slot should exit 4 after cleanup"
  assert_grep "lost this slot" "$case_dir/stderr" "return-removes-copy: no lost-slot warning"
  assert_grep "cannot verify" "$case_dir/stderr" "return-removes-copy: warning did not say the slot is unverified"
  assert_grep "$wt" "$case_dir/stderr" "return-removes-copy: warning did not name the copy"
  assert_no_grep "teardown task-x1 complete" "$case_dir/stdout" \
    "return-removes-copy: stdout still reported a clean return"
  assert_absent "$case_dir/state/task-x1.meta" "return-removes-copy: task record was not removed"
  pass "a return that leaves no readable copy reports the slot as unverified, not clean"
}

test_scout_ignored_files_survive_scratch_clean() {
  local case_dir wt rc
  case_dir=$(make_case scout-ignored-survives)
  wt="$case_dir/wt"
  write_meta "$case_dir" no-mistakes scout
  prepare_scout_teardown "$case_dir"
  printf '%s\n' 'ignored-cache/' > "$wt/.gitignore"
  git -C "$wt" add .gitignore
  git -C "$wt" -c user.email=t@t -c user.name=t commit -q -m "ignore cache"
  mkdir -p "$wt/ignored-cache"
  printf 'keep-me\n' > "$wt/ignored-cache/blob"
  printf 'scratch\n' > "$wt/scratch.txt"
  add_treehouse_clean_fd "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "scout-ignored: teardown should succeed"
  [ "$(cat "$wt/ignored-cache/blob")" = "keep-me" ] \
    || fail "scout-ignored: ignored file was removed or changed"
  assert_absent "$wt/scratch.txt" "scout-ignored: scratch file survived"
  [ -z "$(git -C "$wt" status --porcelain --untracked-files=all)" ] \
    || fail "scout-ignored: untracked entries remain: $(git -C "$wt" status --porcelain --untracked-files=all)"
  pass "ignored files survive the scratch clean and plain scratch does not"
}

test_gh_error_and_content_absent_refuses() {
  local case_dir rc
  case_dir=$(make_case gh-error)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # Real content not pushed, the PR lookup errors, and origin/main never gained the
  # content. The fail-safe must refuse rather than allow on a transient gh failure.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gh-error: teardown should refuse when the PR lookup errors and content is not landed"
  grep -q REFUSED "$case_dir/stderr" || fail "gh-error: no REFUSED line in stderr"
  pass "gh lookup error with content not in default refuses (fail-safe)"
}

# Write a meta that predates the spawn_gen field entirely. Args: case_dir mode kind
write_legacy_meta() {
  local case_dir=$1 mode=$2 kind=$3
  jg_write_meta "$case_dir/state/task-x1.meta" \
    "window=juggernaut:jg-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "harness=codex"
}

# Count spawn_gen fields in the task's meta, so a refusal can prove it left the
# record byte-equivalent rather than stamped.
legacy_meta_gen_count() {
  local case_dir=$1
  awk -F= '$1 == "spawn_gen" { count++ } END { print count + 0 }' \
    "$case_dir/state/task-x1.meta" 2>/dev/null || printf '0\n'
}

# Override fakebin/tmux so the recovery-grade classifier reads the endpoint as
# unreadable (a session inventory failure it cannot attribute), never dead.
add_unreadable_tmux() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) echo "error connecting to fixture: permission denied" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
}

test_legacy_record_without_the_flag_refuses() {
  local case_dir rc
  case_dir=$(make_case legacy-noflag)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-noflag: a record without spawn_gen must refuse without --legacy-record"
  grep -q -- '--legacy-record' "$case_dir/stderr" \
    || fail "legacy-noflag: the refusal did not name the --legacy-record path"
  [ "$(legacy_meta_gen_count "$case_dir")" = 0 ] \
    || fail "legacy-noflag: the refusal stamped a spawn generation into the record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-noflag: the refusal closed the backlog item anyway"
  assert_present "$case_dir/state/task-x1.meta" \
    "legacy-noflag: the refusal removed the task record"
  pass "a record predating spawn_gen refuses teardown until --legacy-record is passed"
}

write_windowless_legacy_meta() {
  local case_dir=$1 mode=$2 kind=$3 worktree
  worktree=${4:-$case_dir/wt}
  jg_write_meta "$case_dir/state/task-x1.meta" \
    "worktree=$worktree" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "harness=codex"
}

test_windowless_legacy_record_with_gone_worktree_tears_down() {
  local case_dir out
  case_dir=$(make_case windowless-gone)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  seed_backlog_in_flight "$case_dir"

  out=$(run_teardown "$case_dir") \
    || fail "windowless-gone: teardown refused a leftover with no window, no spawn_gen, and no worktree"
  printf '%s\n' "$out" | grep -Fq 'legacy record accepted without spawn_gen: endpoint missing' \
    || fail "windowless-gone: the teardown line did not log the missing-endpoint leftover: $out"
  printf '%s\n' "$out" | grep -Fq 'window none' \
    || fail "windowless-gone: the teardown line did not say there was no window: $out"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "windowless-gone: teardown returned success with its backlog item still open"
  assert_absent "$case_dir/state/task-x1.meta" \
    "windowless-gone: teardown left the leftover record"
  pass "a windowless leftover with no spawn_gen and no worktree tears down without --legacy-record"
}

test_windowless_legacy_record_tears_down_with_the_legacy_flag() {
  local case_dir out
  case_dir=$(make_case windowless-flag)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  seed_backlog_in_flight "$case_dir"

  out=$(run_teardown "$case_dir" --legacy-record) \
    || fail "windowless-flag: --legacy-record refused a leftover with no window and no spawn_gen"
  printf '%s\n' "$out" | grep -Fq 'legacy record accepted without spawn_gen: endpoint missing' \
    || fail "windowless-flag: the teardown line did not log the missing-endpoint leftover: $out"
  assert_absent "$case_dir/state/task-x1.meta" \
    "windowless-flag: teardown left the leftover record"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "windowless-flag: teardown returned success with its backlog item still open"
  pass "a windowless leftover with no spawn_gen also tears down when --legacy-record is passed"
}

test_windowless_legacy_record_still_refuses_unlanded_work() {
  local case_dir rc before
  case_dir=$(make_case windowless-unlanded)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit_file "$case_dir" feature.txt unique-windowless-content "real unlanded work"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "windowless-unlanded: a still-present unlanded worktree must refuse"
  grep -q REFUSED "$case_dir/stderr" \
    || fail "windowless-unlanded: no REFUSED line for unlanded windowless work"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "windowless-unlanded: the unlanded refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "windowless-unlanded: the unlanded refusal closed the backlog item anyway"
  pass "a windowless leftover still refuses while its worktree holds unlanded work"
}

test_windowless_record_with_spawn_gen_tears_down_when_nothing_is_unlanded() {
  local case_dir out
  case_dir=$(make_case windowless-gen-clean)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'spawn_gen=s1700000000.1.abc' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"

  out=$(run_teardown "$case_dir") \
    || fail "windowless-gen-clean: teardown refused a published record with no window and nothing unlanded"
  printf '%s\n' "$out" | grep -Fq 'window none' \
    || fail "windowless-gen-clean: the teardown line did not say there was no window: $out"
  assert_absent "$case_dir/state/task-x1.meta" \
    "windowless-gen-clean: teardown left the record"
  pass "a windowless record with a spawn_gen and nothing unlanded tears down"
}

test_windowless_record_with_spawn_gen_still_refuses_unlanded_work() {
  local case_dir rc before
  case_dir=$(make_case windowless-gen-unlanded)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'spawn_gen=s1700000000.1.abc' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit_file "$case_dir" feature.txt unique-gen-content "real unlanded work"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "windowless-gen-unlanded: unlanded work must refuse"
  grep -q REFUSED "$case_dir/stderr" \
    || fail "windowless-gen-unlanded: no REFUSED line"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "windowless-gen-unlanded: the refusal modified the task record"
  pass "a windowless record with a spawn_gen still refuses while its worktree holds unlanded work"
}

assert_windowless_record_refuses() {  # <case-dir> <description> <refusal>
  local case_dir=$1 description=$2 refusal=$3 rc before
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')
  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "$description: a windowless record outside the leftover class must refuse"
  grep -Fq "$refusal" "$case_dir/stderr" \
    || fail "$description: the refusal was not '$refusal': $(cat "$case_dir/stderr")"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "$description: the refusal modified the task record"
}

test_windowless_record_outside_the_leftover_class_still_refuses() {
  local case_dir
  case_dir=$(make_case windowless-orca)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'backend=orca' 'terminal=term-7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-orca "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-dup-project)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' "project=$case_dir/other-project" >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-dup-project "no spawn_gen that identifies one exact incarnation"
  case_dir=$(make_case windowless-foreign-binding)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'endpoint_task_id=task-other' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-foreign-binding "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-terminal)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'terminal=term-7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-terminal "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-herdr-identity)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'backend=tmux' 'herdr_session=s1' 'herdr_pane_id=p1' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-herdr-identity "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-cmux-identity)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'cmux_surface_id=surface-1' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-cmux-identity "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-control-char)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing"$'\t'"wt"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-control-char "no spawn_gen that identifies one exact incarnation"
  pass "a windowless record with a non-tmux backend or endpoint identity, no backlog validation, or ambiguous, foreign, or malformed identity still refuses"
}

test_windowless_leftover_retries_its_retained_legacy_stamp_without_the_flag() {
  local case_dir rc out
  case_dir=$(make_case windowless-retry)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'pr=not-a-valid-url' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  add_failing_truncate_perl "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "windowless-retry: an unrecordable close must fail the first attempt"
  [ "$(legacy_meta_gen_count "$case_dir")" = 1 ] \
    || fail "windowless-retry: the failed attempt did not leave its legacy stamp on the record"

  rm -f "$case_dir/fakebin/perl"
  sed -i.bak '/^pr=/d' "$case_dir/state/task-x1.meta" && rm -f "$case_dir/state/task-x1.meta.bak"
  out=$(run_teardown "$case_dir") \
    || fail "windowless-retry: the flag-less retry refused the retained legacy stamp"
  printf '%s\n' "$out" | grep -Fq 'legacy record accepted without spawn_gen: endpoint missing' \
    || fail "windowless-retry: the retry did not accept the missing-endpoint leftover: $out"
  assert_absent "$case_dir/state/task-x1.meta" \
    "windowless-retry: the retry left the leftover record"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "windowless-retry: the retry returned success with its backlog item still open"
  pass "a windowless leftover retries its retained legacy stamp without --legacy-record"
}

test_legacy_record_teardown_completes_when_landed_and_endpoint_dead() {
  local case_dir out
  case_dir=$(make_case legacy-allow)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  # The default fakebin tmux answers every query with success and no output, so
  # the classifier reads the recorded window as authoritatively missing.

  out=$(run_teardown "$case_dir" --legacy-record) \
    || fail "legacy-allow: teardown refused a landed legacy record with a dead endpoint"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "legacy-allow: teardown returned success with its backlog item still open"
  printf '%s\n' "$out" | grep -Fq 'legacy record accepted without spawn_gen: endpoint missing, incarnation legacy-' \
    || fail "legacy-allow: the teardown line did not log the accepted legacy incarnation: $out"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "legacy-allow: a landed legacy close left its pending-close record behind"
  assert_absent "$case_dir/state/task-x1.meta" \
    "legacy-allow: teardown left the task record behind"
  pass "a landed legacy record with a dead endpoint tears down and logs its accepted incarnation"
}

test_legacy_record_teardown_refuses_unlanded_work() {
  local case_dir rc before
  case_dir=$(make_case legacy-unlanded)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  # Real content committed but pushed nowhere and merged nowhere.
  wt_commit_file "$case_dir" feature.txt unique-legacy-content "real unlanded work"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-unlanded: --legacy-record must not relax the unlanded-work refusal"
  grep -q REFUSED "$case_dir/stderr" \
    || fail "legacy-unlanded: no REFUSED line for unlanded legacy work"
  [ "$(legacy_meta_gen_count "$case_dir")" = 0 ] \
    || fail "legacy-unlanded: the unlanded refusal stamped a spawn generation into the record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-unlanded: the unlanded refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-unlanded: the unlanded refusal closed the backlog item anyway"
  pass "--legacy-record never relaxes the unlanded-work refusal"
}

test_legacy_record_teardown_refuses_an_ambiguous_endpoint() {
  local case_dir rc before
  case_dir=$(make_case legacy-ambiguous)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  add_unreadable_tmux "$case_dir"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-ambiguous: an unreadable endpoint must refuse the legacy acceptance"
  grep -q "not confidently dead or agent-less" "$case_dir/stderr" \
    || fail "legacy-ambiguous: the refusal did not name the endpoint state"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-ambiguous: the endpoint refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-ambiguous: the endpoint refusal closed the backlog item anyway"
  pass "an endpoint that cannot be confidently read as dead refuses --legacy-record teardown"
}

test_legacy_record_rolls_the_stamp_back_when_the_marker_write_fails() {
  local case_dir rc before
  case_dir=$(make_case legacy-stamp-rollback)
  write_legacy_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=not-a-valid-url' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" \
    "legacy-stamp-rollback: an unrecordable close must fail the teardown after accepting the legacy record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-stamp-rollback: the failed marker write left the record modified"
  grep -q "rolled back" "$case_dir/stderr" \
    || fail "legacy-stamp-rollback: the refusal did not report the rolled-back stamp"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-stamp-rollback: the failed teardown closed the backlog item anyway"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-rollback: the flag-less retry must not sail past the endpoint gate on the rolled-back record"
  grep -q -- '--legacy-record' "$case_dir/stderr2" \
    || fail "legacy-stamp-rollback: the retry refusal did not name the flag path"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-stamp-rollback: the flag-less retry modified the record"
  pass "--legacy-record teardown rolls its stamp back when the close marker write fails"
}

# Override fakebin/perl so ONLY the stamp rollback's truncate fails; every other
# perl call in the lifecycle still runs the real interpreter, so the abandoned
# attempt leaves its stamp behind for exactly the reason under test.
add_failing_truncate_perl() {
  local case_dir=$1 real
  real=$(command -v perl)
  cat > "$case_dir/fakebin/perl" <<SH
#!/usr/bin/env bash
case "\$*" in
  *truncate*) exit 1 ;;
esac
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/perl"
}

test_retained_legacy_stamp_still_faces_the_endpoint_gate() {
  local case_dir rc stamped
  case_dir=$(make_case legacy-stamp-retained)
  write_legacy_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=not-a-valid-url' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  add_failing_truncate_perl "$case_dir"

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-retained: an unrecordable close must fail the teardown after accepting the legacy record"
  grep -q "could not be rolled back" "$case_dir/stderr" \
    || fail "legacy-stamp-retained: the fixture did not exercise a failed rollback"
  [ "$(legacy_meta_gen_count "$case_dir")" = 1 ] \
    || fail "legacy-stamp-retained: the abandoned attempt did not leave its stamp on the record"
  stamped=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  # The stamp the failed rollback left behind is the whole risk: a retry must
  # not read it as an incarnation some spawn published and sail past the
  # dead-or-agent-less endpoint gate onto a reused endpoint.
  add_unreadable_tmux "$case_dir"
  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-retained: the retry must re-run the endpoint gate on the retained stamp"
  grep -q "not confidently dead or agent-less" "$case_dir/stderr2" \
    || fail "legacy-stamp-retained: the retry skipped the dead-or-agent-less endpoint gate"
  [ "$(legacy_meta_gen_count "$case_dir")" = 1 ] \
    || fail "legacy-stamp-retained: the retry stamped a second incarnation into the record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$stamped" ] \
    || fail "legacy-stamp-retained: the endpoint refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-stamp-retained: the endpoint refusal closed the backlog item anyway"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout3" 2> "$case_dir/stderr3"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-retained: a flag-less retry must refuse the retained legacy stamp"
  grep -q -- '--legacy-record' "$case_dir/stderr3" \
    || fail "legacy-stamp-retained: the flag-less refusal did not name the flag path"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$stamped" ] \
    || fail "legacy-stamp-retained: the flag-less refusal modified the task record"
  pass "a legacy stamp a failed rollback left behind still faces the endpoint gate"
}

test_legacy_record_never_accepts_a_corrupt_spawn_gen() {
  local case_dir rc
  case_dir=$(make_case legacy-corrupt)
  write_legacy_meta "$case_dir" no-mistakes ship
  printf 'spawn_gen=one\nspawn_gen=two\n' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-corrupt: an ambiguous spawn_gen must refuse even with --legacy-record"
  grep -q "unreadable spawn_gen" "$case_dir/stderr" \
    || fail "legacy-corrupt: the refusal did not name the unreadable spawn_gen"
  [ "$(legacy_meta_gen_count "$case_dir")" = 2 ] \
    || fail "legacy-corrupt: the refusal rewrote the corrupt record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-corrupt: the refusal closed the backlog item anyway"
  pass "a corrupt spawn_gen is never accepted as a legacy record"
}

test_stale_index_lock_cleared_and_teardown_succeeds() {
  local case_dir rc lock
  case_dir=$(make_case stale-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  JG_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 JG_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stale-index-lock: teardown should succeed after clearing the provably stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "stale-index-lock: stale lock file should have been removed"
  pass "provably-stale worktree index.lock (old, no live holder) is cleared and teardown succeeds"
}

test_live_index_lock_is_never_removed_and_teardown_refuses() {
  local case_dir rc lock
  case_dir=$(make_case live-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Even an old mtime must not be enough on its own: a live holder always wins.
  touch -t 200001010000 "$lock"

  set +e
  JG_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 JG_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "live-index-lock: teardown should refuse when the lock has a live holder"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "live-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "live-index-lock: teardown removed a lock with a live holder"
  [ -e "$lock" ] || fail "live-index-lock: live-held lock file was removed"
  pass "live-held worktree index.lock is never removed and teardown refuses"
}

test_lsof_error_never_clears_index_lock() {
  local case_dir rc lock
  case_dir=$(make_case lsof-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  JG_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 JG_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "lsof-error-index-lock: teardown should refuse when lsof errors"
  assert_grep "REFUSED: cannot determine leaked processes" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not report the lsof failure"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "lsof-error-index-lock: teardown removed a lock after lsof failed"
  [ -e "$lock" ] || fail "lsof-error-index-lock: lock file was removed after lsof failed"
  pass "lsof errors leave worktree index.lock in place and refuse teardown"
}

test_stale_index_lock_cleanup_rechecks_dirty_worktree() {
  local case_dir rc lock
  case_dir=$(make_case stale-lock-dirty-recheck)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt landed "landed work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' dirty > "$case_dir/wt/feature.txt"

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_git_status_lock_failure "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  JG_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 JG_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-lock-dirty-recheck: teardown should refuse dirty work after clearing the stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not report clearing the stale lock"
  assert_grep "uncommitted changes present" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not re-run the dirty check"
  assert_absent "$lock" "stale-lock-dirty-recheck: stale lock file should have been removed"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "stale-lock-dirty-recheck: teardown completed despite dirty work"
  pass "stale lock cleanup rechecks and refuses dirty worktree before return"
}

test_non_linked_index_lock_path_is_checked_from_worktree() {
  local case_dir rc lock
  case_dir=$(make_case non-linked-index-lock)
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
  git clone -q "$case_dir/origin.git" "$case_dir/wt"
  git -C "$case_dir/wt" checkout -q -b fm/task-x1
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable normal clone work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/wt" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  JG_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 JG_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "non-linked-index-lock: teardown should clear a normal repo index.lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "non-linked-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "non-linked-index-lock: stale lock file should have been removed"
  pass "normal repo index.lock is resolved from the worktree and cleared when stale"
}

test_index_lock_mtime_read_failure_refuses() {
  local case_dir rc lock
  # The mtime fault is injected by a fake stat on PATH; on Darwin the lock
  # helper now calls /usr/bin/stat directly, so the fake can never fire there.
  # Skip the Darwin run of this case.
  if [ "$(uname)" = Darwin ]; then
    pass "index-lock mtime fault injection is PATH-based; skipped on Darwin where stat is /usr/bin/stat"
    return
  fi
  case_dir=$(make_case mtime-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_stat_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  JG_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 JG_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mtime-error-index-lock: teardown should refuse when lock mtime cannot be read"
  assert_grep "cannot read mtime for git lock" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not report the mtime read failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "mtime-error-index-lock: teardown removed a lock after mtime read failed"
  [ -e "$lock" ] || fail "mtime-error-index-lock: lock file was removed after mtime read failed"
  pass "lock mtime read failures leave worktree index.lock in place and refuse teardown"
}

test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case transient-index-lock-retry)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Fresh lock: not old enough for the force-remove path; patience must win.
  touch "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  JG_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  JG_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  JG_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "transient-index-lock: teardown should succeed on retry after lock self-clears"
  assert_grep "succeeded on retry" "$case_dir/stderr" \
    "transient-index-lock: teardown did not report success on retry"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "transient-index-lock: teardown force-removed a lock that only needed patience"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "transient-index-lock: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  assert_absent "$lock" "transient-index-lock: lock should remain cleared after success"
  pass "transient index.lock cleared after first failed return is retried successfully without force-remove"
}

test_persistent_index_lock_exhausts_retries_and_refuses_loudly() {
  local case_dir rc lock
  case_dir=$(make_case persistent-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  # Fresh lock with a live holder: never provably stale, never force-removed.
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch "$lock"

  set +e
  JG_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  JG_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  JG_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "persistent-index-lock: teardown should refuse when the lock never clears"
  assert_grep "persisted across" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not mention the exhausted retry window"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "persistent-index-lock: teardown removed a non-stale lock"
  [ -e "$lock" ] || fail "persistent-index-lock: lock file was removed"
  [ -f "$case_dir/state/task-x1.meta" ] \
    || fail "persistent-index-lock: teardown completed despite persistent lock"
  pass "persistent index.lock exhausts retries and refuses without force-removing the lock"
}

test_empty_retry_wait_uses_default_without_aborting() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case empty-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  JG_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  JG_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  JG_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS='' \
  JG_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "empty-retry-wait: teardown should fall back to the default wait"
  assert_grep "waiting 1s and retrying" "$case_dir/stderr" \
    "empty-retry-wait: teardown did not use the default retry wait"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "empty-retry-wait: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  pass "empty retry wait overrides use the default without aborting teardown"
}

test_fractional_legacy_retry_wait_refuses_without_arithmetic_error() {
  local case_dir rc lock
  case_dir=$(make_case fractional-legacy-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  set +e
  JG_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  JG_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  JG_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0.1 \
  JG_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "fractional-legacy-retry-wait: teardown should fail only for the persistent lock"
  assert_grep "waiting 0.1s each" "$case_dir/stderr" \
    "fractional-legacy-retry-wait: teardown did not preserve the legacy fractional wait"
  assert_not_contains "$(cat "$case_dir/stderr")" "syntax error" \
    "fractional-legacy-retry-wait: teardown hit an arithmetic error"
  pass "fractional legacy retry wait remains supported without arithmetic"
}

test_local_only_force_overrides_unpushed() {
  local case_dir rc
  case_dir=$(make_case force-override)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "force-override: --force should bypass the unpushed-work check"
  ! grep -q REFUSED "$case_dir/stderr" || fail "force-override: REFUSED printed despite --force"
  pass "local-only worktree with unpushed work is torn down under --force (escape hatch)"
}

# Mark the case's home as a squad_lead home bound to a parent: teardown and
# jg-pr-check run with JG_HOME="$case_dir/home" so the parent-channel
# publishers resolve that binding while the task state stays in $case_dir/state.
configure_squad_lead_home() {  # <case-dir> <local|remote> [<parent-home>]
  local case_dir=$1 route=$2 parent=${3:-} home="$1/home"
  mkdir -p "$home"
  printf 'mate-x\n' > "$home/.jg-squad-lead-home"
  {
    printf 'schema=jg-squad-lead-parent.v1\nroute=%s\n' "$route"
    [ "$route" != local ] || printf 'parent_home=%s\n' "$parent"
  } > "$home/.jg-squad-lead-parent"
  if [ "$route" = local ]; then
    # A local parent registers the mate; teardown resolves that registration.
    mkdir -p "$parent/state" "$parent/data"
    jg_write_squad_lead_meta "$parent/state/mate-x.meta" "$home"
    printf -- '- mate-x - fixture scope (home: %s; scope: fixture; projects: alpha; added 2026-07-14)\n' \
      "$home" > "$parent/data/squad_leads.md"
  fi
}

# Registering a PR inside a squad_lead home publishes the child's ready line
# with the canonical URL on the parent channel from jg-pr-check itself, once;
# a main home publishes nothing.
test_squad_lead_pr_registration_publishes_ready_line() {
  local case_dir pr_head channel url
  url=https://github.com/example/repo/pull/7
  case_dir=$(make_case mate-pr-ready)
  configure_squad_lead_home "$case_dir" local "$case_dir/parent"
  mkdir -p "$case_dir/parent/state"
  channel="$case_dir/parent/state/mate-x.status"
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  JG_HOME="$case_dir/home" JG_ROOT_OVERRIDE="$ROOT" JG_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$PATH" "$PR_CHECK" task-x1 "$url" > "$case_dir/pr-check.out" 2> "$case_dir/pr-check.err" \
    || fail "mate-pr-ready: jg-pr-check failed: $(cat "$case_dir/pr-check.err")"
  grep -q '^armed:' "$case_dir/pr-check.out" || fail "mate-pr-ready: poll was not armed"
  assert_grep "done [key=child-pr-task-x1]: child task-x1 PR ready: $url mode=no-mistakes" <(sed -E 's/ \[at=[0-9]+\]//' "$channel") \
    "mate-pr-ready: the ready line did not reach the parent channel"
  ! grep -q '^actionable:' "$case_dir/pr-check.err" \
    || fail "mate-pr-ready: registration reported a channel problem: $(cat "$case_dir/pr-check.err")"
  JG_HOME="$case_dir/home" JG_ROOT_OVERRIDE="$ROOT" JG_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$PATH" "$PR_CHECK" task-x1 "$url" >/dev/null 2>&1 \
    || fail "mate-pr-ready: re-registration failed"
  [ "$(grep -c 'child-pr-task-x1' "$channel")" -eq 1 ] \
    || fail "mate-pr-ready: re-registration duplicated the ready line"

  case_dir=$(make_case main-pr-ready)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_pr_merged_for_head "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"
  JG_ROOT_OVERRIDE="$ROOT" JG_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$PATH" "$PR_CHECK" task-x1 "$url" >/dev/null 2> "$case_dir/pr-check.err" \
    || fail "main-pr-ready: jg-pr-check failed"
  ! grep -q '^actionable:' "$case_dir/pr-check.err" \
    || fail "main-pr-ready: a main home reported a channel problem"
  [ ! -e "$case_dir/state/parent-replies.status" ] || fail "main-pr-ready: a main home wrote a parent reply"
  pass "jg-pr-check publishes the PR-ready line on a squad_lead's parent channel once"
}

# A behavior script must see the same environment under a live home as in CI.
# A squad_lead launch exports the whole home-override set into every process it
# starts (bin/jg-spawn.sh), so a runner that leaves JG_PUBLIC_FOLLOWUP_PRIMARY_HOME
# in place hands a fixture teardown a foreign "live" parent to compare against
# that fixture's own durable binding, and the teardown then refuses a cleanup
# that has to succeed - a false red that depends only on who started the run.
# The launch's JG_SUPERVISION_MODEL names the live home's model, so a fixture that
# inherits it is judged by a model its own home never had (tests/jg-inbox.test.sh).
# This guards the clearance itself, in the runner that owns what a script inherits.
test_runner_clears_the_lead_launch_parent_prefix() {
  local probe_dir probe out rc
  probe_dir="$TMP_ROOT/runner-env"
  mkdir -p "$probe_dir/foreign-primary-home"
  probe="$probe_dir/probe.test.sh"
  cat > "$probe" <<'SH'
#!/usr/bin/env bash
printf 'seen=%s home=%s model=%s\n' "${JG_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}" "${JG_HOME:-}" "${JG_SUPERVISION_MODEL:-}"
SH
  out="$probe_dir/runner.out"
  rc=0
  JG_HOME="$probe_dir/live-home" \
  JG_PUBLIC_FOLLOWUP_PRIMARY_HOME="$probe_dir/foreign-primary-home" \
  JG_STATE_OVERRIDE="$probe_dir/live-state" \
  JG_SUPERVISION_MODEL=autoarm \
    "$ROOT/bin/jg-test-run.sh" "$probe" > "$out" 2>&1 || rc=$?
  expect_code 0 "$rc" "runner-env: the runner should still report a green probe: $(cat "$out")"
  grep -qxF "seen= home= model=" "$out" \
    || fail "runner-env: the lead-launch parent prefix reached the test script: $(cat "$out")"
  pass "the test runner clears a squad_lead launch's parent-home prefix"
}

# Tearing a child down inside a squad_lead home delivers the child's final
# ledger line to the parent before the record goes, and refuses (retaining
# every record) while the parent channel cannot be written; a rerun after the
# repair delivers and completes.
test_squad_lead_home_teardown_delivers_final_line_or_refuses() {
  local case_dir rc channel wt_head err seq generation

  case_dir=$(make_case mate-teardown-delivers)
  configure_squad_lead_home "$case_dir" local "$case_dir/parent"
  mkdir -p "$case_dir/parent/state"
  channel="$case_dir/parent/state/mate-x.status"
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  printf 'working: shipping\ndone: PR https://github.com/example/repo/pull/9 checks green\n' \
    > "$case_dir/state/task-x1.status"
  set +e
  JG_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "mate-teardown-delivers: teardown should succeed: $(cat "$case_dir/stderr")"
  sed -E 's/ \[at=[0-9]+\]//' "$channel" | grep -Eq '^done \[key=child-outcome-task-x1-done-[0-9a-f]{8}\]: child task-x1 done: PR https://github.com/example/repo/pull/9 checks green pr=https://github.com/example/repo/pull/9 mode=local-only$' \
    || fail "mate-teardown-delivers: the final ledger line did not reach the parent: $(cat "$channel" 2>/dev/null)"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "mate-teardown-delivers: teardown left the task record"

  case_dir=$(make_case mate-teardown-refuses)
  configure_squad_lead_home "$case_dir" local "$case_dir/parent"
  # The channel path is occupied by a directory, so no line can be appended.
  mkdir -p "$case_dir/parent/state/mate-x.status"
  channel="$case_dir/parent/state/mate-x.status"
  write_meta "$case_dir" local-only ship
  mkdir -p "$case_dir/tasktmp"
  printf '!\n' > "$case_dir/state/task-x1.grok-turnend-token"
  printf '!\n' > "$case_dir/state/task-x1.kimi-turnend-token"
  printf 'tasktmp=%s\n' "$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
  wt_commit "$case_dir" "merged work"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  printf 'done: PR https://github.com/example/repo/pull/9 checks green\n' > "$case_dir/state/task-x1.status"
  set +e
  JG_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "mate-teardown-refuses: teardown proceeded with an undelivered final line"
  grep -q 'has not reached the parent channel' "$case_dir/stderr" \
    || fail "mate-teardown-refuses: refusal did not name the parent channel: $(cat "$case_dir/stderr")"
  [ -f "$case_dir/state/task-x1.meta" ] && [ -f "$case_dir/state/task-x1.status" ] \
    || fail "mate-teardown-refuses: refusal did not retain the task records"
  [ -f "$case_dir/state/task-x1.grok-turnend-token" ] \
    && [ -f "$case_dir/state/task-x1.kimi-turnend-token" ] \
    && [ -d "$case_dir/tasktmp" ] \
    || fail "mate-teardown-refuses: refusal removed endpoint records before parent delivery"
  rmdir "$channel"
  err=$(JG_HOME="$case_dir/home" JG_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/jg-wake-drain.sh" 2>&1 >/dev/null)
  seq=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p')
  generation=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p')
  [ -z "$seq" ] || JG_HOME="$case_dir/home" JG_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/jg-wake-drain.sh" --ack-through "$seq" --recovery-generation "$generation" >/dev/null
  set +e
  JG_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 0 "$rc" "mate-teardown-refuses: rerun after repair should succeed: $(cat "$case_dir/stderr2")"
  sed -E 's/ \[at=[0-9]+\]//' "$channel" | grep -Eq '^done \[key=child-outcome-task-x1-done-[0-9a-f]{8}\]: child task-x1 done: PR https://github.com/example/repo/pull/9 checks green' \
    || fail "mate-teardown-refuses: the rerun did not deliver the final line"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "mate-teardown-refuses: rerun left the task record"
  pass "a squad_lead home's teardown delivers the child's final line or refuses until it can"
}

test_teardown_missing_busy_sidecar_completes() {
  local case_dir gen rc
  case_dir=$(make_case missing-busy-sidecar)
  write_meta "$case_dir" local-only ship
  gen=$("$ROOT/bin/jg-busy-event.sh" arm "$case_dir/state" task-x1)
  printf 'busy_gen=%s\n' "$gen" >> "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.busy-gen"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "missing-busy-sidecar: teardown should treat the incarnation as already retired"
  assert_absent "$case_dir/state/task-x1.busy-state" \
    "missing-busy-sidecar: teardown left the orphan busy record"
  assert_absent "$case_dir/state/task-x1.meta" \
    "missing-busy-sidecar: teardown remained incomplete"
  pass "teardown completes when an exact busy-state sidecar is already absent"
}

test_herdr_teardown_clears_escalation_marker() {
  local case_dir marker
  case_dir=$(make_case herdr-marker-cleanup)
  write_meta "$case_dir" local-only ship
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_tab_id=wG:tQ' \
    'herdr_pane_id=wG:pQ' >> "$case_dir/state/task-x1.meta"
  # A reachable session whose exact pane is already structurally gone: the
  # locked close is a no-op and the record gate sees a confirmed-gone pane.
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "session list") printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}' ;;
  "status --json") printf '%s\n' '{"server":{"running":true}}' ;;
  "pane get") printf '%s\n' '{"error":{"code":"pane_not_found"}}'; exit 1 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
  marker="$case_dir/state/.herdr-escalated-default_wG_pQ"
  : > "$marker"

  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-marker-cleanup: forced teardown failed: $(cat "$case_dir/stderr")"
  [ ! -e "$marker" ] || fail "herdr-marker-cleanup: teardown left the pane's escalation marker behind"
  pass "herdr teardown removes pane-owned escalation dedupe state"
}

# Flat (non-projected) Herdr endpoint whose fake pane exists until a locked
# close removes it. The socket path is case-local so the derived presentation
# lock never collides with another test or a real fleet session.
configure_flat_herdr_teardown_case() {  # <case-dir>
  local case_dir=$1
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_tab_id=wG:tQ' \
    'herdr_pane_id=wG:pQ' >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${JG_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"wH","active_tab_id":"wH:t1","focused":true},{"workspace_id":"wG","active_tab_id":"wG:tQ","focused":false}]}}'
    ;;
  "tab list")
    case "\$*" in
      *"--workspace wH"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"wH:t1","focused":true}]}}' ;;
      *"--workspace wG"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"wG:tQ","workspace_id":"wG"}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"wG:pQ","tab_id":"wG:tQ"}]}}'
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    if [ "\${JG_FAKE_HERDR_SESSION_LIST_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}'
    fi
    ;;
  "pane close")
    : > "\${JG_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    if [ "\${JG_FAKE_HERDR_PANE_GET_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
      exit 0
    fi
    if [ -e "\${JG_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"wG:pQ","tab_id":"wG:tQ","workspace_id":"wG"}}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_herdr_flat_teardown_refuses_orphaning_records_then_retry_completes() {
  local case_dir log closed lock ready release holder_pid rc thlog
  case_dir=$(make_case herdr-orphan-refusal)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  # Record every treehouse invocation: the contended-lock refusal must fire
  # BEFORE the isolated copy is returned, so phase 1 may not invoke it at all.
  thlog="$case_dir/treehouse.log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  lock=$(JG_FAKE_HERDR_LOG="$log" JG_FAKE_HERDR_CLOSED="$closed" PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$0/bin/backends/herdr.sh"; jg_backend_herdr_presentation_session_lock_path default' "$ROOT") \
    || fail "herdr-orphan-refusal: could not resolve the fixture presentation lock path"
  ready="$case_dir/lock-ready"; release="$case_dir/lock-release"
  ROOT="$ROOT" LOCK="$lock" READY="$ready" RELEASE="$release" bash -c '
    . "$ROOT/bin/jg-wake-lib.sh"
    jg_lock_try_acquire "$LOCK" || exit 1
    : > "$READY"
    while [ ! -e "$RELEASE" ]; do sleep 0.1; done
    jg_lock_release "$LOCK"
  ' &
  holder_pid=$!
  local waited=0
  while [ ! -e "$ready" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ -e "$ready" ] || fail "herdr-orphan-refusal: the contending lock holder never started"

  rc=0
  JG_FAKE_HERDR_LOG="$log" JG_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if [ "$rc" -eq 0 ]; then
    : > "$release"; wait "$holder_pid" 2>/dev/null || true
    fail "herdr-orphan-refusal: teardown reported success while the exact pane still existed under lock contention"
  fi
  [ -e "$case_dir/state/task-x1.meta" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the durable endpoint metadata"; }
  [ -e "$case_dir/state/task-x1.status" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the task status record"; }
  [ -e "$case_dir/state/task-x1.turn-ended" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the turn-end record"; }
  assert_grep "presentation lock is contended" "$case_dir/stderr" \
    "herdr-orphan-refusal: the pre-return refusal was not explained visibly"
  if [ -s "$thlog" ]; then
    : > "$release"; fail "herdr-orphan-refusal: the contended refusal still returned the isolated copy: $(cat "$thlog")"
  fi
  [ -d "$case_dir/wt" ] || { : > "$release"; fail "herdr-orphan-refusal: the contended refusal removed the isolated copy"; }
  if [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "fm/task-x1" ]; then
    : > "$release"; fail "herdr-orphan-refusal: the contended refusal dropped the task branch before refusing"
  fi
  if grep -q "teardown task-x1 complete" "$case_dir/stdout"; then
    : > "$release"; fail "herdr-orphan-refusal: refusal still reported cleanup complete"
  fi
  if grep -q "^pane close" "$log"; then
    : > "$release"; fail "herdr-orphan-refusal: an unlocked pane close was attempted under contention"
  fi

  : > "$release"
  wait "$holder_pid" 2>/dev/null || true
  JG_FAKE_HERDR_LOG="$log" JG_FAKE_HERDR_CLOSED="$closed" JG_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout2" 2> "$case_dir/stderr2" \
    || fail "herdr-orphan-refusal: the retry after lock release failed: $(cat "$case_dir/stderr2")"
  [ -e "$closed" ] || fail "herdr-orphan-refusal: the retry never closed the pane under the lock"
  [ -s "$thlog" ] || fail "herdr-orphan-refusal: the successful retry never returned the isolated copy"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "herdr-orphan-refusal: the successful retry left the metadata behind"
  [ ! -e "$case_dir/state/task-x1.status" ] || fail "herdr-orphan-refusal: the successful retry left the status record behind"
  grep -q "teardown task-x1 complete" "$case_dir/stdout2" \
    || fail "herdr-orphan-refusal: the successful retry did not report completion"
  pass "herdr flat teardown refuses before returning the isolated copy under lock contention and the retry completes cleanly"
}

test_herdr_flat_teardown_refuses_records_on_unparseable_presence() {
  local case_dir log closed rc
  case_dir=$(make_case herdr-garbage-presence)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  rc=0
  JG_FAKE_HERDR_LOG="$log" JG_FAKE_HERDR_CLOSED="$closed" JG_FAKE_HERDR_PANE_GET_GARBAGE=1 \
    JG_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-garbage-presence: teardown erased records on an unparseable pane presence"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-garbage-presence: ambiguous presence erased the durable endpoint metadata"
  [ -e "$case_dir/state/task-x1.status" ] \
    || fail "herdr-garbage-presence: ambiguous presence erased the task status record"
  assert_grep "ambiguous structured presence" "$case_dir/stderr" \
    "herdr-garbage-presence: the ambiguity refusal was not explained visibly"
  pass "herdr flat teardown never erases records when pane presence is unparseable"
}

assert_herdr_teardown_preflight_refuses_before_changes() {
  local mode=$1 case_dir log closed rc thlog teardown_bin
  case_dir=$(make_case "herdr-preflight-$mode")
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  thlog="$case_dir/treehouse.log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  teardown_bin=$TEARDOWN
  case "$mode" in
    missing-adapter|missing-parser|missing-explicit-close-helper)
      mkdir -p "$case_dir/test-root"
      cp -R "$ROOT/bin" "$case_dir/test-root/bin"
      cp "$ROOT/toolchain.versions" "$case_dir/test-root/toolchain.versions"
      if [ "$mode" = missing-adapter ]; then
        rm -f "$case_dir/test-root/bin/backends/herdr.sh"
      elif [ "$mode" = missing-explicit-close-helper ]; then
        sed -i.bak 's/^jg_backend_herdr_explicit_close_pane_confirmed()/jg_backend_herdr_explicit_close_pane_confirmed_unavailable()/' \
          "$case_dir/test-root/bin/backends/herdr.sh"
        rm -f "$case_dir/test-root/bin/backends/herdr.sh.bak"
      else
        sed -i.bak 's/^jg_backend_herdr_parse_target()/jg_backend_herdr_parse_target_unavailable()/' \
          "$case_dir/test-root/bin/backends/herdr.sh"
        rm -f "$case_dir/test-root/bin/backends/herdr.sh.bak"
      fi
      teardown_bin="$case_dir/test-root/bin/jg-teardown.sh"
      ;;
  esac
  rc=0
  JG_ROOT_OVERRIDE="$ROOT" JG_STATE_OVERRIDE="$case_dir/state" JG_DATA_OVERRIDE="$case_dir/data" \
    JG_CONFIG_OVERRIDE="$case_dir/config" JG_FAKE_HERDR_LOG="$log" JG_FAKE_HERDR_CLOSED="$closed" \
    JG_FAKE_HERDR_SESSION_LIST_GARBAGE="$([ "$mode" = unresolvable-lock ] && printf 1 || printf 0)" \
    PATH="$case_dir/fakebin:$PATH" \
    "$teardown_bin" task-x1 --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-preflight-$mode: teardown continued without its required preflight"
  assert_grep "nothing was changed" "$case_dir/stderr" \
    "herdr-preflight-$mode: the retryable pre-return refusal was not explained visibly"
  [ -d "$case_dir/wt" ] || fail "herdr-preflight-$mode: refusal removed the isolated copy"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "fm/task-x1" ] \
    || fail "herdr-preflight-$mode: refusal dropped the task branch"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-preflight-$mode: refusal erased the durable endpoint metadata"
  [ -e "$case_dir/state/task-x1.status" ] \
    || fail "herdr-preflight-$mode: refusal erased the task status record"
  [ -e "$case_dir/state/task-x1.turn-ended" ] \
    || fail "herdr-preflight-$mode: refusal erased the turn-end record"
  [ ! -s "$thlog" ] || fail "herdr-preflight-$mode: refusal returned the isolated copy"
  [ ! -e "$closed" ] || fail "herdr-preflight-$mode: refusal attempted an unlocked pane close"
}

test_herdr_flat_teardown_preflight_refuses_before_changes() {
  assert_herdr_teardown_preflight_refuses_before_changes unresolvable-lock
  assert_herdr_teardown_preflight_refuses_before_changes missing-adapter
  assert_herdr_teardown_preflight_refuses_before_changes missing-parser
  assert_herdr_teardown_preflight_refuses_before_changes missing-explicit-close-helper
  pass "herdr flat teardown preflight refuses before every destructive change"
}

# The Herdr presentation-lock namespace is named per OS account. These cases
# act as a fixture account uid (via an `id -u` shim) so they never touch the
# real account's namespace or the old shared /tmp/juggernaut-herdr-presentation,
# and every directory the fixture account resolves is really owned by the
# running account, i.e. by another uid from the fixture account's view.
# JG_FAKE_NS_STAT names one path whose owner and mode the `stat` shim reports
# instead; the adapter reads ownership through a PATH `stat` only on its non-
# Darwin branch, so the arms that need it run only there.
herdr_lock_ns_fake_uid() {
  printf '%s' "$((3000000000 + $$ % 1000000))"
}

configure_herdr_lock_ns_shims() {  # <case-dir>
  local case_dir=$1 real_id real_stat
  real_id=$(command -v id); real_stat=$(command -v stat)
  cat > "$case_dir/fakebin/id" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -u ] && [ "\$#" -eq 1 ] && [ -n "\${JG_FAKE_ACCOUNT_UID:-}" ]; then
  printf '%s\n' "\$JG_FAKE_ACCOUNT_UID"
  exit 0
fi
exec "$real_id" "\$@"
SH
  cat > "$case_dir/fakebin/stat" <<SH
#!/usr/bin/env bash
if [ "\$#" -eq 3 ] && [ "\$1" = -c ] && [ -n "\${JG_FAKE_NS_STAT:-}" ] \\
  && [ "\$3" = "\${JG_FAKE_NS_STAT%%:*}" ]; then
  rest=\${JG_FAKE_NS_STAT#*:}
  case "\$2" in
    %u) printf '%s\n' "\${rest%%:*}"; exit 0 ;;
    %a) printf '%s\n' "\${rest#*:}"; exit 0 ;;
  esac
fi
exec "$real_stat" "\$@"
SH
  chmod +x "$case_dir/fakebin/id" "$case_dir/fakebin/stat"
}

herdr_lock_ns_path_state() {  # <path>
  if [ -e "$1" ] || [ -L "$1" ]; then
    # A fixed, known path: ls is the portable way to read mode and numeric owner.
    # shellcheck disable=SC2012
    ls -ldn "$1" 2>/dev/null | awk '{print $1, $3, $4}'
  else
    printf 'absent'
  fi
}

run_herdr_lock_ns_teardown() {  # <case-dir> <fake-uid> [stat-spec]
  local case_dir=$1 fake_uid=$2 stat_spec=${3:-} rc=0
  JG_FAKE_ACCOUNT_UID="$fake_uid" JG_FAKE_NS_STAT="$stat_spec" \
    JG_FAKE_HERDR_LOG="$case_dir/herdr.log" JG_FAKE_HERDR_CLOSED="$case_dir/closed" \
    JG_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  return "$rc"
}

new_herdr_lock_ns_case() {  # <name>
  local case_dir
  case_dir=$(make_case "$1")
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  configure_herdr_lock_ns_shims "$case_dir"
  : > "$case_dir/herdr.log"
  : > "$case_dir/state/task-x1.status"
  printf '%s' "$case_dir"
}

assert_herdr_lock_ns_refused() {  # <case-dir> <label>
  local case_dir=$1 label=$2
  assert_grep "presentation lock could not be resolved" "$case_dir/stderr" \
    "$label: the namespace refusal was not explained visibly"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "$label: refusal erased the durable endpoint metadata"
  [ -d "$case_dir/wt" ] || fail "$label: refusal removed the isolated copy"
  [ ! -e "$case_dir/closed" ] || fail "$label: refusal attempted a pane close without the lock"
}

test_herdr_teardown_presentation_lock_namespace_is_per_account() {
  local fake_uid own_ns legacy legacy_before legacy_after own_before case_dir rc lock linux_arms=0
  fake_uid=$(herdr_lock_ns_fake_uid)
  [ "$fake_uid" != "$(id -u)" ] || fail "herdr-lock-ns: fixture account uid collides with the running account"
  own_ns="/tmp/juggernaut-herdr-presentation-$fake_uid"
  legacy=/tmp/juggernaut-herdr-presentation
  [ ! -e "$own_ns" ] && [ ! -L "$own_ns" ] \
    || fail "herdr-lock-ns: fixture namespace $own_ns already exists; refusing to reuse it"
  printf '%s\n' "$own_ns" >> "$JG_TEST_CLEANUP_REGISTRY"
  mkdir -m 700 "$own_ns" || fail "herdr-lock-ns: could not stage $own_ns"
  legacy_before=$(herdr_lock_ns_path_state "$legacy")

  # This account's own name, really owned by another uid, is still refused and
  # is left exactly as it was.
  own_before=$(herdr_lock_ns_path_state "$own_ns")
  case_dir=$(new_herdr_lock_ns_case herdr-lock-ns-foreign-owner)
  rc=0; run_herdr_lock_ns_teardown "$case_dir" "$fake_uid" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-lock-ns-foreign-owner: teardown adopted a namespace another uid owns"
  assert_herdr_lock_ns_refused "$case_dir" herdr-lock-ns-foreign-owner
  [ "$(herdr_lock_ns_path_state "$own_ns")" = "$own_before" ] \
    || fail "herdr-lock-ns-foreign-owner: refusal changed the foreign-owned namespace: $(herdr_lock_ns_path_state "$own_ns")"

  if [ "$(uname -s)" != Darwin ]; then
    linux_arms=1
    # The old shared name is owned by another uid whenever it exists here, as
    # on a host where a second account created it first; this account's
    # teardown no longer consults it and completes in its own namespace.
    case_dir=$(new_herdr_lock_ns_case herdr-lock-ns-other-account)
    run_herdr_lock_ns_teardown "$case_dir" "$fake_uid" "$own_ns:$fake_uid:700" \
      || fail "herdr-lock-ns-other-account: teardown was blocked: $(cat "$case_dir/stderr")"
    [ -e "$case_dir/closed" ] || fail "herdr-lock-ns-other-account: the pane was not closed under the lock"
    [ ! -e "$case_dir/state/task-x1.meta" ] || fail "herdr-lock-ns-other-account: teardown left the metadata behind"
    grep -q "teardown task-x1 complete" "$case_dir/stdout" \
      || fail "herdr-lock-ns-other-account: teardown did not report completion"
    lock=$(JG_FAKE_ACCOUNT_UID="$fake_uid" JG_FAKE_NS_STAT="$own_ns:$fake_uid:700" \
      JG_FAKE_HERDR_LOG="$case_dir/herdr.log" JG_FAKE_HERDR_CLOSED="$case_dir/closed" \
      PATH="$case_dir/fakebin:$PATH" \
      bash -c '. "$0/bin/backends/herdr.sh"; jg_backend_herdr_presentation_session_lock_path default' "$ROOT") \
      || fail "herdr-lock-ns-other-account: could not resolve the fixture account's lock path"
    case "$lock" in
      "$own_ns"/order-*.lock) ;;
      *) fail "herdr-lock-ns-other-account: the lock is not in this account's namespace: $lock" ;;
    esac

    # This account's own name with the right owner but the wrong mode is refused.
    case_dir=$(new_herdr_lock_ns_case herdr-lock-ns-wrong-mode)
    rc=0; run_herdr_lock_ns_teardown "$case_dir" "$fake_uid" "$own_ns:$fake_uid:755" || rc=$?
    [ "$rc" -ne 0 ] || fail "herdr-lock-ns-wrong-mode: teardown adopted a namespace that is not mode 700"
    assert_herdr_lock_ns_refused "$case_dir" herdr-lock-ns-wrong-mode
    [ -d "$own_ns" ] || fail "herdr-lock-ns-wrong-mode: refusal removed the namespace"
  fi

  legacy_after=$(herdr_lock_ns_path_state "$legacy")
  [ "$legacy_after" = "$legacy_before" ] \
    || fail "herdr-lock-ns: teardown changed the old shared namespace: $legacy_before -> $legacy_after"
  rm -rf "$own_ns"
  if [ "$linux_arms" = 1 ]; then
    pass "herdr teardown takes its lock in a per-account namespace another account cannot block, and still refuses a foreign-owned or wrong-mode one"
  else
    pass "herdr teardown refuses a foreign-owned per-account namespace (owner-shim arms need the non-Darwin stat branch; skipped on Darwin)"
  fi
}

configure_squad_lead_with_herdr_child() {  # <case-dir>
  local case_dir=$1 home="$1/squad-lead-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.jg-squad-lead-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  jg_write_meta "$home/state/child-herdr.meta" \
    "window=childsession:wC:p1" \
    "endpoint_task_id=child-herdr" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "backend=herdr" \
    "herdr_session=childsession" \
    "herdr_workspace_id=wC" \
    "herdr_tab_id=wC:t1" \
    "herdr_pane_id=wC:p1"
  : > "$home/state/child-herdr.status"
  : > "$home/state/child-herdr.turn-ended"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${JG_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "session list")
    if [ "\${JG_FAKE_HERDR_SESSION_LIST_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"sessions":[{"name":"childsession","running":true,"socket_path":"$case_dir/child.sock"}]}'
    fi
    ;;
  "workspace list") exit 1 ;;
  "pane get")
    if [ -e "\${JG_FAKE_HERDR_CLOSED:?}" ]; then
      if [ "\${JG_FAKE_HERDR_PRESENCE_UNKNOWN:-0}" = 1 ]; then
        printf '%s\n' 'not-json'
      else
        printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
        exit 1
      fi
    else
      printf '%s\n' '{"result":{"pane":{"pane_id":"wC:p1","tab_id":"wC:t1","workspace_id":"wC"}}}'
    fi
    ;;
  "pane close") : > "\${JG_FAKE_HERDR_CLOSED:?}" ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_forced_squad_lead_herdr_child_preflight_refuses_before_changes() {
  local case_dir home log closed rc thlog
  case_dir=$(make_case herdr-child-preflight)
  write_meta "$case_dir" local-only squad_lead
  configure_squad_lead_with_herdr_child "$case_dir"
  home="$case_dir/squad-lead-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; thlog="$case_dir/treehouse.log"
  : > "$log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  rc=0
  JG_FAKE_HERDR_LOG="$log" JG_FAKE_HERDR_CLOSED="$closed" \
    JG_FAKE_HERDR_SESSION_LIST_GARBAGE=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-child-preflight: teardown continued through an unresolvable child lock"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "herdr-child-preflight: refusal erased the parent record"
  [ -e "$home/state/child-herdr.meta" ] || fail "herdr-child-preflight: refusal erased the child record"
  [ -e "$home/state/child-herdr.status" ] || fail "herdr-child-preflight: refusal erased child status"
  [ -d "$home" ] || fail "herdr-child-preflight: refusal removed the squad_lead home"
  [ ! -s "$thlog" ] || fail "herdr-child-preflight: refusal returned work before child preflight"
  [ ! -e "$closed" ] || fail "herdr-child-preflight: refusal attempted a child close"
  assert_grep "nothing was changed" "$case_dir/stderr" \
    "herdr-child-preflight: refusal did not explain its non-mutating boundary"
  pass "forced squad_lead teardown preflights every Herdr child before cleanup mutation"
}

configure_squad_lead_with_tmux_children() {  # <case-dir>
  local case_dir=$1 home="$1/squad-lead-home" child child_wt
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.jg-squad-lead-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  for child in child-a child-b; do
    child_wt="$case_dir/$child-wt"
    git -C "$case_dir/project" worktree add -q -b "fm/$child" "$child_wt" main
    jg_write_meta "$home/state/$child.meta" \
      "window=juggernaut:jg-$child" \
      "endpoint_task_id=$child" \
      "worktree=$child_wt" \
      "project=$case_dir/project" \
      "kind=ship" \
      "mode=local-only"
    : > "$home/state/$child.status"
  done
}

test_forced_squad_lead_teardown_holds_descendant_lifecycle_locks() {
  local case_dir home lock ready release holder_pid rc waited=0 child
  case_dir=$(make_case descendant-locks)
  write_meta "$case_dir" local-only squad_lead
  configure_squad_lead_with_tmux_children "$case_dir"
  home="$case_dir/squad-lead-home"
  : > "$case_dir/kill.log"
  : > "$case_dir/treehouse.log"
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/kill.log"
exit 0
SH
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux" "$case_dir/fakebin/treehouse"

  lock="$home/state/.control-child-b.lock"
  ready="$case_dir/lock-ready"
  release="$case_dir/lock-release"
  ROOT="$ROOT" LOCK="$lock" READY="$ready" RELEASE="$release" \
    HOME_STATE="$home/state" OWNER_PID="$$" bash -c '
    export JG_STATE_OVERRIDE="$HOME_STATE"
    . "$ROOT/bin/jg-wake-lib.sh"
    jg_lock_try_acquire "$LOCK" || exit 1
    : > "$READY"
    while [ ! -e "$RELEASE" ] && kill -0 "$OWNER_PID" 2>/dev/null; do sleep 0.1; done
    jg_lock_release "$LOCK"
  ' &
  holder_pid=$!
  while [ ! -e "$ready" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$ready" ] || fail "descendant-locks: the contending lifecycle action never acquired its lock"

  rc=0
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if [ "$rc" -eq 0 ]; then
    : > "$release"
    wait "$holder_pid" 2>/dev/null || true
    fail "descendant-locks: forced teardown ignored a descendant lifecycle lock"
  fi
  assert_grep "descendant task child-b has a lifecycle action in flight" "$case_dir/stderr" \
    "descendant-locks: refusal did not name the contended descendant"
  [ ! -e "$home/state/.control-child-a.lock" ] \
    && [ ! -e "$home/state/.meta-child-a.lock" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal leaked earlier descendant locks"; }
  [ ! -s "$case_dir/kill.log" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal killed an endpoint"; }
  [ ! -s "$case_dir/treehouse.log" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal returned a worktree"; }
  [ -e "$case_dir/state/task-x1.meta" ] && [ -d "$home" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal removed parent state"; }
  for child in child-a child-b; do
    [ -e "$home/state/$child.meta" ] && [ -d "$case_dir/$child-wt" ] \
      || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal removed $child state or worktree"; }
  done

  : > "$release"
  wait "$holder_pid" 2>/dev/null || true
  rc=0
  run_teardown "$case_dir" --force > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
  expect_code 0 "$rc" "descendant-locks: uncontended retry should complete"
  [ ! -e "$case_dir/state/task-x1.meta" ] && [ ! -d "$home" ] \
    || fail "descendant-locks: uncontended retry retained retired task state"
  [ -s "$case_dir/kill.log" ] && [ -s "$case_dir/treehouse.log" ] \
    || fail "descendant-locks: uncontended retry did not perform endpoint and worktree cleanup"
  pass "forced squad_lead teardown holds every descendant lifecycle and metadata lock"
}

test_forced_squad_lead_herdr_child_retains_records_when_close_unconfirmed() {
  local case_dir home log closed rc
  case_dir=$(make_case herdr-child-unconfirmed-close)
  write_meta "$case_dir" local-only squad_lead
  configure_squad_lead_with_herdr_child "$case_dir"
  home="$case_dir/squad-lead-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"
  rc=0
  JG_FAKE_HERDR_LOG="$log" JG_FAKE_HERDR_CLOSED="$closed" JG_FAKE_HERDR_PRESENCE_UNKNOWN=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-child-unconfirmed-close: teardown erased records after an ambiguous close"
  [ -e "$closed" ] || fail "herdr-child-unconfirmed-close: fixture did not attempt the child close"
  [ -e "$home/state/child-herdr.meta" ] || fail "herdr-child-unconfirmed-close: ambiguous close erased child metadata"
  [ -e "$home/state/child-herdr.status" ] || fail "herdr-child-unconfirmed-close: ambiguous close erased child status"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "herdr-child-unconfirmed-close: failed child cleanup erased parent metadata"
  [ -d "$home" ] || fail "herdr-child-unconfirmed-close: failed child cleanup removed the squad_lead home"
  assert_grep "retaining that child's durable identity records" "$case_dir/stderr" \
    "herdr-child-unconfirmed-close: refusal did not explain child record retention"
  pass "forced squad_lead teardown retains Herdr child identity until exact pane disappearance"
}

configure_nested_squad_lead_with_herdr_grandchild() {  # <case-dir>
  local case_dir=$1 home="$1/squad-lead-home" nested_home="$1/squad-lead-home/nested-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  mkdir -p "$nested_home/state" "$nested_home/data" "$nested_home/config" "$nested_home/projects"
  printf '%s\n' task-x1 > "$home/.jg-squad-lead-home"
  printf '%s\n' nested-sm > "$nested_home/.jg-squad-lead-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  jg_write_meta "$home/state/nested-sm.meta" \
    "window=juggernaut:jg-nested-sm" \
    "endpoint_task_id=nested-sm" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=squad_lead" \
    "mode=local-only" \
    "home=$nested_home"
  jg_write_meta "$nested_home/state/grandchild-herdr.meta" \
    "window=grandchildsession:wG:p1" \
    "endpoint_task_id=grandchild-herdr" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "backend=herdr" \
    "herdr_session=grandchildsession" \
    "herdr_workspace_id=wG" \
    "herdr_tab_id=wG:t1" \
    "herdr_pane_id=wG:p1"
  : > "$nested_home/state/grandchild-herdr.status"
  : > "$nested_home/state/grandchild-herdr.turn-ended"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${JG_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "session list")
    printf '%s\n' '{"sessions":[{"name":"grandchildsession","running":true,"socket_path":"$case_dir/grandchild.sock"}]}'
    ;;
  "workspace list") exit 1 ;;
  "pane get")
    if [ -e "\${JG_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"result":{"pane":{"pane_id":"wG:p1","tab_id":"wG:t1","workspace_id":"wG"}}}'
    fi
    ;;
  "pane close") : > "\${JG_FAKE_HERDR_CLOSED:?}" ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_forced_teardown_retains_nested_squad_lead_home_when_grandchild_close_unconfirmed() {
  local case_dir home nested_home log closed rc
  case_dir=$(make_case herdr-grandchild-unconfirmed-close)
  write_meta "$case_dir" local-only squad_lead
  configure_nested_squad_lead_with_herdr_grandchild "$case_dir"
  home="$case_dir/squad-lead-home"; nested_home="$home/nested-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"
  rc=0
  JG_FAKE_HERDR_LOG="$log" JG_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-grandchild-unconfirmed-close: teardown erased records after an ambiguous grandchild close"
  [ -e "$closed" ] \
    || fail "herdr-grandchild-unconfirmed-close: fixture did not attempt the grandchild close"
  [ -d "$nested_home" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure still removed the nested squad_lead home"
  [ -e "$nested_home/state/grandchild-herdr.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: ambiguous close erased the grandchild's metadata"
  [ -e "$nested_home/state/grandchild-herdr.status" ] \
    || fail "herdr-grandchild-unconfirmed-close: ambiguous close erased the grandchild's status record"
  [ -e "$home/state/nested-sm.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure erased the nested squad_lead's own record"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure erased the top-level squad_lead's record"
  pass "forced teardown retains a nested squad_lead home and its grandchild's Herdr identity when the grandchild close is unconfirmed"
}

configure_herdr_projection_teardown_case() {  # <case-dir>
  local case_dir=$1 token=AbCdEfGhIjKlMnOpQrStUv
  sed -i.bak 's/^window=.*/window=fmtest:w1:p2/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=fmtest' \
    'herdr_workspace_id=w1' \
    'herdr_tab_id=w1:t2' \
    'herdr_pane_id=w1:p2' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' \
    'version=1' \
    'task_id=task-x1' \
    "projection_id=$token" > "$case_dir/state/task-x1.herdr-presentation"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${JG_FAKE_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace list")
    if [ -e "${JG_FAKE_HERDR_RESTORED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    elif [ -e "${JG_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":true}]}}'
    else
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t2","label":"juggernaut/task-x1 · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    fi
    ;;
  "tab list")
    case "$*" in
      *"--workspace w2"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","focused":true}]}}' ;;
      *"--workspace w3"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w3:t1","focused":true}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}'
    ;;
  "pane close")
    if [ "${JG_FAKE_HERDR_CLOSE_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    : > "${JG_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    if [ -e "${JG_FAKE_HERDR_CLOSED:?}" ]; then
      if [ "${JG_FAKE_HERDR_PRESENCE_UNKNOWN:-0}" = 1 ]; then
        printf '%s\n' '{"error":{"code":"internal"}}' >&2
        exit 1
      fi
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1"}}}'
    ;;
  "tab get")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2"}}}'
    ;;
  "tab focus")
    if [ "${JG_FAKE_HERDR_RESTORE_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    : > "${JG_FAKE_HERDR_RESTORED:?}"
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2","focused":true}}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_herdr_projection_teardown_retires_journal_only_after_confirmed_close() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-confirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"
  # A leased cd puts the top-level shell in the copy. Returning it can end
  # that pane before the adapter gets a chance to preserve the original focus.
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != return ] || : > "${JG_FAKE_HERDR_CLOSED:?}"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  JG_FAKE_HERDR_LOG="$log" JG_FAKE_HERDR_CLOSED="$closed" JG_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-confirmed-close: forced teardown failed"
  [ ! -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "confirmed exact-pane close did not retire the presentation journal"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "projected teardown must never call workspace close"
  assert_contains "$(cat "$log")" "tab focus w2:t2" \
    "projected teardown did not restore the exact pre-close active tab"
  pass "herdr projection teardown retires its journal only after confirming the exact recorded pane is gone"
}

test_herdr_projection_teardown_retains_journal_when_close_unconfirmed() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-unconfirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  seed_backlog_in_flight "$case_dir"
  mkdir -p "$case_dir/scratch/proof"
  JG_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/jg-scratch.sh" register task-x1 "$case_dir/scratch/proof" >/dev/null \
    || fail "scratch registration failed"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  local rc=0
  JG_FAKE_HERDR_LOG="$log" JG_FAKE_HERDR_CLOSED="$closed" JG_FAKE_HERDR_RESTORED="$restored" JG_FAKE_HERDR_PRESENCE_UNKNOWN=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-projection-unconfirmed-close: teardown reported success after an unknown post-close presence read"
  [ -e "$closed" ] \
    || fail "herdr-projection-unconfirmed-close: regression did not exercise an attempted close"
  [ -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "unconfirmed task-pane close incorrectly retired the presentation journal"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "unconfirmed task-pane close erased the durable endpoint metadata"
  assert_grep "close could not be confirmed" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the journal was retained"
  assert_grep "not confirmed gone" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the records were retained"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "unconfirmed projected close must not escalate to workspace cleanup"
  assert_present "$case_dir/state/task-x1.scratch" "early refusal lost scratch registry"
  assert_absent "$case_dir/state/task-x1.backlog-close" "early refusal left a replayable close"
  pass "herdr projection teardown retains every record when post-close presence is unknown"
}

test_herdr_projection_teardown_surfaces_restore_failure_without_blocking_cleanup() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-restore-failure)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  JG_FAKE_HERDR_LOG="$log" JG_FAKE_HERDR_CLOSED="$closed" JG_FAKE_HERDR_RESTORED="$restored" \
    JG_FAKE_HERDR_RESTORE_FAIL=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-restore-failure: a confirmed close with a failed focus restore blocked teardown"
  [ -e "$closed" ] \
    || fail "herdr-projection-restore-failure: regression did not exercise the exact projected-pane close"
  [ ! -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "herdr-projection-restore-failure: confirmed closure did not retire the presentation journal"
  assert_grep "exact-tab restoration failed" "$case_dir/stderr" \
    "herdr-projection-restore-failure: teardown swallowed the focus helper's restore warning"
  pass "herdr projection teardown surfaces failed focus restoration without turning confirmed cleanup into a hard failure"
}

# A task's per-task watcher markers (.seen-<id>_status, .seen-<id>_turn-ended,
# .hb-surfaced-<id>) and an orphaned presentation journal - one whose pane the
# close path proved gone without retiring it - must not outlive teardown, while
# another task's markers and a journal bound to a different pane must.
seed_watcher_markers() {  # <case-dir> <task-id>
  local state="$1/state" id=$2
  printf '0:0\n' > "$state/.seen-${id}_status"
  printf '0:0\n' > "$state/.seen-${id}_turn-ended"
  printf '0\n' > "$state/.hb-surfaced-$id"
}

test_teardown_retires_task_watcher_markers_and_orphan_journal() {
  local case_dir log closed restored marker
  case_dir=$(make_case retire-watcher-markers)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"
  # The projected workspace is already gone before teardown runs, so the close
  # path cannot match the journal to a live workspace and leaves it behind.
  : > "$closed"
  seed_watcher_markers "$case_dir" task-x1
  seed_watcher_markers "$case_dir" task-y2
  seed_watcher_markers "$case_dir" task-x1_extra
  printf '%s\n' 'version=1' 'task_id=task-y2' 'projection_id=ZyXwVuTsRqPoNmLkJiHgFe' \
    > "$case_dir/state/task-y2.herdr-presentation"

  JG_FAKE_HERDR_LOG="$log" JG_FAKE_HERDR_CLOSED="$closed" JG_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retire-watcher-markers: teardown failed: $(cat "$case_dir/stderr")"
  for marker in .seen-task-x1_status .seen-task-x1_turn-ended .hb-surfaced-task-x1 task-x1.herdr-presentation; do
    assert_absent "$case_dir/state/$marker" "teardown left the torn-down task's $marker behind"
  done
  for marker in .seen-task-y2_status .seen-task-y2_turn-ended .hb-surfaced-task-y2 task-y2.herdr-presentation \
    .seen-task-x1_extra_status .seen-task-x1_extra_turn-ended .hb-surfaced-task-x1_extra; do
    assert_present "$case_dir/state/$marker" "teardown removed another task's $marker"
  done
  pass "teardown retires the task's own watcher markers and orphaned presentation journal, leaving other tasks' markers alone"
}

test_teardown_retains_journal_bound_to_another_pane() {
  local case_dir log closed restored
  case_dir=$(make_case retain-drifted-journal)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"
  : > "$closed"
  # A version 2 binding that advanced to a replacement pane the metadata never
  # recorded may still name a live quarantined space; only the sweep may judge it.
  printf '%s\n' 'version=2' 'task_id=task-x1' 'projection_id=AbCdEfGhIjKlMnOpQrStUv' \
    "home=$case_dir" 'session=fmtest' 'workspace_id=w1' 'tab_id=w1:t2' 'pane_id=w1:p9' \
    'parent_workspace_id=w0' 'parent_label=juggernaut' \
    'workspace_label=└ task-x1 · p:AbCdEfGhIjKlMnOpQrStUv' 'task_label=jg-task-x1' \
    > "$case_dir/state/task-x1.herdr-presentation"

  JG_FAKE_HERDR_LOG="$log" JG_FAKE_HERDR_CLOSED="$closed" JG_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retain-drifted-journal: teardown failed: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-x1.herdr-presentation" \
    "teardown retired a journal bound to a pane it never proved gone"
  assert_absent "$case_dir/state/task-x1.meta" "retain-drifted-journal: teardown did not complete"
  assert_grep "retaining herdr presentation journal" "$case_dir/stderr" \
    "teardown kept the drifted journal without saying why"
  pass "teardown retains a presentation journal bound to a pane other than the closed endpoint"
}

# A version 1 attempt journal binds no pane, so proving the recorded task pane
# gone does not prove its token-bearing projected workspace gone. When the v2
# bind never landed (RETIRE_CANDIDATE stays 0 because the metadata workspace no
# longer matches the drifted token workspace), teardown may retire the journal
# only after the session's workspace list confirms the token workspace is gone;
# while it is still present the session-start sweep alone owns it.
configure_herdr_v1_orphan_workspace_case() {  # <case-dir>
  local case_dir=$1 token=AbCdEfGhIjKlMnOpQrStUv
  sed -i.bak 's/^window=.*/window=fmtest:w1:p2/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=fmtest' \
    'herdr_workspace_id=w9' \
    'herdr_tab_id=w1:t2' \
    'herdr_pane_id=w1:p2' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' \
    'version=1' \
    'task_id=task-x1' \
    "projection_id=$token" > "$case_dir/state/task-x1.herdr-presentation"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${JG_FAKE_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace list")
    if [ "${JG_FAKE_HERDR_WS_MALFORMED:-0}" = 1 ]; then
      # A non-object entry before a live token-bearing workspace: the token query
      # is ambiguous, so teardown must treat it as unknown and keep the journal.
      printf '%s\n' '{"result":{"workspaces":[42,{"workspace_id":"w1","active_tab_id":"w1:t2","label":"juggernaut/task-x1 · p:AbCdEfGhIjKlMnOpQrStUv","focused":false}]}}'
    elif [ "${JG_FAKE_HERDR_WS_COLLAPSED:-0}" = 1 ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true}]}}'
    else
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t2","label":"juggernaut/task-x1 · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true}]}}'
    fi
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}'
    ;;
  "pane close")
    : > "${JG_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
    exit 1
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_teardown_retires_v1_journal_when_projected_workspace_gone() {
  local case_dir log closed
  case_dir=$(make_case retire-v1-journal-workspace-gone)
  write_meta "$case_dir" local-only ship
  configure_herdr_v1_orphan_workspace_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"

  JG_FAKE_HERDR_LOG="$log" JG_FAKE_HERDR_CLOSED="$closed" JG_FAKE_HERDR_WS_COLLAPSED=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retire-v1-journal-workspace-gone: teardown failed: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.herdr-presentation" \
    "a v1 journal whose token workspace is confirmed gone was not retired"
  assert_absent "$case_dir/state/task-x1.meta" \
    "retire-v1-journal-workspace-gone: teardown did not complete"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "retire-v1-journal-workspace-gone: teardown must never call workspace close"
  pass "teardown retires a v1 presentation journal once its token workspace is confirmed gone"
}

test_teardown_retains_v1_journal_when_projected_workspace_present() {
  local case_dir log closed
  case_dir=$(make_case retain-v1-journal-workspace-present)
  write_meta "$case_dir" local-only ship
  configure_herdr_v1_orphan_workspace_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"

  JG_FAKE_HERDR_LOG="$log" JG_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retain-v1-journal-workspace-present: teardown failed: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-x1.herdr-presentation" \
    "a v1 journal whose token workspace is still present was wrongly retired, stranding the workspace"
  assert_absent "$case_dir/state/task-x1.meta" \
    "retain-v1-journal-workspace-present: teardown did not complete"
  assert_grep "retaining herdr presentation journal" "$case_dir/stderr" \
    "teardown retained the v1 journal without saying why"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "retain-v1-journal-workspace-present: teardown must not escalate to workspace cleanup"
  pass "teardown retains a v1 presentation journal while its token workspace is still present"
}

test_teardown_retains_v1_journal_when_workspace_query_ambiguous() {
  local case_dir log closed
  case_dir=$(make_case retain-v1-journal-workspace-ambiguous)
  write_meta "$case_dir" local-only ship
  configure_herdr_v1_orphan_workspace_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"

  # A malformed workspace-list entry makes the token query ambiguous: teardown
  # cannot prove the token workspace gone, so it must keep the journal.
  JG_FAKE_HERDR_LOG="$log" JG_FAKE_HERDR_CLOSED="$closed" JG_FAKE_HERDR_WS_MALFORMED=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retain-v1-journal-workspace-ambiguous: teardown failed: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-x1.herdr-presentation" \
    "a v1 journal was retired even though the workspace query was ambiguous"
  assert_absent "$case_dir/state/task-x1.meta" \
    "retain-v1-journal-workspace-ambiguous: teardown did not complete"
  assert_grep "retaining herdr presentation journal" "$case_dir/stderr" \
    "teardown retained the v1 journal without saying why"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "retain-v1-journal-workspace-ambiguous: teardown must not escalate to workspace cleanup"
  pass "teardown retains a v1 presentation journal when the workspace query is ambiguous"
}

# --- Fix 2: reap leaked descendant processes rooted under the task's own
# worktree/tasktmp, exercised through the real teardown path
# (bin/jg-teardown.sh), never by matching its source text. ------------------

# Land an empty commit on the task branch and push it to origin: it changes no
# content, so origin's main already holds it and teardown must ALLOW, so these
# cases exercise the abort/reap steps on a real successful teardown rather than a
# refusal path.
land_shippable_commit() {
  local case_dir=$1
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
}

# Retro 4: task scratch directories and detached proof processes outlived their
# tasks. A task registers its scratch through bin/jg-scratch.sh; teardown reaps
# exactly those literal paths (and processes working inside them) once landing
# is proven, even though the session that created them is long gone.
test_registered_scratch_is_reaped_after_launching_session_is_gone() {
  local case_dir rc pid scratch sibling
  case_dir=$(make_case registered-scratch-reap)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  scratch="$case_dir/scratch/proof-run"
  sibling="$case_dir/scratch/proof-run-other"
  mkdir -p "$scratch/deep" "$sibling" "$case_dir/data/task-x1"
  printf 'x\n' > "$scratch/deep/file"
  printf 'keep\n' > "$sibling/file"
  printf 'evidence\n' > "$case_dir/data/task-x1/report.md"

  JG_ROOT_OVERRIDE="$ROOT" JG_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/jg-scratch.sh" register task-x1 "$scratch" > /dev/null \
    || fail "registered-scratch-reap: register refused a plain scratch directory"
  # The launching session is gone: a detached proof process outlives the
  # subshell that started it, parented to init, with its cwd in the scratch dir.
  ( cd "$scratch/deep" && setsid sleep 301 < /dev/null > /dev/null 2>&1 & )
  sleep 0.5
  pid=$(pgrep -f '^sleep 301$' -n -u "$(id -u)" 2>/dev/null || true)
  [ -n "$pid" ] && [ "$(readlink "/proc/$pid/cwd" 2>/dev/null)" = "$scratch/deep" ] \
    || { [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null; fail "registered-scratch-reap: setup process did not start in the scratch dir"; }

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "registered-scratch-reap: detached process in registered scratch survived teardown"
  fi
  expect_code 0 "$rc" "registered-scratch-reap: teardown should succeed: $(cat "$case_dir/stderr")"
  [ ! -e "$scratch" ] || fail "registered-scratch-reap: registered scratch directory survived teardown"
  [ -f "$sibling/file" ] || fail "registered-scratch-reap: an unregistered sibling directory was reaped"
  [ -f "$case_dir/data/task-x1/report.md" ] || fail "registered-scratch-reap: task evidence was reaped"
  [ ! -e "$case_dir/state/task-x1.scratch" ] || fail "registered-scratch-reap: teardown left the scratch record"
  pass "teardown reaps exactly the registered scratch directories and their detached processes, keeping evidence and unregistered siblings"
}

# Retro 5: a replay or measurement harness outlived the lane that started it and ran for hours. A harness
# started through bin/jg-lane-run.sh dies with its lane: a normal finish stops what it backgrounded, and a lane
# killed outright leaves nothing for teardown to miss even when the leftovers moved to another session and cwd.
test_lane_harness_dies_with_its_lane() {
  local case_dir rc pid wrapper marker harness
  case_dir=$(make_case lane-harness-reap)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  mkdir -p "$case_dir/data/task-x1"
  marker="$case_dir/harness-pids"
  harness="$case_dir/harness.sh"
  # The harness backgrounds a loop in its own group (a "replay") and, unless told to stay, ends at once.
  cat > "$harness" <<'HARNESS'
#!/bin/sh
(cd / && setsid sh -c 'echo $$ >> "$LANE_MARKER"; exec sleep 302' </dev/null >/dev/null 2>&1 &)
while [ "$(wc -l < "$LANE_MARKER" 2>/dev/null || echo 0)" -lt 1 ]; do sleep 0.05; done
sleep 303 </dev/null >/dev/null 2>&1 &
echo $! >> "$LANE_MARKER"
if [ "$1" = stay ]; then sleep 304; fi
exit 7
HARNESS
  export LANE_MARKER="$marker"
  chmod +x "$harness"

  # 1. A lane that starts a harness and finishes leaves no surviving process, and the harness status comes through.
  rc=0
  JG_ROOT_OVERRIDE="$ROOT" JG_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/jg-lane-run.sh" task-x1 -- "$harness" > /dev/null 2>&1 || rc=$?
  expect_code 7 "$rc" "lane-harness-reap: jg-lane-run should pass the harness status through"
  sleep 0.3
  while read -r pid; do
    if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fail "lane-harness-reap: harness process $pid survived its finished lane"; fi
  done < "$marker"

  # 2. A lane killed outright: nothing ran the wrapper's trap, so teardown reaps by the recorded token.
  : > "$marker"
  JG_ROOT_OVERRIDE="$ROOT" JG_STATE_OVERRIDE="$case_dir/state" setsid "$ROOT/bin/jg-lane-run.sh" task-x1 -- "$harness" stay < /dev/null > /dev/null 2>&1 &
  wrapper=$!
  sleep 1
  kill -KILL "$wrapper" 2>/dev/null || true
  pid=$(head -n1 "$marker")
  if [ "$(wc -l < "$marker")" -ne 2 ] || ! kill -0 "$pid" 2>/dev/null; then fail "lane-harness-reap: setup harness did not start"; fi
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "lane-harness-reap: teardown should succeed: $(cat "$case_dir/stderr")"
  while read -r pid; do
    if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fail "lane-harness-reap: harness process $pid survived teardown"; fi
  done < "$marker"
  [ ! -e "$case_dir/state/task-x1.lane-groups" ] || fail "lane-harness-reap: teardown left the lane record"
  pass "a harness started through jg-lane-run dies with its lane, and teardown reaps what a killed lane left"
}

test_registered_scratch_cleanup_paths() {
  local route failure case_dir home state data task scratch pid rc test_path
  for route in direct child; do
    for failure in none removal no-lsof worktree-scan scratch-scan list-search list-parent list-read; do
      case_dir=$(make_case "scratch-$route-$failure")
      if [ "$route" = child ]; then
        write_meta "$case_dir" local-only squad_lead
        configure_squad_lead_with_tmux_children "$case_dir"
        home="$case_dir/squad-lead-home"
        state="$home/state"; data="$home/data"; task="child-a"
      else
        write_meta "$case_dir" local-only ship
        seed_backlog_in_flight "$case_dir"
        home="$ROOT"; state="$case_dir/state"; data="$case_dir/data"; task="task-x1"
      fi
      scratch="$case_dir/scratch/proof"
      mkdir -p "$scratch"
      printf 'proof bytes\n' > "$scratch/file"
      case "$failure" in
        list-*)
          mkdir -p "$case_dir/another-proof"
          JG_HOME="$home" JG_STATE_OVERRIDE="$state" JG_DATA_OVERRIDE="$data" \
            "$ROOT/bin/jg-scratch.sh" register "$task" "$case_dir/another-proof" >/dev/null || fail "sibling registration failed"
          ;;
      esac
      JG_HOME="$home" JG_STATE_OVERRIDE="$state" JG_DATA_OVERRIDE="$data" \
        "$ROOT/bin/jg-scratch.sh" register "$task" "$scratch" >/dev/null \
        || fail "scratch-$route-$failure: registration failed"
      pid=
      if [ "$failure" = none ] || [ "$failure" = no-lsof ] \
         || [ "$failure" = worktree-scan ] || [ "$failure" = scratch-scan ]; then
        setsid bash -c "cd \"\$1\"; exec sleep 307" _ "$scratch" &
        pid=$!
        sleep 0.5
        kill -0 "$pid" 2>/dev/null || fail "scratch-$route-$failure: proof process did not start"
      fi
      if [ "$failure" = removal ]; then
        cat > "$case_dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" != "$JG_BLOCKED_SCRATCH" ] || exit 1
done
exec "$JG_REAL_RM" "$@"
SH
        chmod +x "$case_dir/fakebin/rm"
      fi
      if [ "$failure" = worktree-scan ] || [ "$failure" = scratch-scan ]; then
        cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$JG_SCRATCH_SCAN_COUNT" ] || count=$(cat "$JG_SCRATCH_SCAN_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$JG_SCRATCH_SCAN_COUNT"
[ "$count" -lt "$JG_SCRATCH_SCAN_LIMIT" ]
SH
        chmod +x "$case_dir/fakebin/lsof"
      fi
      case "$failure" in
        list-search) chmod 600 "$scratch" ;;
        list-parent) chmod 600 "$case_dir/scratch" ;;
        list-read) chmod 000 "$state/$task.scratch" ;;
      esac
      local scan_limit=1
      [ "$failure:$route" != scratch-scan:direct ] || scan_limit=2
      test_path=$PATH
      [ "$failure" != no-lsof ] || test_path=$(make_path_without_lsof "$case_dir")
      rc=0
      JG_BLOCKED_SCRATCH="$scratch" JG_REAL_RM="$(command -v rm)" \
        JG_SCRATCH_SCAN_COUNT="$case_dir/scan-count" JG_SCRATCH_SCAN_LIMIT="$scan_limit" \
        JG_TEARDOWN_TEST_PATH="$test_path" \
        run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      case "$failure" in
        list-search) chmod 700 "$scratch" ;;
        list-parent) chmod 700 "$case_dir/scratch" ;;
        list-read) chmod 600 "$state/$task.scratch" ;;
      esac
      if [ "$failure" = none ]; then
        if kill -0 "$pid" 2>/dev/null; then
          kill -KILL "$pid" 2>/dev/null || true
          wait "$pid" 2>/dev/null || true
          fail "scratch-$route: detached process survived"
        fi
        wait "$pid" 2>/dev/null || true
        expect_code 0 "$rc" "scratch-$route: cleanup failed: $(cat "$case_dir/stderr")"
        assert_absent "$scratch" "scratch-$route: scratch survived"
        assert_absent "$state/$task.scratch" "scratch-$route: registry survived"
      else
        if [ -n "$pid" ]; then
          if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            fail "scratch-$route-$failure: unverified proof process was killed"
          fi
          kill -KILL "$pid" 2>/dev/null || true
          wait "$pid" 2>/dev/null || true
        fi
        expect_code 1 "$rc" "scratch-$route-$failure: cleanup should refuse"
        assert_present "$scratch/file" "scratch-$route-$failure: scratch was removed"
        case "$failure" in
          list-*) assert_present "$case_dir/another-proof" "listing failure reaped a partial result" ;;
        esac
        assert_present "$state/$task.scratch" "scratch-$route-$failure: registry was removed"
        assert_present "$state/$task.meta" "scratch-$route-$failure: retry record was removed"
        assert_absent "$state/$task.backlog-close" "scratch-$route-$failure: pending close could erase retry record"
        bash -c '. "$1/bin/jg-backlog-transition-lib.sh"; jg_backlog_close_marker_replay "$2" "$2/$3.backlog-close" "$4"' \
          _ "$ROOT" "$state" "$task" "$data" || fail "scratch-$route-$failure: startup replay failed"
        assert_present "$state/$task.meta" "scratch-$route-$failure: startup replay erased retry record"
        assert_present "$case_dir/state/task-x1.meta" "scratch-$route-$failure: parent record was removed"
        if [ "$failure" = removal ] || [ "$failure" = no-lsof ] \
           || [ "$failure" = worktree-scan ] || [ "$failure" = scratch-scan ] \
           || [[ "$failure" = list-* ]]; then
          case "$failure" in
            worktree-scan|scratch-scan) rm "$case_dir/fakebin/lsof" ;;
          esac
          [ "$failure" != removal ] || rm "$case_dir/fakebin/rm"
          rc=0
          run_teardown "$case_dir" --force > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
          expect_code 0 "$rc" "scratch-$route-$failure: retry failed: $(cat "$case_dir/retry.stderr")"
          assert_absent "$scratch" "scratch-$route-$failure: retry left scratch"
          case "$failure" in
            list-*) assert_absent "$case_dir/another-proof" "retry left sibling scratch" ;;
          esac
        fi
      fi
    done
  done
  pass "direct and descendant scratch cleanup reap detached proofs and retain retry records on every refusal"
}

test_retained_task_data_processes_are_reaped() {
  local route failure case_dir data task pid rc test_path
  for route in direct child; do
    for failure in none no-lsof; do
      case_dir=$(make_case "retained-data-$route-$failure")
      if [ "$route" = child ]; then
        write_meta "$case_dir" local-only squad_lead
        configure_squad_lead_with_tmux_children "$case_dir"
        data="$case_dir/squad-lead-home/data"; task="child-a"
      else
        write_meta "$case_dir" local-only ship
        seed_backlog_in_flight "$case_dir"
        data="$case_dir/data"; task="task-x1"
      fi
      mkdir -p "$data/$task/proof"
      printf 'retain evidence\n' > "$data/$task/proof/result"
      printf 'retain sibling\n' > "$data/sibling-evidence"
      setsid bash -c "cd \"\$1\"; exec sleep 311" _ "$data/$task/proof" &
      pid=$!
      sleep 0.5
      test_path=$PATH
      [ "$failure" != no-lsof ] || test_path=$(make_path_without_lsof "$case_dir")
      rc=0
      JG_TEARDOWN_TEST_PATH="$test_path" run_teardown "$case_dir" --force \
        > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      if [ "$failure" = no-lsof ]; then
        kill -0 "$pid" 2>/dev/null || fail "retained-data: unverified process was killed"
        expect_code 1 "$rc" "retained-data: missing scanner should refuse"
        assert_present "$case_dir/state/task-x1.meta" "retained-data: lost parent retry record"
        if [ "$route" = child ]; then
          assert_present "$case_dir/squad-lead-home/state/$task.meta" "retained-data: lost child retry record"
        fi
        rc=0
        run_teardown "$case_dir" --force > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
      fi
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        fail "retained-data: detached proof survived cleanup"
      fi
      wait "$pid" 2>/dev/null || true
      expect_code 0 "$rc" "retained-data: cleanup failed: $(cat "$case_dir/stderr")"
      if [ "$route" = direct ]; then
        assert_present "$data/$task/proof/result" "retained-data: cleanup erased evidence"
        assert_present "$data/sibling-evidence" "retained-data: cleanup erased sibling evidence"
      fi
    done
  done
  pass "direct and descendant cleanup reap retained-data proofs, retain direct evidence, and refuse without a scanner"
}

test_hard_interruption_preserves_scratch_ownership_on_replay() {
  local case_dir scratch pid cleanup_pid rc mode location=${1:-scratch}
  case_dir=$(make_case "hard-interruption-$location")
  write_meta "$case_dir" local-only ship
  seed_backlog_in_flight "$case_dir"
  scratch="$case_dir/scratch/proof"
  [ "$location" != data ] || scratch="$case_dir/data/task-x1/proof"
  mkdir -p "$scratch"
  if [ "$location" = scratch ]; then
    JG_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/jg-scratch.sh" register task-x1 "$scratch" >/dev/null \
      || fail "hard-interruption: scratch registration failed"
  fi
  setsid bash -c "cd \"\$1\"; exec sleep 309" _ "$scratch" &
  pid=$!
  sleep 0.5
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
kill -KILL "$JG_TEARDOWN_KILL_PID"
exit 1
SH
  chmod +x "$case_dir/fakebin/lsof"
  JG_ROOT_OVERRIDE="$ROOT" JG_STATE_OVERRIDE="$case_dir/state" \
    JG_DATA_OVERRIDE="$case_dir/data" JG_CONFIG_OVERRIDE="$case_dir/config" \
    PATH="$case_dir/fakebin:$PATH" \
    bash -c 'export JG_TEARDOWN_KILL_PID=$$; exec "$@"' _ "$TEARDOWN" task-x1 --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr" &
  cleanup_pid=$!
  rc=0
  wait "$cleanup_pid" 2>/dev/null || rc=$?
  expect_code 137 "$rc" "hard-interruption: cleanup was not killed during scan"
  assert_present "$case_dir/state/task-x1.backlog-close" "hard-interruption: no pending close was written"
  for mode in close retain; do
    rc=0
    bash -c '
      . "$1/bin/jg-backlog-transition-lib.sh"
      if [ "$3" = retain ]; then
        gen=$(sed -n "s/^spawn_gen=//p" "$2/state/task-x1.meta")
        jg_backlog_close_marker_write "$2/state" task-x1 "$2/data" "$gen" --retain --note "local main" || exit 2
      fi
      jg_backlog_close_marker_replay "$2/state" "$2/state/task-x1.backlog-close" "$2/data"
    ' _ "$ROOT" "$case_dir" "$mode" || rc=$?
    expect_code 1 "$rc" "hard-interruption: $mode replay should wait for scratch cleanup"
    assert_present "$case_dir/state/task-x1.meta" "hard-interruption: $mode replay erased ownership"
    if [ "$location" = scratch ]; then
      assert_present "$case_dir/state/task-x1.scratch" "hard-interruption: $mode replay erased scratch registry"
    fi
    assert_present "$scratch" "hard-interruption: $mode replay erased scratch"
    assert_equals in_flight "$(backlog_row_state "$case_dir")" "hard-interruption: replay closed backlog"
  done
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    fail "hard-interruption: proof did not survive setup"
  fi
  rm "$case_dir/fakebin/lsof"
  rc=0
  run_teardown "$case_dir" --force > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "hard-interruption: proof survived retry"
  fi
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$rc" "hard-interruption: retry failed: $(cat "$case_dir/retry.stderr")"
  if [ "$location" = scratch ]; then
    assert_absent "$scratch" "hard-interruption: retry left scratch"
  else
    assert_present "$scratch" "hard-interruption: retry erased retained data"
  fi
  assert_absent "$case_dir/state/task-x1.meta" "hard-interruption: retry left task record"
  pass "hard interruption preserves scratch ownership across close and retain replay until retry reaps proofs"
}

test_scratch_registration_excludes_retained_material() {
  local case_dir home state data dir rc
  case_dir=$(make_case scratch-protected-material)
  write_meta "$case_dir" local-only ship
  home="$case_dir/home"; state="$case_dir/state"; data="$case_dir/data"
  mkdir -p "$home/sub" "$data/task-x1/proof" "$case_dir/scratch/proof"
  printf 'keep\n' > "$data/task-x1/proof/file"
  ln -s "$data" "$case_dir/evidence-alias"
  for dir in "$home" "$home/sub" "$state" "$data" "$data/task-x1/proof" \
      "$case_dir" "$ROOT" "$ROOT/bin" "$case_dir/evidence-alias/task-x1/proof"; do
    if JG_HOME="$home" JG_STATE_OVERRIDE="$state" JG_DATA_OVERRIDE="$data" \
        "$ROOT/bin/jg-scratch.sh" register task-x1 "$dir" >/dev/null 2>&1; then
      fail "protected-material: registered $dir"
    fi
  done
  assert_absent "$state/task-x1.scratch" "protected-material: refusals created registry"
  printf '%s\n' "$data/task-x1/proof" "$case_dir/scratch/proof" > "$state/task-x1.scratch"
  rc=0
  JG_HOME="$home" JG_DATA_OVERRIDE="$data" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "protected-material: legacy registry blocked cleanup: $(cat "$case_dir/stderr")"
  assert_present "$data/task-x1/proof/file" "protected-material: retained evidence was reaped"
  assert_absent "$case_dir/scratch/proof" "protected-material: disposable scratch survived"
  pass "registration and legacy listing exclude protected material, including canonical aliases"
}

test_registered_scratch_survives_a_refused_teardown() {
  local case_dir rc scratch
  case_dir=$(make_case registered-scratch-refused)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"
  scratch="$case_dir/scratch/proof-run"
  mkdir -p "$scratch"
  JG_ROOT_OVERRIDE="$ROOT" JG_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/jg-scratch.sh" register task-x1 "$scratch" > /dev/null \
    || fail "registered-scratch-refused: register refused a plain scratch directory"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "registered-scratch-refused: unlanded work must still refuse"
  [ -d "$scratch" ] && [ -f "$case_dir/state/task-x1.scratch" ] \
    || fail "registered-scratch-refused: a refused teardown reaped the scratch or its record"
  pass "a refused teardown leaves registered scratch and its record in place"
}

test_scratch_register_and_reap_refuse_unsafe_paths() {
  local case_dir rc
  case_dir=$(make_case scratch-unsafe-paths)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  mkdir -p "$case_dir/scratch/real" "$case_dir/home-like"
  ln -s "$case_dir/scratch/real" "$case_dir/scratch/link"
  for bad in "relative/dir" "$case_dir/scratch/*" "$case_dir/scratch/link" "$case_dir/scratch/real/../real" "$HOME" "/" "/tmp/does-not-exist-$$"; do
    if JG_ROOT_OVERRIDE="$ROOT" JG_STATE_OVERRIDE="$case_dir/state" \
        "$ROOT/bin/jg-scratch.sh" register task-x1 "$bad" > /dev/null 2>&1; then
      fail "scratch-unsafe-paths: register accepted $bad"
    fi
  done
  # A hand-written record cannot widen a delete: the unsafe lines are skipped and
  # the one safe line is still reaped.
  printf '%s\n' "$case_dir/scratch/*" "$HOME" "$case_dir/scratch/link" "$case_dir/missing" "$case_dir/scratch/real" \
    > "$case_dir/state/task-x1.scratch"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "scratch-unsafe-paths: teardown should succeed: $(cat "$case_dir/stderr")"
  [ ! -e "$case_dir/scratch/real" ] || fail "scratch-unsafe-paths: the safe recorded directory was not reaped"
  [ -d "$HOME" ] || fail "scratch-unsafe-paths: HOME was touched"
  pass "unsafe scratch paths are refused at registration and skipped at reap"
}

# Cleanup keeps the task's no-mistakes pipeline spend in this home's records
# (bin/jg-pipeline-spend.sh) while the task branch that attributes its runs and
# the task record still exist, then removes both as before.
test_teardown_records_the_task_pipeline_spend() {
  local case_dir rc=0 ledger
  case_dir=$(make_case pipeline-spend)
  write_meta "$case_dir" no-mistakes ship
  : > "$case_dir/config/pipeline-spend"
  land_shippable_commit "$case_dir"
  mkdir -p "$case_dir/nm"
  python3 - "$case_dir/nm/state.sqlite" "$case_dir/project" "$(date +%s)" <<'PY'
import sqlite3
import sys

database, project, created = sys.argv[1], sys.argv[2], int(sys.argv[3])
db = sqlite3.connect(database)
db.executescript("""
    CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
    CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
                       status TEXT NOT NULL, created_at INTEGER NOT NULL);
    CREATE TABLE agent_invocations (id TEXT, run_id TEXT, purpose TEXT, session_mode TEXT,
        started_at INTEGER, exit_status TEXT, duration_ms INTEGER, input_tokens INTEGER,
        output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER,
        delta_input_tokens INTEGER, delta_output_tokens INTEGER, delta_cache_read_tokens INTEGER);
""")
db.execute("INSERT INTO repos VALUES ('r1', ?)", (project,))
db.execute("INSERT INTO runs VALUES ('01RUN', 'r1', 'fm/task-x1', 'completed', ?)", (created,))
db.execute("INSERT INTO agent_invocations VALUES ('i1', '01RUN', 'review', 'cold', ?, 'ok', 100, 7, 8, 9, 10, 7, 8, 9)",
           (created,))
db.execute("INSERT INTO agent_invocations VALUES ('i2', '01RUN', 'review', 'cold', ?, 'cancelled', 50, "
           "NULL, NULL, NULL, NULL, NULL, NULL, NULL)", (created + 1,))
db.commit()
PY
  (
    export NM_HOME="$case_dir/nm" JG_FAKE_AXI_OVERVIEW="repo: $case_dir/project"
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  ) || rc=$?

  expect_code 0 "$rc" "pipeline-spend: teardown should succeed"
  ledger=$case_dir/data/pipeline-spend.jsonl
  assert_present "$ledger" "pipeline-spend: teardown left no pipeline spend record"
  jq -e '
    .task == "task-x1" and .spawn_gen == "teardown-test-task-x1"
    and .source == "no-mistakes-state" and .branch == "fm/task-x1"
    and [.runs[].id] == ["01RUN"]
    and .total.invocations == 2 and .total.exit == {"ok": 1, "cancelled": 1}
    and .total.input_tokens == {"total": 7, "unknown": 1}
  ' "$ledger" >/dev/null || fail "pipeline-spend: the recorded spend is wrong: $(cat "$ledger")"
  assert_absent "$case_dir/state/task-x1.meta" "pipeline-spend: teardown kept the task record"
  ! git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    || fail "pipeline-spend: teardown kept the task branch"
  pass "teardown records the task's pipeline spend before removing its branch and record"
}

test_teardown_skips_pipeline_spend_when_disabled() {
  local case_dir rc=0
  case_dir=$(make_case pipeline-spend-disabled)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "pipeline-spend-disabled: teardown should succeed"
  assert_absent "$case_dir/data/pipeline-spend.jsonl" \
    "pipeline-spend-disabled: teardown created a spend ledger without opt-in"
  assert_absent "$case_dir/state/task-x1.meta" \
    "pipeline-spend-disabled: teardown kept the task record"
  pass 'teardown skips all pipeline-spend recording when the home has not opted in'
}

# An owned ship task whose local copy is already gone still leaves a durable
# account: the recorder writes an unavailable-source line before the record goes.
test_teardown_records_unavailable_spend_for_a_gone_worktree() {
  local case_dir rc=0 ledger
  case_dir=$(make_case pipeline-spend-gone)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  : > "$case_dir/config/pipeline-spend"
  seed_backlog_in_flight "$case_dir"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "pipeline-spend-gone: teardown should succeed"
  ledger=$case_dir/data/pipeline-spend.jsonl
  assert_present "$ledger" "pipeline-spend-gone: teardown left no pipeline spend record"
  jq -e '.task == "task-x1" and .source == "unavailable" and .total == null
    and (.reason | contains("is gone"))' "$ledger" >/dev/null \
    || fail "pipeline-spend-gone: the recorded spend is wrong: $(cat "$ledger")"
  assert_absent "$case_dir/state/task-x1.meta" "pipeline-spend-gone: teardown kept the task record"
  pass "teardown records unavailable pipeline spend for an owned ship task whose copy is gone"
}

test_leaked_worktree_process_is_reaped() {
  local case_dir rc pid
  case_dir=$(make_case leaked-process-reap)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  # A backgrounded, disowned process rooted (by cwd) under the task's own
  # worktree - the same shape the observed incident's leaked `go test`
  # binaries took (reparented to init, no live task meta to attribute them
  # to once an unpatched teardown had already run).
  ( cd "$case_dir/wt" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "leaked-process-reap: setup sleeper did not start"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "leaked-process-reap: teardown should still succeed"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "leaked-process-reap: leaked worktree process survived teardown"
  fi
  assert_grep "reaping leaked worktree process" "$case_dir/stderr" \
    "leaked-process-reap: teardown did not report reaping the leaked process"
  pass "a leaked descendant process rooted under the task's worktree is reaped by teardown, not left surviving"
}

test_leaked_tasktmp_process_is_reaped() {
  local case_dir rc pid
  case_dir=$(make_case leaked-tasktmp-reap)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' "tasktmp=$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/tasktmp"
  land_shippable_commit "$case_dir"

  ( cd "$case_dir/tasktmp" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "leaked-tasktmp-reap: setup sleeper did not start"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "leaked-tasktmp-reap: teardown should still succeed"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "leaked-tasktmp-reap: leaked tasktmp process survived teardown"
  fi
  assert_grep "reaping leaked worktree process" "$case_dir/stderr" \
    "leaked-tasktmp-reap: teardown did not report reaping the leaked tasktmp process"
  pass "a leaked descendant process rooted under the task's per-task tasktmp is reaped by teardown too"
}

test_lsof_absent_reaps_tmux_process_group() {
  local case_dir rc pid path_without_lsof
  case_dir=$(make_case lsof-absent-process-group-reap)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  path_without_lsof=$(make_path_without_lsof "$case_dir")
  PATH="$path_without_lsof" command -v lsof >/dev/null 2>&1 \
    && fail "lsof-absent-process-group-reap: fixture path unexpectedly exposes lsof"

  perl -e 'setpgrp(0, 0); chdir shift or die; exec "sleep", "300"' "$case_dir/wt" &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "lsof-absent-process-group-reap: setup sleeper did not start"
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = display-message ] && [ "\${*: -1}" = '#{pane_pid}' ]; then
  printf '%s\n' '$pid'
fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/tmux"

  rc=0
  JG_TEARDOWN_TEST_PATH="$path_without_lsof" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "lsof-absent-process-group-reap: teardown should succeed"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "lsof-absent-process-group-reap: tmux process group survived teardown"
  fi
  assert_grep "reaping leaked worktree process group" "$case_dir/stderr" \
    "lsof-absent-process-group-reap: teardown did not use the process-group fallback"
  pass "missing lsof falls back to reaping the tmux pane process group"
}

test_lsof_error_refuses_before_removal() {
  local case_dir rc
  case_dir=$(make_case lsof-error-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'return\n' >> "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/treehouse"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "lsof-error-refusal: teardown should refuse"
  assert_grep "REFUSED: cannot determine leaked processes under $case_dir/wt for task-x1 (lsof failed)" "$case_dir/stderr" \
    "lsof-error-refusal: teardown did not explain the lsof refusal"
  assert_present "$case_dir/wt" "lsof-error-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "lsof-error-refusal: teardown removed task metadata"
  assert_absent "$case_dir/treehouse.log" "lsof-error-refusal: teardown returned the worktree"
  pass "an erroring lsof scan refuses teardown and preserves the task"
}

test_reused_pid_identity_is_not_force_killed() {
  local case_dir rc pid
  case_dir=$(make_case reused-pid-identity)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  perl -e '$SIG{TERM} = "IGNORE"; sleep 300' &
  pid=$!
  disown
  sleep 0.2
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
count=0
[ ! -f '$case_dir/lsof-count' ] || count=\$(cat '$case_dir/lsof-count')
count=\$((count + 1))
printf '%s\n' "\$count" > '$case_dir/lsof-count'
if [ "\$count" -le 3 ]; then printf 'p%s\nfcwd\nn%s\n' '$pid' '$case_dir/wt'; fi
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${JG_FAKE_REUSED_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  count=0
  [ ! -f "$JG_FAKE_PS_COUNT" ] || count=$(cat "$JG_FAKE_PS_COUNT")
  count=$((count + 1))
  printf '%s\n' "$count" > "$JG_FAKE_PS_COUNT"
  if [ "$count" -le 2 ]; then printf 'Tue Aug  4 10:00:00 2026\n'
  else printf 'Tue Aug  4 10:00:01 2026\n'; fi
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps"

  rc=0
  JG_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
  JG_FAKE_REUSED_PID="$pid" JG_FAKE_PS_COUNT="$case_dir/ps-count" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "reused-pid-identity: teardown should skip the replacement process"
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "reused-pid-identity: teardown force-killed a process whose start time changed"
  fi
  kill -KILL "$pid" 2>/dev/null || true
  pass "a reused pid with a different start time is never force-killed"
}

test_exec_changed_process_is_still_reaped() {
  local case_dir rc pid marker done_flag survived=0
  case_dir=$(make_case exec-changed-process)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  marker="$case_dir/exec-now"
  done_flag="$case_dir/exec-done"

  ( cd "$case_dir/wt" && exec perl -e '
      my ($marker, $done) = @ARGV;
      until (-e $marker) { select undef, undef, undef, 0.01; }
      open my $fh, ">", $done or die "open";
      close $fh;
      exec "perl", "-e", '\''$SIG{TERM} = "IGNORE"; sleep 300'\'';
    ' "$marker" "$done_flag" ) &
  pid=$!
  disown
  sleep 0.2
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${JG_FAKE_EXEC_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  out=$("$REAL_PS_FOR_TEST" "$@") || exit $?
  [ -e "$JG_FAKE_EXEC_MARKER" ] || : > "$JG_FAKE_EXEC_MARKER"
  printf '%s\n' "$out"
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$JG_FAKE_LSOF_COUNT" ] || count=$(cat "$JG_FAKE_LSOF_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$JG_FAKE_LSOF_COUNT"
if [ "$count" -eq 2 ]; then
  i=0
  while [ "$i" -lt 100 ]; do
    [ ! -e "$JG_FAKE_EXEC_DONE" ] || break
    sleep 0.01
    i=$((i + 1))
  done
fi
exec "$REAL_LSOF_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/ps" "$case_dir/fakebin/lsof"

  rc=0
  JG_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
  JG_FAKE_EXEC_PID="$pid" JG_FAKE_EXEC_MARKER="$marker" \
  JG_FAKE_EXEC_DONE="$done_flag" JG_FAKE_LSOF_COUNT="$case_dir/lsof-count" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if kill -0 "$pid" 2>/dev/null; then
    survived=1
    kill -KILL "$pid" 2>/dev/null || true
  fi
  expect_code 0 "$rc" "exec-changed-process: teardown should succeed"
  [ "$survived" -eq 0 ] || fail "exec-changed-process: exec-changed leaked process survived teardown"
  pass "an exec change preserves birth identity and the process is reaped"
}

test_process_spawned_during_grace_is_reaped_on_later_pass() {
  local case_dir rc pid child_file child_pid="" parent_survived=0 child_survived=0
  case_dir=$(make_case grace-spawn-convergence)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  child_file="$case_dir/child.pid"

  ( cd "$case_dir/wt" && exec perl -e '
      my $file = shift;
      $SIG{TERM} = sub {
        my $child = fork();
        die "fork" unless defined $child;
        if (!$child) { exec "sleep", "300"; }
        open my $fh, ">", $file or die "open";
        print {$fh} "$child\n";
        close $fh;
        exit 0;
      };
      sleep 300;
    ' "$child_file" ) &
  pid=$!
  disown
  sleep 0.2

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if [ -f "$child_file" ]; then child_pid=$(cat "$child_file"); fi
  if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
    child_survived=1
    kill -KILL "$child_pid" 2>/dev/null || true
  fi
  if kill -0 "$pid" 2>/dev/null; then
    parent_survived=1
    kill -KILL "$pid" 2>/dev/null || true
  fi
  expect_code 0 "$rc" "grace-spawn-convergence: teardown should converge"
  assert_present "$child_file" "grace-spawn-convergence: TERM handler did not spawn a child"
  [ "$child_survived" -eq 0 ] || fail "grace-spawn-convergence: spawned child survived"
  [ "$parent_survived" -eq 0 ] || fail "grace-spawn-convergence: original process survived"
  pass "a process spawned during grace is reaped on a later pass"
}

test_persistent_scan_refuses_after_bounded_retries() {
  local case_dir rc wt_path fake_pid=99999999
  case_dir=$(make_case persistent-reap-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  wt_path=$(cd "$case_dir/wt" && pwd -P)
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
printf 'p%s\nfcwd\nn%s\n' '$fake_pid' '$wt_path'
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${JG_FAKE_PERSISTENT_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  printf 'Tue Aug  4 10:00:00 2026\n'
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps"

  rc=0
  JG_PROC_ROOT_OVERRIDE="$case_dir/no-proc" JG_FAKE_PERSISTENT_PID="$fake_pid" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "persistent-reap-refusal: teardown should refuse"
  assert_grep "remain after 3 reap attempts" "$case_dir/stderr" \
    "persistent-reap-refusal: teardown did not report bounded non-convergence"
  assert_present "$case_dir/wt" "persistent-reap-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "persistent-reap-refusal: teardown removed task metadata"
  pass "persistent leaked processes refuse teardown after bounded retries"
}

test_process_exit_during_identity_lookup_does_not_refuse() {
  local case_dir rc wt_path fake_pid=99999998
  case_dir=$(make_case identity-exit-convergence)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  wt_path=$(cd "$case_dir/wt" && pwd -P)
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
count=0
[ ! -f "$case_dir/lsof-count" ] || count=\$(cat "$case_dir/lsof-count")
count=\$((count + 1))
printf '%s\n' "\$count" > "$case_dir/lsof-count"
if [ "\$count" -eq 1 ]; then
  printf 'p%s\nfcwd\nn%s\n' '$fake_pid' '$wt_path'
fi
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${JG_FAKE_EXITED_PID:-}" ]; then
  exit 1
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'returned\n' > "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps" "$case_dir/fakebin/treehouse"

  rc=0
  JG_PROC_ROOT_OVERRIDE="$case_dir/no-proc" JG_FAKE_EXITED_PID="$fake_pid" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "identity-exit-convergence: teardown should succeed"
  assert_present "$case_dir/treehouse.log" \
    "identity-exit-convergence: teardown did not reach worktree return"
  ! grep -q REFUSED "$case_dir/stderr" || \
    fail "identity-exit-convergence: a disappeared process caused teardown refusal"
  pass "a process exiting during identity lookup does not block teardown"
}

test_process_reap_precedes_worktree_removal() {
  local case_dir rc pid
  case_dir=$(make_case reap-then-remove-order)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  ( cd "$case_dir/wt" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "reap-then-remove-order: setup sleeper did not start"

  # A treehouse fake that snapshots, at the exact moment the destructive
  # worktree return runs whether the leaked process was already reaped - direct causal proof of ordering from
  # real observed state, not a source-text or line-number correlation.
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
if ! kill -0 $pid 2>/dev/null; then echo "reap-already-happened" >> "$case_dir/order.log"; fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "reap-then-remove-order: teardown should still succeed"
  kill -0 "$pid" 2>/dev/null && { kill -KILL "$pid" 2>/dev/null || true; }

  assert_present "$case_dir/order.log" \
    "reap-then-remove-order: the destructive worktree return was never invoked"
  assert_grep "reap-already-happened" "$case_dir/order.log" \
    "reap-then-remove-order: the leaked process was not yet reaped when the worktree return ran"
  pass "the leaked-process reap completes before the destructive worktree return"
}

# Copy the public teardown script tree, then drop or blank one required file.
# Symlinks keep the copy cheap; an unreadable case replaces one link with a
# real mode-000 file so the probe is of the file itself.
prepare_teardown_source_copy() {  # <case-dir>
  local case_dir=$1 f base dest="$1/test-root/bin" s
  mkdir -p "$dest/backends"
  for f in "$ROOT"/bin/*; do
    base=$(basename "$f")
    if [ -d "$f" ]; then
      mkdir -p "$dest/$base"
      for s in "$f"/*; do
        ln -s "$s" "$dest/$base/$(basename "$s")"
      done
    else
      ln -s "$f" "$dest/$base"
    fi
  done
  ln -s "$ROOT/toolchain.versions" "$case_dir/test-root/toolchain.versions"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  : > "$case_dir/treehouse.log"
  : > "$case_dir/state/task-x1.status"
}

run_copied_teardown() {  # <case-dir> [args...]
  local case_dir=$1
  shift
  JG_ROOT_OVERRIDE="$ROOT" \
  JG_STATE_OVERRIDE="$case_dir/state" \
  JG_DATA_OVERRIDE="$case_dir/data" \
  JG_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$case_dir/test-root/bin/jg-teardown.sh" task-x1 "$@"
}

assert_source_refusal_preserved_state() {  # <case-dir> <label> <stderr-needle>
  local case_dir=$1 label=$2 needle=$3
  [ "$rc" -ne 0 ] || fail "$label: teardown reported success after a required source disappeared"
  assert_grep "$needle" "$case_dir/stderr" "$label: the refusal did not name the missing source"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "$label: the refusal erased task metadata"
  [ -e "$case_dir/state/task-x1.status" ] || fail "$label: the refusal erased the task status record"
  [ ! -s "$case_dir/treehouse.log" ] || fail "$label: the refusal returned the local copy: $(cat "$case_dir/treehouse.log")"
  if grep -q "teardown task-x1 complete" "$case_dir/stdout"; then
    fail "$label: the refusal still reported cleanup complete"
  fi
}

test_missing_startup_source_refuses_before_cleanup() {
  local case_dir rc
  case_dir=$(make_case missing-startup-source)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/jg-wake-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-startup-source" "required source jg-wake-lib.sh"
  pass "a missing teardown startup source refuses before cleanup"
}

test_unreadable_startup_source_refuses_before_cleanup() {
  local case_dir rc
  case_dir=$(make_case unreadable-startup-source)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/jg-wake-lib.sh"
  cp "$ROOT/bin/jg-wake-lib.sh" "$case_dir/test-root/bin/jg-wake-lib.sh"
  chmod 000 "$case_dir/test-root/bin/jg-wake-lib.sh"
  if [ -r "$case_dir/test-root/bin/jg-wake-lib.sh" ]; then
    pass "unreadable startup source skipped: this user can read mode-000 files"
    return 0
  fi
  rc=0
  run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "unreadable-startup-source" "required source jg-wake-lib.sh"
  pass "an unreadable teardown startup source refuses before cleanup"
}

test_missing_adapter_sibling_refuses_before_cleanup() {
  local case_dir rc
  case_dir=$(make_case missing-adapter-sibling)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/jg-session-lock-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-adapter-sibling" "required tmux source"
  pass "a missing adapter sibling refuses before cleanup"
}

test_forced_child_missing_adapter_sibling_refuses_before_cleanup() {
  local case_dir home rc
  case_dir=$(make_case missing-child-adapter-sibling)
  write_meta "$case_dir" local-only squad_lead
  configure_squad_lead_with_herdr_child "$case_dir"
  home="$case_dir/squad-lead-home"
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/jg-transition-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-child-source" "required herdr source"
  [ -e "$home/state/child-herdr.meta" ] || fail "missing-child-source: the refusal erased the child record"
  [ -d "$home" ] || fail "missing-child-source: the refusal removed the squad_lead home"
  pass "a forced descendant with a missing adapter sibling refuses before cleanup"
}

test_forced_squad_lead_own_missing_adapter_sibling_refuses_before_child_cleanup() {
  local case_dir home rc
  case_dir=$(make_case missing-own-adapter-sibling)
  jg_write_meta "$case_dir/state/task-x1.meta" \
    "window=zs:3" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=squad_lead" \
    "mode=local-only" \
    "backend=zellij" \
    "zellij_session=zs" \
    "zellij_tab_id=1" \
    "zellij_pane_id=3" \
    "spawn_gen=teardown-test-task-x1"
  home="$case_dir/squad-lead-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.jg-squad-lead-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  jg_write_meta "$home/state/child-tmux.meta" \
    "window=childsession:jg-child-tmux" \
    "endpoint_task_id=child-tmux" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only"
  : > "$home/state/child-tmux.status"
  prepare_teardown_source_copy "$case_dir"
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/tmux.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  : > "$case_dir/tmux.log"
  rm -f "$case_dir/test-root/bin/jg-backend-hometag-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-own-source" "required zellij source"
  [ -e "$home/state/child-tmux.meta" ] || fail "missing-own-source: the refusal erased the child record"
  [ -e "$home/state/child-tmux.status" ] || fail "missing-own-source: the refusal erased the child status"
  [ -d "$home" ] || fail "missing-own-source: the refusal removed the squad_lead home"
  if grep -q "kill" "$case_dir/tmux.log"; then
    fail "missing-own-source: the refusal killed the child endpoint: $(cat "$case_dir/tmux.log")"
  fi
  pass "a forced squad_lead with a missing own adapter sibling refuses before child cleanup"
}

test_retained_sources_still_reach_the_ordinary_refusal() {
  local case_dir rc
  case_dir=$(make_case retained-sources)
  prepare_teardown_source_copy "$case_dir"
  rc=0
  JG_ROOT_OVERRIDE="$ROOT" \
  JG_STATE_OVERRIDE="$case_dir/state" \
  JG_DATA_OVERRIDE="$case_dir/data" \
  JG_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$case_dir/test-root/bin/jg-teardown.sh" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -eq 2 ] || fail "retained-sources: a present source tree should still reject a request with no task id (rc=$rc)"
  assert_grep "invalid teardown request" "$case_dir/stderr" \
    "retained-sources: the ordinary refusal was replaced"
  pass "present required sources still reach the ordinary teardown refusal"
}

test_local_trunk_cleanup() {
  local scenario case_dir head out rc branch=trunk
  for scenario in landed unlanded pushed-unlanded dirty held rolled non-trunk; do
    case_dir=$(make_case "local-trunk-$scenario")
    write_meta "$case_dir" local-only ship
    printf '%s\n' '- project [local-trunk] - fixture' > "$case_dir/data/projects.md"
    wt_commit_file "$case_dir" feature.txt 'Umer feature' 'task-x1: feature'
    head=$(git -C "$case_dir/wt" rev-parse HEAD)
    [ "$scenario" != rolled ] || branch=trunk-v2
    git -C "$case_dir/project" branch "$branch" "$head"
    printf '%s\n' "$branch" > "$case_dir/state/trunk-branch-project"
    printf '%s\n' "$head" > "$case_dir/state/trunk-tip-project"
    # In rolled homes the original trunk has already been retired.
    git -C "$case_dir/project" show-ref --verify --quiet "refs/heads/$branch" || fail 'missing fixture trunk'
    case "$scenario" in
      unlanded|pushed-unlanded) wt_commit_file "$case_dir" later.txt 'unlanded work' 'task-x1: later' ;;
      dirty) printf '%s\n' 'uncommitted work' >> "$case_dir/wt/feature.txt" ;;
      held)
        seed_backlog_in_flight "$case_dir"
        JG_HOME="$case_dir" JG_STATE_OVERRIDE="$case_dir/state" JG_DATA_OVERRIDE="$case_dir/data" \
          JG_CONFIG_OVERRIDE="$case_dir/config" "$ROOT/bin/jg-captain-hold.sh" hold task-x1 \
          --reason 'Choose the follow-up' >/dev/null || fail 'could not hold fixture task'
        ;;
      non-trunk) printf '%s\n' '- project [local-only] - fixture' > "$case_dir/data/projects.md" ;;
    esac
    [ "$scenario" != pushed-unlanded ] || add_fork_with_pushed_branch "$case_dir"
    head=$(git -C "$case_dir/wt" rev-parse HEAD)
    [ -z "$(git --git-dir="$case_dir/origin.git" for-each-ref refs/heads/release/)" ] || fail 'fixture has a release ref'
    rc=0; out=$(run_teardown "$case_dir" 2>&1) || rc=$?
    case "$scenario" in
      unlanded|pushed-unlanded|dirty|non-trunk)
        [ "$rc" -ne 0 ] || fail "$scenario: cleanup discarded protected work"
        assert_refusal_retained_task_state "$case_dir" "$scenario" "$head"
        if [ "$scenario" = dirty ]; then
          assert_contains "$(cat "$case_dir/wt/feature.txt")" 'uncommitted work' 'dirty bytes lost'
        fi
        assert_contains "$out" REFUSED "$scenario: refusal must name the cause"
        ;;
      *)
        [ "$rc" -eq 0 ] || fail "$scenario: landed local trunk cleanup refused: $out"
        [ ! -e "$case_dir/state/task-x1.meta" ] || fail "$scenario: task record survived cleanup"
        git -C "$case_dir/project" merge-base --is-ancestor "$head" "$branch" || fail 'cleanup lost landed work'
        if [ "$scenario" = held ]; then
          JG_HOME="$case_dir" JG_STATE_OVERRIDE="$case_dir/state" JG_DATA_OVERRIDE="$case_dir/data" \
            JG_CONFIG_OVERRIDE="$case_dir/config" "$ROOT/bin/jg-captain-hold.sh" open task-x1 >/dev/null \
            || fail 'cleanup closed the unanswered captain call'
          assert_contains "$out" 'still held for the captain' 'held row must remain open'
        fi
        ;;
    esac
    pass "local trunk cleanup: $scenario (no release ref)"
    branch=trunk
  done
}

if [ "${1:-}" = --local-trunk ]; then
  test_local_trunk_cleanup
  test_local_only_truly_unpushed_refuses
  test_local_only_merged_to_local_main_allows
  exit 0
fi

test_local_trunk_cleanup
test_missing_startup_source_refuses_before_cleanup
test_unreadable_startup_source_refuses_before_cleanup
test_missing_adapter_sibling_refuses_before_cleanup
test_forced_child_missing_adapter_sibling_refuses_before_cleanup
test_forced_squad_lead_own_missing_adapter_sibling_refuses_before_child_cleanup
test_retained_sources_still_reach_the_ordinary_refusal
test_local_only_fork_remote_allows
test_teardown_of_an_already_cleaned_task_says_so
test_teardown_closes_the_backlog_item_itself
test_empty_lane_of_a_closed_ticket_is_dropped
test_local_only_truly_unpushed_refuses
test_local_only_merged_to_local_main_allows
test_pushed_branch_needs_forge_merge_proof
test_no_mistakes_truly_unpushed_refuses
test_local_only_force_overrides_unpushed
test_squad_lead_pr_registration_publishes_ready_line
test_runner_clears_the_lead_launch_parent_prefix
test_squad_lead_home_teardown_delivers_final_line_or_refuses
test_teardown_missing_busy_sidecar_completes
test_herdr_teardown_clears_escalation_marker
test_herdr_flat_teardown_refuses_orphaning_records_then_retry_completes
test_herdr_flat_teardown_refuses_records_on_unparseable_presence
test_herdr_flat_teardown_preflight_refuses_before_changes
test_herdr_teardown_presentation_lock_namespace_is_per_account
test_forced_squad_lead_herdr_child_preflight_refuses_before_changes
test_forced_squad_lead_teardown_holds_descendant_lifecycle_locks
test_forced_squad_lead_herdr_child_retains_records_when_close_unconfirmed
test_forced_teardown_retains_nested_squad_lead_home_when_grandchild_close_unconfirmed
test_herdr_projection_teardown_retires_journal_only_after_confirmed_close
test_herdr_projection_teardown_retains_journal_when_close_unconfirmed
test_herdr_projection_teardown_surfaces_restore_failure_without_blocking_cleanup
test_teardown_retires_task_watcher_markers_and_orphan_journal
test_teardown_retains_journal_bound_to_another_pane
test_teardown_retires_v1_journal_when_projected_workspace_gone
test_teardown_retains_v1_journal_when_projected_workspace_present
test_teardown_retains_v1_journal_when_workspace_query_ambiguous
test_squash_merged_branch_deleted_allows
test_squash_merged_pr_allows_when_head_ancestor_of_pr_head
test_cross_repo_lane_proves_own_landing
test_no_pr_recorded_discovers_merged_pr_by_branch_allows
test_squash_merged_pr_allows_replayed_unpushed_patch
test_merged_pr_with_later_local_commit_refuses
test_squash_merged_rebased_branch_allows
test_squash_merged_forgejo_pr_allows_when_main_moved_on
test_squash_merged_same_file_different_content_refuses
test_squash_merged_rebased_local_with_unlanded_commit_refuses
test_squash_merged_stale_local_refuses_when_forge_unreachable
test_pr_check_does_not_refresh_stale_pr_head
test_pr_check_records_remote_head_when_local_lags
test_content_in_default_fallback_allows
test_content_fallback_uses_recorded_base_branch
test_content_fallback_refreshes_stale_origin_ref
test_dirty_worktree_refuses
test_untracked_only_refusal_diagnostic
test_tracked_edit_refusal_diagnostic
test_mixed_refusal_diagnostic
test_scout_nested_clone_returns_with_no_untracked_entries
test_scout_report_page_must_open_with_the_answer
test_scout_wide_report_must_carry_the_state_map
test_scout_report_must_pass_the_recon_depth_gate
test_ship_nested_clone_is_refused_and_bytes_stay
test_dirty_return_warns_which_slot_was_lost
test_dirty_return_warns_even_when_a_later_step_refuses
test_forced_squad_lead_child_scout_nested_clone_returns_clean
test_forced_squad_lead_dirty_child_return_warns_and_completes
test_return_that_removes_copy_warns_cannot_verify
test_scout_ignored_files_survive_scratch_clean
test_gh_error_and_content_absent_refuses
test_legacy_record_without_the_flag_refuses
test_windowless_legacy_record_with_gone_worktree_tears_down
test_windowless_legacy_record_tears_down_with_the_legacy_flag
test_windowless_legacy_record_still_refuses_unlanded_work
test_windowless_record_with_spawn_gen_tears_down_when_nothing_is_unlanded
test_windowless_record_with_spawn_gen_still_refuses_unlanded_work
test_windowless_record_outside_the_leftover_class_still_refuses
test_windowless_leftover_retries_its_retained_legacy_stamp_without_the_flag
test_legacy_record_teardown_completes_when_landed_and_endpoint_dead
test_legacy_record_teardown_refuses_unlanded_work
test_legacy_record_teardown_refuses_an_ambiguous_endpoint
test_legacy_record_rolls_the_stamp_back_when_the_marker_write_fails
test_retained_legacy_stamp_still_faces_the_endpoint_gate
test_legacy_record_never_accepts_a_corrupt_spawn_gen
test_stale_index_lock_cleared_and_teardown_succeeds
test_live_index_lock_is_never_removed_and_teardown_refuses
test_lsof_error_never_clears_index_lock
test_stale_index_lock_cleanup_rechecks_dirty_worktree
test_non_linked_index_lock_path_is_checked_from_worktree
test_index_lock_mtime_read_failure_refuses
test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds
test_persistent_index_lock_exhausts_retries_and_refuses_loudly
test_empty_retry_wait_uses_default_without_aborting
test_fractional_legacy_retry_wait_refuses_without_arithmetic_error
test_teardown_records_the_task_pipeline_spend
test_teardown_skips_pipeline_spend_when_disabled
test_teardown_records_unavailable_spend_for_a_gone_worktree
test_leaked_worktree_process_is_reaped
test_leaked_tasktmp_process_is_reaped
test_registered_scratch_is_reaped_after_launching_session_is_gone
test_lane_harness_dies_with_its_lane
test_retained_task_data_processes_are_reaped
test_hard_interruption_preserves_scratch_ownership_on_replay
test_hard_interruption_preserves_scratch_ownership_on_replay data
test_scratch_registration_excludes_retained_material
test_registered_scratch_cleanup_paths
test_registered_scratch_survives_a_refused_teardown
test_scratch_register_and_reap_refuse_unsafe_paths
test_lsof_absent_reaps_tmux_process_group
test_lsof_error_refuses_before_removal
test_reused_pid_identity_is_not_force_killed
test_exec_changed_process_is_still_reaped
test_process_spawned_during_grace_is_reaped_on_later_pass
test_persistent_scan_refuses_after_bounded_retries
test_process_exit_during_identity_lookup_does_not_refuse
test_process_reap_precedes_worktree_removal

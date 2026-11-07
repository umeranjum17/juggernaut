#!/usr/bin/env bash
# done-done journey: a pull request cannot be merged into a release branch that
# already shipped, driven by the real bin/jg-pr-merge.sh (merge-on-green merges
# through the same script).
#
# Pull request 598 once merged into release/c-8 after c-8 had reached the default
# branch, so its commit never shipped. A release branch is shipped only when its
# release pull request into the default branch merged, so a newer release branch
# existing proves nothing: c-10 took no work for a while after c-11 was cut even
# though c-10 had never reached the default branch. The journey shows that:
#   1. a pull request on release/c-5, whose release pull request merged, with
#      release/c-6 open, is refused before any merge command runs; the refusal
#      names release/c-6 and the exact gh pr edit command, and the task record
#      gets no merge;
#   2. a pull request on release/c-5 with release/c-6 open but NO merged release
#      pull request for c-5 is not refused: c-5 has not shipped and still takes
#      work;
#   3. a pull request on release/c-6, the open release branch, merges normally;
#   4. a branch shipped by a merged pull request into the default branch, with no
#      newer branch yet, is refused and says no release branch is open;
#   5. the release pull request into the default branch is not touched by the guard,
#      and merges with a merge commit while the feature pull request in 3 squashes.
# The forge is a recording `gh` driven by files, so the proof needs no network.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
LOG=$OUT/release-shipped-merge-refusal.txt
: > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
fail() { log "FAIL: $*"; exit 1; }
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid
export HOME=$T/user-home
mkdir -p "$HOME"

H=$T/home
mkdir -p "$H/config" "$H/state" "$H/data" "$T/fakebin"
# The merge asks the backlog whether the task is still held for the captain, and a home with no Beads
# store (pinned bd and dolt, run only through bin/jg-beads.sh) refuses to answer.
BD=${JG_BEADS_BD:-${JG_BEADS_TEST_BD:-$(command -v bd)}}
DOLT=${JG_BEADS_DOLT:-${JG_BEADS_TEST_DOLT:-$(command -v dolt)}}
[ -n "$BD" ] && [ -n "$DOLT" ] || fail "the pinned bd and dolt are required (bin/jg-bootstrap.sh install bd dolt)"
export JG_BEADS_BD=$BD JG_BEADS_DOLT=$DOLT
mkdir -p "$T/beads"
printf '%s\n' "$T/beads/.beads" > "$H/config/beads-dir"
BEADS_DIR="$T/beads/.beads" "$REPO/bin/jg-beads.sh" init --prefix jg >/dev/null 2>&1 || fail "cannot create the Beads store"
HEAD_SHA=0123456789abcdef0123456789abcdef01234567
U=https://github.com/acme/thing/pull

# A project clone: main plus the release branches a case names.
mkproject() {  # <dir> <release-branch>...
  local dir=$1 b
  shift
  git init -q --bare "$dir.git" || fail "cannot create the fixture origin"
  git -C "$dir.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir.git" "$dir" 2>/dev/null || fail "cannot clone the fixture"
  printf 'v1\n' > "$dir/README.md"
  git -C "$dir" add -A
  git -C "$dir" commit -qm c1 || fail "cannot seed the fixture"
  for b in main "$@"; do
    git -C "$dir" push -q origin "HEAD:refs/heads/$b" || fail "cannot push $b"
  done
  git -C "$dir" fetch -q
  git -C "$dir" remote set-head origin main >/dev/null 2>&1 || true
}

cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
# A recording forge. $GH_BASE is the pull request's base; $GH_MERGED_HEADS lists
# the release heads that have a merged pull request into main.
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr view")
    case "$*" in
      *statusCheckRollup*)
        printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"%s","baseRefName":"%s","headRefName":"%s","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}\n' "$GH_HEAD" "$GH_BASE" "${GH_HEAD_REF:-fm/feature}" ;;
      *headRefOid*) printf '%s\n' "$GH_HEAD" ;;
      *isDraft*) printf '{"isDraft":false}\n' ;;
      *baseRefName*) printf '%s\t%s\n' "$GH_BASE" "${GH_HEAD_REF:-fm/feature}" ;;
    esac ;;
  "pr list")
    head=
    while [ "$#" -gt 0 ]; do [ "$1" = --head ] && { head=$2; break; }; shift; done
    if [ -n "$head" ] && grep -qxF "$head" "$GH_MERGED_HEADS"; then echo 1; else echo 0; fi ;;
  "pr merge") printf 'merged\n' ;;
  "api graphql") printf 'state=MERGED\nmerged=true\nqueued=false\nbase=%s\n' "$GH_BASE" ;;
  "api "*)
    case "$*" in
      *check-runs*) printf '{"check_runs":[]}\n' ;;
      *rules/branches*) printf '[]\n' ;;
      *branches/*) printf '{"name":"x","protected":false,"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"off","contexts":[],"checks":[]}}}\n' ;;
      *) printf '[]\n' ;;
    esac ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/gh-axi" <<'EOF'
#!/bin/bash
printf 'pull_request:\n  number: %s\n  state: merged\n' "$3"
EOF
chmod +x "$T/fakebin/gh-axi"
cat > "$T/pass-lint.sh" <<'EOF'
#!/usr/bin/env bash
echo "checks-lint: PASS"
EOF
chmod +x "$T/pass-lint.sh"
export GH_LOG=$T/gh.log GH_MERGED_HEADS=$T/merged-heads GH_HEAD=$HEAD_SHA

# One merge attempt: <case> <pr-number> <base> <project-dir>.
merge_case() {
  local id=$1 n=$2 base=$3 project=$4 wt=$T/wt-$1
  git init -q "$wt" && git -C "$wt" commit -q --allow-empty -m wt
  git -C "$wt" update-ref refs/remotes/origin/main "$(git -C "$wt" rev-parse HEAD)"
  printf 'window=jg-%s\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\n' "$id" "$wt" "$project" > "$H/state/$id.meta"
  : > "$GH_LOG"
  env JG_ROOT_OVERRIDE="$REPO" JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" \
    JG_CONFIG_OVERRIDE="$H/config" JG_PR_MERGE_CHECKS_LINT="$T/pass-lint.sh" GH_BASE="$base" \
    PATH="$T/fakebin:$PATH" "$REPO/bin/jg-pr-merge.sh" "$id" "$U/$n" 2>&1
}
merged_called() { grep -q '^pr merge ' "$GH_LOG"; }

# 1. release/c-5 shipped (its release pull request merged) and release/c-6 is the
# open branch: the merge is refused before it runs.
printf 'release/c-5\n' > "$GH_MERGED_HEADS"
mkproject "$T/p1" release/c-5 release/c-6
out=$(merge_case shipped-a 598 release/c-5 "$T/p1"); rc=$?
log "merge into shipped release/c-5 with release/c-6 open (rc=$rc): $(printf '%s' "$out" | grep -m1 'already shipped')"
[ "$rc" -ne 0 ] || fail "a merge into a shipped release branch was allowed"
merged_called && fail "gh pr merge ran for a shipped release branch"
case "$out" in *"release/c-5 already shipped"*"the open release branch is release/c-6"*) ;; *) fail "the refusal does not name the shipped and open branches: $out" ;; esac
case "$out" in *"gh pr edit 598 --base release/c-6"*) ;; *) fail "the refusal does not print the exact retarget command: $out" ;; esac

# 2. release/c-5 is older than release/c-6 but never shipped: it still takes work.
: > "$GH_MERGED_HEADS"
out=$(merge_case unshipped-e 604 release/c-5 "$T/p1"); rc=$?
log "merge into unshipped release/c-5 with release/c-6 open (rc=$rc): $(printf '%s' "$out" | grep -m1 '^verified: .* is merged')"
[ "$rc" -eq 0 ] || fail "a merge into a release branch that never shipped was refused: $out"
merged_called || fail "gh pr merge never ran for the unshipped release branch"
case "$out" in *"already shipped"*) fail "an unshipped release branch was called shipped: $out" ;; esac

# 3. The open release branch merges as before.
out=$(merge_case open-b 601 release/c-6 "$T/p1"); rc=$?
log "merge into release/c-6, the open branch (rc=$rc): $(printf '%s' "$out" | grep -m1 '^verified: .* is merged')"
[ "$rc" -eq 0 ] || fail "a merge into the open release branch was refused: $out"
merged_called || fail "gh pr merge never ran for the open release branch"
case "$out" in *"already shipped"*) fail "the open release branch was called shipped: $out" ;; esac
grep -q '^pr merge .* --squash' "$GH_LOG" || fail "a feature pull request into the release branch was not squashed: $(grep '^pr merge ' "$GH_LOG")"
log "the feature pull request into the open release branch was squashed"

# 4. Shipped by a merged release pull request, no newer branch yet.
printf 'release/c-5\n' > "$GH_MERGED_HEADS"
mkproject "$T/p3" release/c-5
out=$(merge_case shipped-c 602 release/c-5 "$T/p3"); rc=$?
log "merge into release/c-5 after its release pull request merged (rc=$rc): $(printf '%s' "$out" | grep -m1 'already shipped')"
[ "$rc" -ne 0 ] || fail "a merge into a branch shipped by a merged release pull request was allowed"
merged_called && fail "gh pr merge ran for a branch shipped by a merged release pull request"
case "$out" in *"no newer release branch is open"*) ;; *) fail "the refusal does not say no release branch is open: $out" ;; esac
case "$out" in *"gh pr edit 602 --base"*) fail "the refusal printed a retarget command with no branch to retarget to: $out" ;; esac

# 5. The release pull request into the default branch is not touched by the guard.
out=$(GH_HEAD_REF=release/c-5 merge_case main-d 603 main "$T/p3"); rc=$?
log "merge of the release pull request into the default branch (rc=$rc): $(printf '%s' "$out" | grep -m1 '^verified: .* is merged')"
[ "$rc" -eq 0 ] || fail "the release pull request into the default branch was refused: $out"
merged_called || fail "gh pr merge never ran for the default branch"
grep -q '^pr merge .* --merge' "$GH_LOG" || fail "the release pull request was not merged with a merge commit: $(grep '^pr merge ' "$GH_LOG")"
grep -q -- '--squash' "$GH_LOG" && fail "the release pull request was squashed: $(grep '^pr merge ' "$GH_LOG")"
log "the release pull request was merged with a merge commit"

cat > "$OUT/steps.json" <<'JSON'
{"target":{"version":"jg-pr-merge.sh"},"start":"a fixture project with release/c-5 and release/c-6","steps":["merge a pull request into release/c-5 after its release pull request merged, while release/c-6 is open: refused before the merge runs, naming release/c-6 and the exact gh pr edit command","merge a pull request into release/c-5 while its release pull request has not merged: allowed, because c-5 has not shipped","merge a pull request into release/c-6: merges as before","merge into release/c-5 after its release pull request merged with no newer branch: refused, saying no release branch is open","merge of the release pull request into the default branch: unchanged"],"result":"a merge is refused only into a release branch whose release pull request merged"}
JSON
log "PASS: a merge into a shipped release branch is refused, an unshipped older one is not; the open branch and the default branch merge"

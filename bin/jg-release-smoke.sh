#!/usr/bin/env bash
# jg-release-smoke.sh - replay three real lanes through the merge path before a release goes to homes.
#
# Usage: jg-release-smoke.sh [--budget <seconds>]
#        jg-release-smoke.sh --help
#
# WHY. The 6 Nov fleet retro found that about 12 merge-path blocked lines a day
# came from release changes that passed their own tests and then met a real lane
# at merge time: a design lane, a lane of several pull requests, and a proof
# lookup. This script is the smoke for that: it replays one of each through the
# real bin/jg-pr-merge.sh, with the real bin/jg-captain-hold.sh and the real
# bin/jg-local-suite.sh receipt check behind it, over a throwaway home. It adds
# no runner of its own; only the forge (`gh`) is a recording stand-in, so it needs
# no network.
#
# LANES (each prints one `lane:` line, and any failed assertion fails the run).
#   design     A ship linked to an open [design-ux] ticket is refused, naming the
#              ticket, and nothing reaches the forge. After the pick is recorded
#              the same pull request merges; unrelated work was never held.
#   multi-pr   Three pull requests into the open release branch merge in turn,
#              each squashed. A pull request on a release branch that already
#              shipped is refused and names the open branch. The release pull
#              request into the default branch merges with a merge commit.
#   signature  Over red forge checks, a sealed local suite receipt that proves the
#              head's tree merges. A receipt edited after its run, one for another
#              tree, and one that records a failed run each refuse by name.
#
# TIME BOX. The whole run, and every merge in it, stops at --budget seconds
# (default 120, or JG_RELEASE_SMOKE_BUDGET). A run over its budget fails and says
# which lane it was in. Typical wall time is a few seconds.
#
# EXIT. 0 when all three lanes held, 1 when a lane failed or the budget ran out,
# 2 on a usage error. A missing tool (git, jq, tasks-axi) fails the run naming it,
# because a smoke that skipped a lane proved nothing about it. The last line is
# `release smoke: PASS|FAIL ... seconds=<n>`. JG_RELEASE_SMOKE_KEEP=1 keeps the
# scratch directory for inspection and prints its path.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO=${JG_RELEASE_SMOKE_REPO:-$(cd "$SCRIPT_DIR/.." && pwd)}

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '$d'
}

BUDGET=${JG_RELEASE_SMOKE_BUDGET:-120}
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --budget) shift; BUDGET=${1:-} ;;
    *) echo "jg-release-smoke: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift || true
done
case "$BUDGET" in ''|*[!0-9]*|0) echo "jg-release-smoke: --budget needs whole seconds above 0" >&2; exit 2 ;; esac

LANE=setup
verdict() {  # PASS|FAIL <detail>
  printf 'release smoke: %s %s seconds=%s\n' "$1" "$2" "$SECONDS"
}
fail() {
  printf 'FAIL [%s]: %s\n' "$LANE" "$*" >&2
  verdict FAIL "lane=$LANE"
  exit 1
}

for tool in git jq tasks-axi timeout; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not installed, so the lanes that need it cannot be replayed"
done

T=$(mktemp -d "${TMPDIR:-/tmp}/jg-release-smoke.XXXXXX") || fail "cannot create a scratch directory"
cleanup() {
  if [ "${JG_RELEASE_SMOKE_KEEP:-0}" = 1 ]; then
    echo "release smoke: scratch kept at $T"
  else
    rm -rf -- "$T"
  fi
}
trap cleanup EXIT
export GIT_AUTHOR_NAME=smoke GIT_AUTHOR_EMAIL=smoke@example.invalid
export GIT_COMMITTER_NAME=smoke GIT_COMMITTER_EMAIL=smoke@example.invalid
export HOME=$T/user-home
mkdir -p "$HOME"
unset TASKS_AXI_FILE TASKS_AXI_BACKEND
export JG_TASK_PRIORITY_CHECK=/nonexistent

H=$T/home
FAKE=$T/fakebin
mkdir -p "$H/config" "$T/merge-config" "$H/state" "$H/data" "$FAKE"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$H/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
printf '#!/usr/bin/env bash\necho "checks-lint: PASS"\n' > "$T/pass-lint.sh"
chmod +x "$T/pass-lint.sh"
printf 'Use the compact layout.\n' > "$T/pick.txt"

# The recording forge. GH_BASE and GH_HEAD_REF shape the pull request, GH_CONCLUSION
# its one check, GH_HEAD its head commit, GH_TREE that commit's tree, and
# $GH_MERGED_HEADS lists the release heads that have a merged pull request.
cat > "$FAKE/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr view")
    case "$*" in
      *statusCheckRollup*)
        printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"%s","baseRefName":"%s","headRefName":"%s","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"%s"}]}\n' "$GH_HEAD" "$GH_BASE" "${GH_HEAD_REF:-fm/feature}" "${GH_CONCLUSION:-SUCCESS}" ;;
      *headRefOid*) printf '%s\n' "$GH_HEAD" ;;
      *isDraft*) printf '{"isDraft":false}\n' ;;
      *baseRefName*) printf '%s\n' "$GH_BASE" ;;
    esac ;;
  "pr list")
    head=
    while [ "$#" -gt 0 ]; do [ "$1" = --head ] && { head=$2; break; }; shift; done
    if [ -n "$head" ] && grep -qxF "$head" "$GH_MERGED_HEADS"; then echo 1; else echo 0; fi ;;
  "pr merge") printf 'merged\n' ;;
  "api graphql") printf 'state=MERGED\nmerged=true\nqueued=false\nbase=%s\n' "$GH_BASE" ;;
  "api "*)
    case "$*" in
      *commits/*) printf '%s\n' "$GH_TREE" ;;
      *check-runs*) printf '{"check_runs":[]}\n' ;;
      *rules/branches*) printf '[]\n' ;;
      *branches/*) printf '{"name":"x","protected":false,"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"off","contexts":[],"checks":[]}}}\n' ;;
      *) printf '[]\n' ;;
    esac ;;
esac
exit 0
EOF
cat > "$FAKE/gh-axi" <<'EOF'
#!/bin/bash
printf 'pull_request:\n  number: %s\n  state: merged\n' "$3"
EOF
chmod +x "$FAKE/gh" "$FAKE/gh-axi"
export GH_LOG=$T/gh.log GH_MERGED_HEADS=$T/merged-heads GH_HEAD=0123456789abcdef0123456789abcdef01234567
export GH_TREE=1111111111111111111111111111111111111111 GH_CONCLUSION=SUCCESS
: > "$GH_MERGED_HEADS"
URL=https://github.com/acme/thing/pull

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

# Time box: no single step may outlive what is left of the budget.
left() {
  local n=$((BUDGET - SECONDS))
  [ "$n" -gt 0 ] || fail "the $BUDGET second budget ran out"
  printf '%s\n' "$n"
}

hold() {  # <captain-hold args...>
  timeout "$(left)" env JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" \
    JG_CONFIG_OVERRIDE="$H/config" PATH="$FAKE:$PATH" "$REPO/bin/jg-captain-hold.sh" "$@"
}
tasks() { (cd "$H" && timeout "$(left)" tasks-axi "$@"); }

# merge <id> <pr-number> <base> <project> [<extra meta line>]: one real merge attempt.
# Sets MERGE_OUT and MERGE_RC; MERGE_CALLED says whether the forge saw a merge.
merge() {
  local id=$1 n=$2 base=$3 project=$4 wt=$T/wt-$1
  git init -q "$wt" && git -C "$wt" commit -q --allow-empty -m wt
  git -C "$wt" update-ref refs/remotes/origin/main "$(git -C "$wt" rev-parse HEAD)"
  printf 'window=jg-%s\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\n' "$id" "$wt" "$project" > "$H/state/$id.meta"
  : > "$GH_LOG"
  MERGE_OUT=$(timeout "$(left)" env JG_ROOT_OVERRIDE="$REPO" JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" \
    JG_DATA_OVERRIDE="$H/data" JG_CONFIG_OVERRIDE="$T/merge-config" JG_PR_MERGE_CHECKS_LINT="$T/pass-lint.sh" \
    JG_POST_MERGE_CI_DEADLINE=0 GH_BASE="$base" PATH="$FAKE:$PATH" \
    "$REPO/bin/jg-pr-merge.sh" "$id" "$URL/$n" 2>&1)
  MERGE_RC=$?
  if grep -q '^pr merge ' "$GH_LOG"; then MERGE_CALLED=1; else MERGE_CALLED=0; fi
}
must_refuse() {  # <what> <needle>
  [ "$MERGE_RC" -ne 0 ] || fail "$1: the merge was allowed: $MERGE_OUT"
  [ "$MERGE_CALLED" -eq 0 ] || fail "$1: a refused merge still reached the forge"
  case "$MERGE_OUT" in *"$2"*) ;; *) fail "$1: the refusal does not say \"$2\": $MERGE_OUT" ;; esac
}
must_merge() {  # <what>
  [ "$MERGE_RC" -eq 0 ] || fail "$1: the merge was refused: $MERGE_OUT"
  [ "$MERGE_CALLED" -eq 1 ] || fail "$1: the merge never reached the forge"
}

# ---- lane 1: design -------------------------------------------------------
LANE=design
mkproject "$T/p-design" release/c-6
tasks add dz1 "[design-ux] Tickets page design" --kind ship --repo sample >/dev/null || fail "cannot file the design ticket"
tasks add sa1 "Build the tickets page" --kind ship --repo sample --body "linked-to: dz1" >/dev/null || fail "cannot file the linked ship"
tasks add su1 "Fix the footer" --kind ship --repo sample >/dev/null || fail "cannot file the unrelated ship"
GH_HEAD_REF=fm/sa1 merge sa1 201 release/c-6 "$T/p-design"
must_refuse "linked ship with an open design pick" "dz1"
merge su1 202 release/c-6 "$T/p-design"
must_merge "unrelated ship while a design pick is open"
hold hold dz1 --reason "captain must pick" >/dev/null 2>&1 || fail "cannot hold the design ticket"
hold answer dz1 --decision-file "$T/pick.txt" --release >/dev/null 2>&1 || fail "cannot record the design pick"
merge sa1 201 release/c-6 "$T/p-design"
must_merge "linked ship after the pick was recorded"
echo "lane: design ok - linked merge refused naming dz1, unrelated merge moved, merged after the recorded pick"

# ---- lane 2: multi-pr -----------------------------------------------------
LANE=multi-pr
printf 'release/c-5\n' > "$GH_MERGED_HEADS"
mkproject "$T/p-multi" release/c-5 release/c-6
for n in 301 302 303; do
  merge "mp-$n" "$n" release/c-6 "$T/p-multi"
  must_merge "pull request $n into the open release branch"
  grep -q '^pr merge .* --squash' "$GH_LOG" || fail "pull request $n into the release branch was not squashed"
done
merge mp-stranded 304 release/c-5 "$T/p-multi"
must_refuse "pull request on a shipped release branch" "release/c-6"
GH_HEAD_REF=release/c-6 merge mp-release 305 main "$T/p-multi"
must_merge "the release pull request into the default branch"
grep -q '^pr merge .* --merge' "$GH_LOG" || fail "the release pull request was not merged with a merge commit"
echo "lane: multi-pr ok - three squashed, shipped branch refused naming release/c-6, release pull request merged"

# ---- lane 3: signature ----------------------------------------------------
LANE=signature
: > "$GH_MERGED_HEADS"
mkproject "$T/p-sig" release/c-6
seal() {  # <id> <head> <tree> <exit> [tamper]
  local f=$H/state/$1.local-suite d
  {
    printf 'schema=1\ntask=%s\nhead=%s\ntree=%s\n' "$1" "$2" "$3"
    printf 'suite=jg-test-run --all + jg-lint\nexit=%s\n' "$4"
    printf 'started_at=1700000000\nended_at=1700000042\nwall_seconds=42\nshards=1\nlog=%s\n' "$T/run.log"
  } > "$f"
  d=$(sed '/^seal=/d' "$f" | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')
  printf 'seal=sha256:%s\n' "$d" >> "$f"
  [ -z "${5:-}" ] || sed -i 's/^wall_seconds=42$/wall_seconds=1/' "$f"
}
export GH_CONCLUSION=FAILURE
seal sig-ok "$GH_HEAD" "$GH_TREE" 0
GH_HEAD_REF=fm/sig-ok merge sig-ok 401 release/c-6 "$T/p-sig"
must_merge "sealed receipt over red checks"
case "$MERGE_OUT" in *"local suite receipt proves head"*) ;; *) fail "the merge did not name the receipt as its proof: $MERGE_OUT" ;; esac
seal sig-edit "$GH_HEAD" "$GH_TREE" 0 tamper
merge sig-edit 402 release/c-6 "$T/p-sig"
must_refuse "receipt edited after its run" "seal does not verify"
seal sig-tree "$GH_HEAD" 2222222222222222222222222222222222222222 0
merge sig-tree 403 release/c-6 "$T/p-sig"
must_refuse "receipt for another tree" "not the tree"
seal sig-red "$GH_HEAD" "$GH_TREE" 1
merge sig-red 404 release/c-6 "$T/p-sig"
must_refuse "receipt of a failed run" "exited 1"
echo "lane: signature ok - sealed receipt merged over red checks; edited, wrong-tree and failed-run receipts each refused by name"

LANE="done"
verdict PASS "lanes=3"

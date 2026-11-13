#!/usr/bin/env bash
# Integration test for bin/jg-release-tag.sh and the merge-outcome record that runs it.
#
# T1 A recorded release merge creates the tag and release page once, named by the
#    release branch with the pull request title and URL and the included pull
#    request titles in the notes; a second run creates nothing; and a project
#    that already tags its releases with its own scheme gets no second tag.
# T2 The same merge writes one line to the home's release record, a second run
#    adds none, and bin/jg-live-claim.sh then lets a `live:` claim for that tag
#    stand, naming the pull requests the release carries.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TAG="$ROOT/bin/jg-release-tag.sh"
OUTCOME_LIB="$ROOT/bin/jg-merge-outcome-lib.sh"
TMP_ROOT=$(jg_test_tmproot jg-release-tag-tests)

# A forge that answers from files and records every release it is asked to create.
make_gh() {  # <dir>
  mkdir -p "$1"
  cat > "$1/gh" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "pr view") printf 'MERGED\tmain\trelease/c-6\tRelease c-6 to main\t%s\n' "$FAKE_GH_SHA"; exit 0 ;;
  "repo view") echo main; exit 0 ;;
  "pr list") printf -- '7\t- Add the thing (https://github.com/o/r/pull/7)\n'; exit 0 ;;
  "release view")
    [ -f "$FAKE_GH_DIR/released-$3" ] && { echo "https://github.com/o/r/releases/tag/$3"; exit 0; }
    exit 1 ;;
  "release create")
    printf '%s\n' "$*" >> "$FAKE_GH_DIR/creates"
    : > "$FAKE_GH_DIR/released-$3"
    echo "https://github.com/o/r/releases/tag/$3"; exit 0 ;;
esac
[ "${1:-}" = api ] && { cat "$FAKE_GH_DIR/tags"; exit 0; }
exit 1
SH
  chmod +x "$1/gh"
}

new_world() {  # <name> -> world dir with a project clone that has release/c-6
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/home/state" "$w/home/config" "$w/gh" "$w/project"
  make_gh "$w/bin"
  git init -q -b main "$w/project"
  git -C "$w/project" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m c1
  git -C "$w/project" branch release/c-6
  : > "$w/gh/tags"
  printf 'project=%s\n' "$w/project" > "$w/home/state/task-r.meta"
  printf '%s\n' "$w"
}

record_merge() {  # <world>
  local w=$1
  (cd "$w/home" && PATH="$w/bin:$PATH" FAKE_GH_DIR="$w/gh" FAKE_GH_SHA=0123456789abcdef0123456789abcdef01234567 \
    JG_HOME="$w/home" JG_STATE_OVERRIDE="$w/home/state" JG_CONFIG_OVERRIDE="$w/home/config" bash -c '
      . "$1"
      jg_merge_outcome_report "$2" "$2/state" task-r https://github.com/o/r/pull/9 self attended
    ' _ "$OUTCOME_LIB" "$w/home" 2>&1)
}

test_release_merge_is_tagged_once() {
  local w out creates
  w=$(new_world t1)
  jg_git_identity fmtest fmtest@example.com

  out=$(record_merge "$w")
  assert_contains "$out" "release tag: created c-6 at 0123456789abcdef0123456789abcdef01234567: https://github.com/o/r/releases/tag/c-6" \
    "the recorded release merge creates the release and shows its URL"
  creates=$(cat "$w/gh/creates")
  assert_contains "$creates" "release create c-6 " "the tag is named by the release branch"
  assert_contains "$creates" "Release pull request: Release c-6 to main (https://github.com/o/r/pull/9)" \
    "the notes carry the release pull request title and URL"
  assert_contains "$creates" "- Add the thing (https://github.com/o/r/pull/7)" \
    "the notes list the included pull requests"

  out=$(PATH="$w/bin:$PATH" FAKE_GH_DIR="$w/gh" FAKE_GH_SHA=0123456789abcdef0123456789abcdef01234567 \
    "$TAG" https://github.com/o/r/pull/9 "$w/project" 2>&1)
  assert_contains "$out" "c-6 already released, nothing to do" "a second run is a no-op"
  assert_equals 1 "$(grep -c "^release create" "$w/gh/creates")" "exactly one release was ever created"

  w=$(new_world t1-own)
  printf 'v0.5.3\nv0.5.2\n' > "$w/gh/tags"
  out=$(record_merge "$w")
  assert_contains "$out" "already tags its releases with its own scheme (found v0.5.3)" \
    "a project with its own tag scheme is skipped with the reason"
  [ ! -e "$w/gh/creates" ] || fail "a project with its own tag scheme must get no second tag"
  pass "T1 a release merge is tagged once, and a project with its own scheme is left alone"
}

test_release_is_recorded_for_the_live_claim() {
  local w out rec
  w=$(new_world t2)
  jg_git_identity fmtest fmtest@example.com
  record_merge "$w" >/dev/null
  rec=$(cat "$w/home/data/releases")
  assert_contains "$rec" "c-6 " "the release record names the tag"
  assert_contains "$rec" "repo=o/r commit=0123456789abcdef0123456789abcdef01234567 prs=7,9" \
    "the release record names the repository, the commit and the pull requests it carries"
  PATH="$w/bin:$PATH" FAKE_GH_DIR="$w/gh" FAKE_GH_SHA=0123456789abcdef0123456789abcdef01234567 \
    JG_HOME="$w/home" "$TAG" https://github.com/o/r/pull/9 "$w/project" >/dev/null 2>&1
  assert_equals 1 "$(grep -c '^c-6 ' "$w/home/data/releases")" "a second run adds no second line"

  printf '#!/bin/sh\nexit 0\n' > "$w/services"; chmod +x "$w/services"
  out=$(JG_HOME="$w/home" JG_STATE_OVERRIDE="$w/home/state" JG_LIVE_SERVICES_BIN="$w/services" \
    "$ROOT/bin/jg-live-claim.sh" "done" "fixed: live: c-6 @ this home; waiting: none" 2>&1)
  assert_not_contains "$out" "Landed, not in use" "a claim for a recorded release is not downgraded"
  assert_contains "$out" "carries: #7 #9" "the claim names the pull requests the recorded release carries"
  pass "T2 a release is recorded once and the live claim reads it"
}

test_release_merge_is_tagged_once
test_release_is_recorded_for_the_live_claim
echo "all jg-release-tag tests passed"

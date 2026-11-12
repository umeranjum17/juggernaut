#!/usr/bin/env bash
# Tests for the skip logic of ci.yml: bin/jg-ci-scope.sh decides which area suites a
# pull request owes, bin/jg-ci-required.sh refuses a needed suite that skipped, and
# bin/jg-ci-area-reads.sh proves the scope covers every file a suite reads. The
# failure these guard is a change to a file a suite depends on that lets the suite
# skip and the run report green (the skipped Bus service and Smoke runs on PRs 415
# and 418).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCOPE="$ROOT/bin/jg-ci-scope.sh"
REQUIRED="$ROOT/bin/jg-ci-required.sh"
READS="$ROOT/bin/jg-ci-area-reads.sh"
TMP_ROOT=$(jg_test_tmproot jg-ci-scope)

# scope_of <path...>: the scope verdict for a change touching exactly these paths.
scope_of() { printf '%s\n' "$@" | bash "$SCOPE"; }

# skipped_suite_verdict <area> <path>: pretend CI skipped the area's suite on a pull
# request that changed <path>, with every other lane passing, and run the merge gate.
skipped_suite_verdict() {
  local area=$1 path=$2 scope needs lane
  scope=$(scope_of "$path")
  case $area in bus) lane=bus ;; shell) lane=syntax ;; evals) lane=smoke ;; esac
  needs='{"invariants":{"result":"success"},"lint":{"result":"success"},"tier-ci":{"result":"success"},"bus":{"result":"success"},"syntax":{"result":"success"},"smoke":{"result":"success"},"evals":{"result":"success"}}'
  needs=$(printf '%s' "$needs" | jq -c --arg l "$lane" '.[$l].result = "skipped"')
  OUT=$(JG_CI_EVENT=pull_request JG_CI_NEEDS="$needs" \
    JG_CI_BEHAVIOR="$(printf '%s\n' "$scope" | sed -n 's/^behavior=//p')" \
    JG_CI_BUS="$(printf '%s\n' "$scope" | sed -n 's/^bus=//p')" \
    JG_CI_SHELL="$(printf '%s\n' "$scope" | sed -n 's/^shell=//p')" \
    JG_CI_EVALS="$(printf '%s\n' "$scope" | sed -n 's/^evals=//p')" bash "$REQUIRED" 2>&1)
  RC=$?
}

test_a_hidden_change_to_a_suite_dependency_is_not_skippable() {
  local row area path
  # Each row is a file the suite reads that no name match would find: the pinned
  # versions both suites read, the libraries the stack script sources, the bus doc
  # the bus suite asserts on, and the test helpers it sources.
  while IFS=' ' read -r area path; do
    [ -n "$area" ] || continue
    row="$area <- $path"
    assert_contains "$(scope_of "$path")" "$area=true" "$row: the change must owe the suite"
    skipped_suite_verdict "$area" "$path"
    [ "$RC" -ne 0 ] || fail "$row: the run went green with the suite skipped: $OUT"
  done <<'ROWS'
bus toolchain.versions
bus .github/workflows/ci.yml
evals .github/workflows/ci.yml
shell .github/workflows/ci.yml
bus bin/jg-stack.sh
bus bin/jg-kv-lib.sh
bus docs/bus-service.md
bus defaults/captain-channel
bus tests/lib.sh
bus tests/git-config-helpers.sh
bus core/brief-inherit/bin/jg-brief-inherit-lib.sh
evals toolchain.versions
evals bin/jg-lib.sh
evals defaults/captain-voice-worker.md
shell tests/jg-bus.test.sh
shell bin/backends/tmux.sh
ROWS
  pass 'a change to a file a suite reads owes that suite, and the gate refuses it skipped'
}

test_documentation_and_media_stay_cheap() {
  local path out
  for path in README.md CONTRIBUTING.md docs/architecture.md assets/hero.png; do
    out=$(scope_of "$path")
    assert_contains "$out" 'behavior=false' "$path: documentation or media must stay cheap"
    assert_contains "$out" 'bus=false' "$path: a cheap change owes no area suite"
  done
  out=$(scope_of docs/bus-service.md)
  assert_contains "$out" 'behavior=true' 'the bus doc is read by the bus suite, so it is not cheap'
  pass 'documentation and media stay cheap, except the bus doc the bus suite reads'
}

test_an_unreadable_diff_owes_every_area() {
  local out
  out=$(printf '' | bash "$SCOPE")
  assert_contains "$out" 'bus=true' 'an empty change list must owe the bus suite'
  assert_contains "$out" 'shell=true' 'an empty change list must owe the shell suite'
  assert_contains "$out" 'evals=true' 'an empty change list must owe the evals suite'
  pass 'a change list CI could not read owes every area'
}

# A fixture repository for the read trace: bin/ is inside the bus area, data/ is not.
make_trace_repo() {
  local dir=$TMP_ROOT/$1
  mkdir -p "$dir/bin" "$dir/data"
  cp "$SCOPE" "$READS" "$dir/bin/"
  printf 'inside\n' >"$dir/bin/inside.txt"
  printf 'outside\n' >"$dir/data/outside.txt"
  git -C "$dir" init -q .
  git -C "$dir" add -A
  git -C "$dir" -c user.name=t -c user.email=t@example.invalid commit -qm fixture
  printf '%s\n' "$dir"
}

test_the_read_trace_names_a_read_outside_the_scope() {
  local dir out rc=0
  dir=$(make_trace_repo trace)
  out=$("$dir/bin/jg-ci-area-reads.sh" --check bus -- cat bin/inside.txt 2>&1) || rc=$?
  if printf '%s' "$out" | grep -q 'do not update'; then
    echo 'skip: access times do not update on this filesystem, so the read trace cannot run here'
    return 0
  fi
  assert_equals 0 "$rc" "a suite that reads only in-scope files must pass: $out"
  assert_contains "$out" 'every one inside its scope' 'the pass must say what it checked'
  rc=0
  out=$("$dir/bin/jg-ci-area-reads.sh" --check bus -- cat data/outside.txt 2>&1) || rc=$?
  assert_equals 1 "$rc" "a suite that reads a file outside its scope must fail: $out"
  assert_contains "$out" 'data/outside.txt' 'the file the suite read must be named'
  rc=0
  out=$("$dir/bin/jg-ci-area-reads.sh" --check bus -- bash -c 'exit 7' 2>&1) || rc=$?
  assert_equals 7 "$rc" "a failing suite must keep its own exit status: $out"
  pass 'the read trace passes in-scope reads, names an out-of-scope read, and keeps a failing suite failing'
}

test_a_hidden_change_to_a_suite_dependency_is_not_skippable
test_documentation_and_media_stay_cheap
test_an_unreadable_diff_owes_every_area
test_the_read_trace_names_a_read_outside_the_scope

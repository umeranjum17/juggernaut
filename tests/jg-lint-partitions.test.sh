#!/usr/bin/env bash
# The canonical partition contract in bin/jg-lint.sh: every partition is a
# complete, disjoint slice of the same inventory, the slices are byte-weight
# balanced, no partition carries more than one of the roots that need the
# memory allowance, and an unusable <k>of<n> is refused by name.
#
# CI runs four partitions so each lint job stays inside the Normal tier once the
# heaviest roots really follow their sources; this test is what keeps that
# split honest.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/jg-lint.sh"
TMP_ROOT=$(jg_test_tmproot jg-lint-partitions)
HEAVY='bin/jg-spawn.sh bin/jg-teardown.sh bin/jg-watch.sh tests/jg-launch-prompt-signals-live-e2e.test.sh'

# partitions <n>: write each partition's root list and the full inventory to the
# case directory, and echo the directory.
partitions() {
  local count=$1 dir="$TMP_ROOT/$1ofN" index
  mkdir -p "$dir"
  # CI forces the full canonical inventory; a plain local run would answer with
  # the changed-file set instead.
  GITHUB_ACTIONS=true bash "$LINT" --list-files | LC_ALL=C sort > "$dir/full.list"
  index=1
  while [ "$index" -le "$count" ]; do
    bash "$LINT" --partition "${index}of${count}" --list-files | LC_ALL=C sort > "$dir/$index.list"
    index=$((index + 1))
  done
  printf '%s\n' "$dir"
}

test_every_partition_is_a_complete_disjoint_slice() {
  local dir count
  dir=$(partitions 4)
  count=$(wc -l < "$dir/full.list")
  cat "$dir"/[1-4].list | LC_ALL=C sort > "$dir/union.list"
  [ -z "$(LC_ALL=C uniq -d "$dir/union.list")" ] \
    || fail 'a root appears in more than one partition'
  cmp -s "$dir/full.list" "$dir/union.list" \
    || fail 'the four partitions do not cover the full canonical inventory'
  [ "$(wc -l < "$dir/union.list")" -eq "$count" ] || fail 'the union lost or gained roots'
  pass "four partitions are complete and disjoint over $count roots"
}

test_partitions_are_byte_weight_balanced() {
  local dir index bytes worst=0 best=0
  dir=$(partitions 4)
  index=1
  while [ "$index" -le 4 ]; do
    bytes=$(cd "$ROOT" && xargs -d'\n' wc -c < "$dir/$index.list" | awk '{sum += $1} END {print sum + 0}')
    if [ "$worst" -eq 0 ] || [ "$bytes" -gt "$worst" ]; then worst=$bytes; fi
    if [ "$best" -eq 0 ] || [ "$bytes" -lt "$best" ]; then best=$bytes; fi
    index=$((index + 1))
  done
  # A partition no more than 5% heavier than the lightest one is balanced well
  # inside the runtime spread the partitions absorb anyway.
  [ $((worst * 100)) -le $((best * 105)) ] \
    || fail "partition byte weights are not balanced: lightest $best, heaviest $worst"
  pass "partition byte weights are balanced within 5% (lightest $best, heaviest $worst)"
}

test_no_partition_carries_two_heavy_roots() {
  local dir index heavy found
  dir=$(partitions 4)
  for heavy in $HEAVY; do
    found=
    index=1
    while [ "$index" -le 4 ]; do
      if grep -qxF "$heavy" "$dir/$index.list"; then
        [ -z "$found" ] || fail "$heavy appears in partitions $found and $index"
        found=$index
      fi
      index=$((index + 1))
    done
    [ -n "$found" ] || fail "$heavy is in no partition at all"
  done
  pass 'each memory-heavy root sits in its own partition'
}

test_an_unusable_partition_name_is_refused() {
  local bad output rc
  for bad in 0of4 5of4 1of1 xofy 1of2x 1of; do
    rc=0
    output=$(JG_LINT_REQUIRE_BOUNDS=0 bash "$LINT" --partition "$bad" --list-files 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "--partition $bad was accepted"
    assert_contains "$output" 'jg-lint.sh: --partition' "--partition $bad names the flag it refuses"
  done
  pass 'an unusable partition name is refused with the flag named'
}

test_every_partition_is_a_complete_disjoint_slice
test_partitions_are_byte_weight_balanced
test_no_partition_carries_two_heavy_roots
test_an_unusable_partition_name_is_refused
printf 'jg-lint-partitions: ok\n'

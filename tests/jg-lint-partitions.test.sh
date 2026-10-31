#!/usr/bin/env bash
# bin/jg-lint.sh partitions the entire canonical lint inventory across the CI
# runners. A partition that dropped a file, repeated one, or came out empty would
# leave part of the lint silently unrun, so the split is proven here for the
# shard counts CI uses and refuses anything outside its range.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/jg-lint.sh"
TMP_ROOT=$(jg_test_tmproot jg-lint-partitions)

# list <k>of<n>: one partition's roots, exactly as CI derives them.
list() {  # <partition>
  ( cd "$ROOT" && CI=true bash "$LINT" --partition "$1" --list-files )
}

test_every_partition_is_complete_and_disjoint() {
  local n k part full all union dup
  for n in 2 4; do
    full="$TMP_ROOT/full-$n"
    all="$TMP_ROOT/all-$n"
    union="$TMP_ROOT/union-$n"
    ( cd "$ROOT" && CI=true bash "$LINT" --list-files ) > "$full" || fail "the full inventory must list for n=$n"
    : > "$all"
    for k in $(seq 1 "$n"); do
      part="$TMP_ROOT/part-$n-$k"
      list "${k}of$n" > "$part" || fail "partition ${k}of$n must list"
      [ -s "$part" ] || fail "partition ${k}of$n must not be empty"
      cat "$part" >> "$all"
    done
    LC_ALL=C sort "$all" > "$all.sorted"
    LC_ALL=C sort -u "$all" > "$union"
    dup=$(LC_ALL=C sort "$all" | uniq -d)
    [ -z "$dup" ] || fail "partitions for n=$n repeat: $dup"
    LC_ALL=C sort "$full" > "$full.sorted"
    cmp -s "$full.sorted" "$all.sorted" || fail "partitions for n=$n do not cover the full inventory"
    local total=0 count
    for k in $(seq 1 "$n"); do
      count=$(wc -l < "$TMP_ROOT/part-$n-$k" | tr -d '[:space:]')
      total=$((total + count))
    done
    [ "$total" -eq "$(wc -l < "$full" | tr -d '[:space:]')" ] \
      || fail "partitions for n=$n total $total files, not the full inventory"
  done
  pass 'every partition is complete and disjoint'
}

test_a_partition_outside_its_range_is_refused() {
  local spec out rc
  for spec in 3of2 1of9 0of4 bogus 1of2of3; do
    rc=0
    out=$(list "$spec" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] || fail "partition $spec must be refused with exit 2, got $rc"
    assert_contains "$out" 'must be <k>of<n>' "the refusal for $spec must name the accepted form"
  done
  pass 'a partition outside its range is refused'
}

test_every_partition_is_complete_and_disjoint
test_a_partition_outside_its_range_is_refused
printf 'jg-lint-partitions: ok\n'

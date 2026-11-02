#!/usr/bin/env bash
# The local suite receipt is the proof a merge lands on, so it is keyed to the
# TREE the suite read, not to the commit it ran at. Two commits that carry the
# same tree are the same proof: a body edit, a re-push of identical content, a
# squash of one change, or a base merge that leaves those files alone never
# forces a re-seal. A different tree refuses by name, and a receipt edited after
# its run refuses whatever the trees say.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUITE="$ROOT/bin/jg-local-suite.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/jg-local-suite-tree.XXXXXX") || exit 1
trap 'rm -rf -- "$WORK"' EXIT INT TERM
REPO="$WORK/repo"
STATE="$WORK/state"
mkdir -p "$STATE"
jg_git_init_commit "$REPO"

# seal_receipt <file> <task> <head> <tree> <exit>: write a schema 1 receipt whose
# seal is computed exactly as the script computes it, so a fixture can prove the
# verify path without running a suite.
seal_receipt() {  # <file> <task> <head> <tree> <exit>
  local file=$1
  {
    printf 'schema=1\n'
    printf 'task=%s\n' "$2"
    printf 'head=%s\n' "$3"
    printf 'tree=%s\n' "$4"
    printf 'suite=jg-test-run --all + jg-lint\n'
    printf 'exit=%s\n' "$5"
    printf 'started_at=0\n'
    printf 'ended_at=1\n'
    printf 'wall_seconds=1\n'
    printf 'shards=1\n'
    printf 'log=/dev/null\n'
  } > "$file"
  printf 'seal=sha256:%s\n' "$(shasum -a 256 < "$file" | awk '{print $1}')" >> "$file"
}

# verify <state-dir> <task> <head>: run verify from inside the fixture repo, so
# the tree read resolves against it.
verify() {  # <state-dir> <task> <head>
  ( cd "$REPO" && bash "$SUITE" verify "$1" "$2" "$3" )
}

TREE_A=$(git -C "$REPO" rev-parse 'HEAD^{tree}')
HEAD_A=$(git -C "$REPO" rev-parse HEAD)

# A second commit with the same tree: git allows an empty commit, and its tree is
# byte-identical to the first.
git -C "$REPO" -c user.name='Juggernaut Tests' -c user.email='tests@example.invalid' \
  commit -q --allow-empty -m 'same tree, new commit'
HEAD_B=$(git -C "$REPO" rev-parse HEAD)
[ "$HEAD_A" != "$HEAD_B" ] || fail 'the fixture must produce two different commits'
[ "$(git -C "$REPO" rev-parse 'HEAD^{tree}')" = "$TREE_A" ] \
  || fail 'the fixture commits must share one tree'

test_a_receipt_proves_the_same_tree_under_another_head() {
  seal_receipt "$STATE/task-a.local-suite" task-a "$HEAD_A" "$TREE_A" 0
  OUT=$(verify "$STATE" task-a "$HEAD_B" 2>&1)
  RC=$?
  [ "$RC" -eq 0 ] || fail "a receipt for the same tree must verify: $OUT"
  assert_contains "$OUT" "$TREE_A" 'the evidence line must name the tree it proved'
  pass 'a receipt proves the same tree under another head'
}

test_a_receipt_refuses_a_different_tree() {
  # A changed file gives the branch a different tree; the receipt must refuse by
  # naming both trees rather than falling back to the forge check gate.
  printf 'changed\n' > "$REPO/CHANGED.txt"
  git -C "$REPO" add CHANGED.txt
  git -C "$REPO" -c user.name='Juggernaut Tests' -c user.email='tests@example.invalid' \
    commit -q -m 'other tree'
  HEAD_C=$(git -C "$REPO" rev-parse HEAD)
  TREE_C=$(git -C "$REPO" rev-parse 'HEAD^{tree}')
  seal_receipt "$STATE/task-b.local-suite" task-b "$HEAD_A" "$TREE_A" 0
  OUT=$(verify "$STATE" task-b "$HEAD_C" 2>&1)
  RC=$?
  [ "$RC" -eq 1 ] || fail "a receipt for another tree must refuse: $OUT"
  assert_contains "$OUT" "$TREE_A" 'the refusal must name the proved tree'
  assert_contains "$OUT" "$TREE_C" 'the refusal must name the candidate tree'
  pass 'a receipt refuses a different tree'
}

test_a_receipt_edited_after_the_run_refuses() {
  seal_receipt "$STATE/task-c.local-suite" task-c "$HEAD_A" "$TREE_A" 0
  sed -i.bak 's/^wall_seconds=1$/wall_seconds=2/' "$STATE/task-c.local-suite"
  rm -f "$STATE/task-c.local-suite.bak"
  OUT=$(verify "$STATE" task-c "$HEAD_A" 2>&1)
  RC=$?
  [ "$RC" -eq 1 ] || fail "an edited receipt must refuse: $OUT"
  assert_contains "$OUT" 'seal does not verify' 'the refusal must name the seal'
  pass 'a receipt edited after the run refuses'
}

test_a_failed_run_refuses_even_for_the_same_tree() {
  seal_receipt "$STATE/task-d.local-suite" task-d "$HEAD_A" "$TREE_A" 1
  OUT=$(verify "$STATE" task-d "$HEAD_B" 2>&1)
  RC=$?
  [ "$RC" -eq 1 ] || fail "a nonzero suite run must refuse: $OUT"
  assert_contains "$OUT" 'exited 1' 'the refusal must name the exit status'
  pass 'a failed run refuses even for the same tree'
}

test_no_receipt_leaves_the_forge_gate_in_charge() {
  OUT=$(verify "$STATE" task-e "$HEAD_A" 2>&1)
  RC=$?
  [ "$RC" -eq 3 ] || fail "a missing receipt must report 'no receipt' (3), got $RC: $OUT"
  assert_contains "$OUT" 'forge check gate' 'the note must say the forge gate applies'
  pass 'no receipt leaves the forge gate in charge'
}

test_a_legacy_receipt_still_compares_heads() {
  # A receipt written before tree keying has no tree= line; it keeps the old
  # head rule instead of becoming unusable.
  {
    printf 'schema=1\n'
    printf 'task=task-f\n'
    printf 'head=%s\n' "$HEAD_A"
    printf 'suite=jg-test-run --all + jg-lint\n'
    printf 'exit=0\n'
    printf 'started_at=0\n'
    printf 'ended_at=1\n'
    printf 'wall_seconds=1\n'
    printf 'shards=1\n'
    printf 'log=/dev/null\n'
  } > "$STATE/task-f.local-suite"
  printf 'seal=sha256:%s\n' "$(shasum -a 256 < "$STATE/task-f.local-suite" | awk '{print $1}')" \
    >> "$STATE/task-f.local-suite"
  OUT=$(verify "$STATE" task-f "$HEAD_B" 2>&1)
  RC=$?
  [ "$RC" -eq 1 ] || fail "a legacy receipt for another head must refuse: $OUT"
  assert_contains "$OUT" "not the pull request head" 'the refusal must name the head rule'
  pass 'a legacy receipt still compares heads'
}

test_a_receipt_proves_the_same_tree_under_another_head
test_a_receipt_refuses_a_different_tree
test_a_receipt_edited_after_the_run_refuses
test_a_failed_run_refuses_even_for_the_same_tree
test_no_receipt_leaves_the_forge_gate_in_charge
test_a_legacy_receipt_still_compares_heads
printf 'jg-local-suite-tree: ok\n'

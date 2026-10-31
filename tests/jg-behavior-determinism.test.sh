#!/usr/bin/env bash
# tests/jg-behavior-determinism.test.sh - the same content must give the same
# verdict twice.
#
# Pull requests kept going red on scripts that had nothing to do with them, and a
# rerun of the same shard could flip the verdict. Each script below is one that
# failed on the portable serial shards (3, 5 and 6) for a reason unrelated to the
# change under it, so each is run twice in a row here:
#   - two different verdicts are the reported flake, and the message names the
#     script and both verdicts;
#   - two identical failures are still a failure, because a check that cannot go
#     red on a broken script is no check at all.
# The pass value is two runs of a script agreeing, which is what a shard verdict
# has to mean. A whole shard is far past this suite's budget to run twice, so the
# check takes the scripts that went red, not the shard around them.
# tests/jg-board-gate.test.sh and tests/jg-board-answers.test.sh read the card key
# `jg-question-card.sh post` prints on stdout after #313 put the card-rule
# measurement on stderr; tests/jg-squad-lead-dormant.test.sh lost a whole-second
# mtime race. Both are fixed, and this is the check that keeps them fixed.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-behavior-determinism)
CANDIDATES=(
  tests/jg-board-gate.test.sh
  tests/jg-board-answers.test.sh
  tests/jg-squad-lead-dormant.test.sh
  tests/jg-lease-command-lock.test.sh
)

run_once() {  # <script> <log> -> the script's exit code
  local script=$1 log=$2
  bash "$ROOT/$script" >"$log" 2>&1
  printf '%s\n' "$?"
}

test_each_previously_flaky_script_gives_one_verdict_twice() {
  local script first second a b
  for script in "${CANDIDATES[@]}"; do
    [ -f "$ROOT/$script" ] || fail "the determinism check names a script that is gone: $script"
    a=$TMP_ROOT/$(printf '%s' "$script" | tr '/' '-').1.log
    b=$TMP_ROOT/$(printf '%s' "$script" | tr '/' '-').2.log
    first=$(run_once "$script" "$a")
    second=$(run_once "$script" "$b")
    if [ "$first" != "$second" ]; then
      fail "$script gave two different verdicts on identical content: run 1 exit=$first, run 2 exit=$second"$'\n'"--- run 1 ---"$'\n'"$(cat "$a")"$'\n'"--- run 2 ---"$'\n'"$(cat "$b")"
    fi
    [ "$first" -eq 0 ] || fail "$script failed both times (exit=$first), so its verdict is not the pass value"$'\n'"$(cat "$a")"
  done
  pass "every previously flaky script gives the same verdict twice in a row"
}

test_each_previously_flaky_script_gives_one_verdict_twice

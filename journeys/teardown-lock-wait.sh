#!/usr/bin/env bash
# done-done journey: a cleanup waits for the project's slot lock instead of refusing a landed lane, driven by the real
# bin/jg-teardown.sh and the real core/lead-sweep/lead-sweep.sh. The "before" leg runs the previous commit's teardown
# against a lock held for 5 seconds and shows the old refusal; the "after" leg runs this tree's teardown against a lock
# held for 70 seconds (a cleanup stub) and shows the lane cleaned within the one wait, a dead holder taken over, and the
# sweep running as its own job past the watcher's 30-second check limit.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/oldbin" "$T/before"
cp -R "$REPO/bin/." "$T/oldbin/"
git -C "$REPO" show HEAD~1:bin/jg-teardown.sh > "$T/oldbin/jg-teardown.sh" || exit 1
{
  echo "== before (previous commit's teardown), lock held 5 s"
  DONE_DONE_EVIDENCE_ROOT=$T/before JG_TEARDOWN_UNDER_TEST=$T/oldbin/jg-teardown.sh JG_LOCK_WAIT_TEST_HOLD=5 bash "$REPO/tests/jg-teardown-lock-wait.test.sh" 2>&1 | grep -E "^(ok|FAIL): a:" 
  echo "== after (this tree), lock held 70 s"
  bash "$REPO/tests/jg-teardown-lock-wait.test.sh" 2>&1
} | tee "$OUT/teardown-lock-wait.txt"
grep -q '^FAIL: a: the cleanup waited' "$OUT/teardown-lock-wait.txt" || { echo "FAIL: the old teardown did not refuse"; exit 1; }
grep -q '^all checks passed' "$OUT/teardown-lock-wait.txt" || { echo "FAIL: the new teardown run did not pass"; exit 1; }
cat > "$OUT/steps.json" <<'J'
{"target":{"version":"jg-teardown.sh, lead-sweep.sh"},"start":"a landed lane whose project slot lock is held by a live cleanup","steps":["run the previous commit's teardown with the lock held 5 seconds","run this tree's teardown with the lock held 70 seconds","run it with a dead holder and with a holder that outlasts the wait","run the sweep check with a 35-second teardown stub"],"result":"the old teardown refuses and leaves the record; this tree waits, cleans the lane within one wait, takes over a dead holder, refuses only after the wait, and the sweep job outlives the 30-second check limit"}
J
echo PASS

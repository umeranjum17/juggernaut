#!/usr/bin/env bash
# done-done journey: tearing down a task whose state/<id>.meta is already gone
# (the watcher's cleanup ran first) says so and exits 0, driven by the real
# bin/jg-teardown.sh. The "before" leg runs the base branch's script from a copy
# of bin/ and shows the old wrong refusal; the "after" leg runs this tree's script,
# shows the new message and the removed receipt and probe files, and shows that a
# record which is not a regular file keeps its refusal.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
BASE=${JG_TEARDOWN_BASE_REF:-origin/release/c-14}
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/state" "$T/data" "$T/config" "$T/oldbin"
cp -R "$REPO/bin/." "$T/oldbin/"
git -C "$REPO" show "$BASE:bin/jg-teardown.sh" > "$T/oldbin/jg-teardown.sh" || exit 1
run() { # <script> <log>
  JG_ROOT_OVERRIDE="$REPO" JG_STATE_OVERRIDE="$T/state" JG_DATA_OVERRIDE="$T/data" \
    JG_CONFIG_OVERRIDE="$T/config" bash "$1" task-y1 >"$2" 2>&1
  echo "exit=$?" >>"$2"
}
leftovers() { : >"$T/state/task-y1.run-receipt.json"; : >"$T/state/task-y1.probe-at"; }
{
  echo "== before (base $BASE): record missing, receipt and probe left behind"
  leftovers; run "$T/oldbin/jg-teardown.sh" "$T/before.log"; cat "$T/before.log"
  echo "== after (this tree): record missing, receipt and probe left behind"
  leftovers; run "$REPO/bin/jg-teardown.sh" "$T/after.log"; cat "$T/after.log"
  ls "$T/state"
  echo "== after: a record that is not a regular file keeps its refusal"
  mkdir "$T/state/task-y1.meta"; run "$REPO/bin/jg-teardown.sh" "$T/dir.log"; cat "$T/dir.log"
} | tee "$OUT/teardown-missing-record.txt"
grep -q 'not a regular file' "$T/before.log" || { echo "FAIL: base did not show the old refusal"; exit 1; }
if ! { grep -q 'already cleaned up' "$T/after.log" && grep -q 'exit=0' "$T/after.log"; }; then echo "FAIL: new message or exit missing"; exit 1; fi
[ ! -e "$T/state/task-y1.run-receipt.json" ] && [ ! -e "$T/state/task-y1.probe-at" ] || { echo "FAIL: leftovers kept"; exit 1; }
if ! { grep -q 'not a regular file' "$T/dir.log" && ! grep -q 'exit=0' "$T/dir.log"; }; then echo "FAIL: directory record accepted"; exit 1; fi

cat > "$OUT/steps.json" <<'J'
{"target":{"version":"jg-teardown.sh"},"start":"a task whose state/<id>.meta is gone, with a run-receipt and probe file left behind","steps":["run bin/jg-teardown.sh on the base branch script","run bin/jg-teardown.sh from this tree","run it again with a directory standing where the record should be"],"result":"the base script refuses with a wrong 'not a regular file' message; this tree says the task is already cleaned up, exits 0 and removes the leftovers; a directory record keeps its refusal"}
J
echo "PASS"

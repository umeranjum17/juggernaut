#!/usr/bin/env bash
# done-done journey: the state folder diet (jg8-j19). A fixture task leaves one file of every per-task kind that
# bin/jg-task-files-lib.sh lists; the real bin/jg-teardown.sh cleans the task up and the
# journey counts the kinds (the suffix after state/<id>.) before and after. Slices 1 to 4 remove 32 kinds (one is a directory).
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
# shellcheck source=bin/jg-task-files-lib.sh disable=SC1091
. "$REPO/bin/jg-task-files-lib.sh"
T=$(mktemp -d)
trap 'chmod -R u+w -- "$T" 2>/dev/null; rm -rf -- "$T"' EXIT
mkdir -p "$T/state" "$T/data" "$T/config"
kinds() { find "$T/state" -maxdepth 1 -name 'task-z1.*' -printf '%f\n' | sed 's/^task-z1\.//' | sort; }
for k in $JG_TASK_FILE_KINDS_RETIRED; do printf '1\n' > "$T/state/task-z1.$k"; done
for k in $JG_TASK_DIR_KINDS_RETIRED; do mkdir "$T/state/task-z1.$k"; : > "$T/state/task-z1.$k/commit-msg"; chmod a-w "$T/state/task-z1.$k"; done
kinds > "$T/before.txt"
JG_ROOT_OVERRIDE="$REPO" JG_STATE_OVERRIDE="$T/state" JG_DATA_OVERRIDE="$T/data" JG_CONFIG_OVERRIDE="$T/config" \
  bash "$REPO/bin/jg-teardown.sh" task-z1 > "$T/teardown.log" 2>&1; rc=$?
kinds > "$T/after.txt"
b=$(wc -l < "$T/before.txt"); a=$(wc -l < "$T/after.txt")
{
  echo "teardown exit=$rc"; cat "$T/teardown.log"
  echo "== kinds before ($b)"; cat "$T/before.txt"
  echo "== kinds after ($a)"; cat "$T/after.txt"
  echo "kinds per task: $b -> $a"
} | tee "$OUT/state-folder-diet.txt"
[ "$rc" -eq 0 ] || { echo "FAIL: teardown exit $rc"; exit 1; }
read -ra kinds_listed <<< "$JG_TASK_FILE_KINDS_RETIRED $JG_TASK_DIR_KINDS_RETIRED"; want=${#kinds_listed[@]}
[ $((b - a)) -eq "$want" ] || { echo "FAIL: $((b - a)) kinds removed, want $want"; exit 1; }
cat > "$OUT/steps.json" <<'J'
{"target":{"version":"jg-teardown.sh"},"start":"a cleaned-up task with a file of every listed per-task kind in its state folder","steps":["count the kinds of file the task has","run bin/jg-teardown.sh on it","count the kinds again"],"result":"every listed kind is gone; none is left"}
J
echo "PASS"

#!/usr/bin/env bash
# run-proof.sh: the wait-identity proof for done-done. Runs the wait-timers hook journey and the full timer journey
# against a read-only fork checkout (default ~/juggernaut) and keeps one combined plain transcript as evidence.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
mkdir -p "$evidence"
export JG_TEST_FORK=${JG_TEST_FORK:-$HOME/juggernaut}
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
mkdir -p "$d/fork" "$d/user" "$d/tmp" "$d/addons"
cp -a "$JG_TEST_FORK/bin" "$JG_TEST_FORK/tests" "$d/fork/"
cp -a "$repo/." "$d/addons/"
cp "$repo/wait-timers/tests/jg-wait-timers.test.sh" "$d/fork/tests/"
{
  echo "== hook journey"
  bash "$repo/wait-timers/tests/wait-timers-hook-e2e.sh"
  echo "== full timer journey"
  (cd "$d/fork" && env -u JG_TASK_ID JG_HOME="$d/fork" JG_ADDONS_DIR="$d/addons" HOME="$d/user" TMPDIR="$d/tmp" bash tests/jg-wait-timers.test.sh)
} 2>&1 | tee "$evidence/wait-timers-identity.txt"
test "${PIPESTATUS[0]}" -eq 0
cat > "$evidence/steps.json" <<'J'
{"target":{"version":"juggernaut bin/jg-watch.sh from a read-only fork checkout, with this feature's wait-timers library"},
 "start":"a disposable juggernaut home whose lane has two open decisions, one without an [at=] stamp, and an unkeyed blocker",
 "steps":["run the real watcher over the feature library until the wait is overdue and read the id and source in the escalation","resolve one decision, add a working line, and read which wait stays open and its new identity","resolve the last decision and add an unkeyed blocker and read its identity"],
 "result":"escalations print id=<home/task/generation/key> and the exact source; a resolution closes only its own wait; a later working line closes nothing; the transcript ends with ok"}
J

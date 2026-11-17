#!/usr/bin/env bash
# done-done journey: drive the real core/lead-sweep/lead-sweep.sh against a fixture home (resolved lanes landed and not
# landed), through tests/jg-lead-sweep-end-states.test.sh, and write the transcript into the evidence folder.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/${RUN_ID:-lead-sweep-end-states}.log
st=0
bash "$REPO/tests/jg-lead-sweep-end-states.test.sh" >"$LOG" 2>&1 || st=1
grep -q '^FAIL' "$LOG" && st=1
[ "$(grep -c '^ok: ' "$LOG")" -ge 6 ] || st=1
cat "$LOG"
# The capacity path uses the central alert owner; keep its caller and delivery regressions in the same sealed proof.
for command in 'bash core/lead-sweep/tests/lead-sweep.test.sh' 'bash journeys/alert.sh' 'bash bin/jg-lint.sh' 'bash bin/jg-doc-audience-check.sh'; do
  name=${command##*/}; name=${name%.sh}
  bash -c "$command" > "$OUT/$name.log" 2>&1 || st=1
  cat "$OUT/$name.log"
done
cat >"$OUT/steps.json" <<'J'
{"target":{"version":"juggernaut core/lead-sweep/lead-sweep.sh at this commit"},
 "start":"an isolated home with synthetic Git branches, resolved and paused lanes and the real central alert owner",
 "steps":["sweep a landed resolved lane and an unlanded resolved lane twice","refuse cleanup and change its reason","return a lost-slot result then command success","refuse park then return success","change a lane generation and retain a legacy lane","fail and repair a retention destination","add unread input before a declared park","run the full lead-sweep and central alert integration journeys, lint and documentation checks"],
 "result":"landed cleanup runs unforced; a refusal retains an original-age, generation-bound lead action and branch; repeated alerts deliver the changed reason; lost slot and command success do not prove reusable capacity; unread input protects the lane; no actual pool or live lane is used"}
J
exit "$st"

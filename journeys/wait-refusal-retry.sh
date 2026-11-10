#!/usr/bin/env bash
# done-done journey: a wait refusal is never left stale. A lane refused for a red trunk lands with no hand step once the red is gone,
# even while every landing-check sweep finds another landing running, because the start a finished landing chains tries it again;
# a lane whose red still holds stays waiting and never restarts itself in a loop (10 Nov 2026: three lanes sat hours on a red cleared
# long before). The real bin/jg-trunk.sh and core/trunk-landing run over real git repositories in a fixture home
# (tests/jg-trunk-retry.test.sh owns the cases).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
env -u JG_TASK_ID bash "$root/tests/jg-trunk-retry.test.sh" > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a fixture home with a local-trunk project and a trunk pinned red",
 "steps": ["a land-next lane reports done on the red trunk and is refused: it waits", "the red clears hours later while another landing runs at every check sweep, and a new lane reports done: the check starts nothing", "that landing ends and starts the next one, as every landing does", "a second lane is refused on a red that still holds, its refusal ages past the backoff, and two finished landings start the next one in turn"],
 "result": "the lane whose red cleared is on the trunk with the new lane and no hand step; the lane whose red holds was judged once more, still waits, and did not restart itself in a loop"}
JSON
exit "$rc"

#!/usr/bin/env bash
# done-done journey: the local trunk flow. One proved commit per ticket lands on a local trunk by
# compare-and-swap and the home moves to it inside the same command; eight unsafe landings (a second
# commit, a moved tip, a failing lander gate, an open linked decision, away mode, a protected path, a
# red trunk, a trunk a lane moved) refuse and leave the trunk unchanged; each open captain call changes
# behaviour only through config/trunk-policy; a smoke landing keeps the home on the last fully green
# commit until verify passes; and release pushes release/c-N+1 without force and opens one PR.
# Real bin/jg-trunk.sh, bin/jg-trunk-live-home.sh and the shared landing gates run over real git repositories,
# a bare origin and a recording forge (tests/jg-trunk.test.sh owns the cases).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-trunk.test.sh" > "$out" 2>&1 || rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a fixture home with a project, a local bare origin, a trunk created at the release tip, a recording hold reader, a recording live hook and a recording forge",
 "steps": ["land a lane with one commit: the trunk moves to it, one landing row is logged and the live hook runs at that commit", "land with the bundled hook against a clone of the project: the home checkout is fast-forwarded; a dirty home exits 3 with the commit still landed", "try a lane with two commits, a lane on a moved tip, a failing gate, a linked open decision, away mode, a protected path, a red trunk and a trunk a lane moved: each refuses and the trunk does not move", "change protected-landing, away-landing and trunk-owner in config/trunk-policy: behaviour changes with no code change", "land under a smoke gate: the home stays on the last fully green commit; a red verify sets the red flag; only a fixes-red commit lands; a green verify clears it", "release a batch: release/c-5 holds the trunk tip, exactly one PR is opened, and an empty batch, a repeat and a red trunk refuse"],
 "result": "a proved commit is on the local trunk and the home runs it inside one command, every unsafe landing is refused with the reason, and the batch goes out as one release PR without a force push"}
JSON
exit "$rc"

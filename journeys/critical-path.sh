#!/usr/bin/env bash
# done-done journey: the migration's critical path. While a part of config/migration-card's
# critical= list (nats, accounts, wake, inbox) is not live, a ship for any later step, or with no
# Migration row at all, is refused at spawn before any worktree or task record exists; a ship for
# the first part not live, for non-migration work (Migration row: none) and a ship the captain
# overrides in his own words (--off-critical-path, quoted in the brief) all launch.
# Real bin/jg-brief.sh, bin/jg-spawn.sh and bin/jg-critical-path.sh run over a fixture project with a
# stand-in probe (tests/jg-critical-path.test.sh owns the gate cases, tests/jg-critical-path-spawn.test.sh the spawn cases).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
{ bash "$root/tests/jg-critical-path.test.sh" && bash "$root/tests/jg-critical-path-spawn.test.sh"; } > "$out" 2>&1 || rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a fixture home whose config/migration-card lists critical=nats,accounts,wake,inbox for the fixture project, with a probe that reports nats live and accounts pending",
 "steps": ["scaffold and spawn a ship for Migration row deletions: refused, naming accounts, what its probe measured and its pull request", "spawn ships for Migration row accounts and for Migration row none: both launch and the task record keeps the row", "spawn a ship whose brief has no Migration row line: refused", "spawn the deletions ship with --off-critical-path and the brief quoting the same words: launches and records critical_override=", "flip the probe to accounts live: the refusal names wake; flip every part live: nothing is refused", "an unconfigured home, another project and a scout are unchanged, and a relaunch is not gated again"],
 "result": "a ship that is off the migration's critical path is refused before any worktree or record exists, unless it works on the first part not live, declares non-migration work, or carries the captain's quoted override"}
JSON
exit "$rc"

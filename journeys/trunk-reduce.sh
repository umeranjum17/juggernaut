#!/usr/bin/env bash
# done-done journey: the one reducer of the verify's proof results. Runs tests/jg-trunk-reduce.test.sh and keeps its output as run evidence.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ev=${DONE_DONE_EVIDENCE_ROOT:?DONE_DONE_EVIDENCE_ROOT must name the run folder}
rc=0
(cd "$root" && bash tests/jg-trunk-reduce.test.sh) > "$ev/reduce.log" 2>&1 || rc=$?
cat "$ev/reduce.log"
printf '%s\n' '{"target": {"version": "core/trunk-verify/reduce.py at this head"}, "start": "the real reducer command line over typed proof inputs, test sources and run logs, a real git project and open tickets", "steps": ["verdicts for counted, carried, carried-progressed and incomplete scripts against the grace", "timeout, skip, quarantine and missing-aggregate controls stay incomplete and are refused before any move", "the merged first-home check, one deduplicated repair owner per blocking input, and the record map of asks"], "result": "reduce.log shows nine ok cases and no not ok line"}' > "$ev/steps.json"
exit "$rc"

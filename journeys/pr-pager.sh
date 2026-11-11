#!/usr/bin/env bash
# done-done journey: every open pull request pages its lead until it merges or closes. The real pager and
# wiring run over disposable homes with a forge stub (tests/jg-pr-pager.test.sh owns the cases).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-pr-pager.test.sh" > "$out" 2>&1 || rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a disposable lead home and a disposable Main home, a forge stub with open pull requests (one 30 minutes old with a red check, one of another lead's repository) and a due release with no pull request",
 "steps": ["run the real pager over the lead home and require one page with the address, the check's name and the next step", "run it again inside the hour and 60 minutes later and require no page, then a second page", "reach 6 pages with no change and require one note to Main, none after", "merge or close the pull request and require no page and no episode", "run Main and require no page for the lead's repository, and one page for a due release with no pull request", "require that bin/jg-captain-say.sh is never called"],
 "result": "each open pull request pages its owning lead hourly with its next step, climbs to Main after 6 unchanged pages, stops when the pull request merges or closes, and never speaks to the captain"}
JSON
exit "$rc"

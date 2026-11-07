#!/usr/bin/env bash
# End-to-end: bin/jg-ci-rerun.sh over the real jg-tasks-axi.sh backlog and a recorded forge. A red run is refused
# with no ticket, refused with a ticket that has no root-cause note (the filed text only mentions the word), and
# re-run once the ticket body holds a "root-cause:" line; a green run re-runs without a ticket; --failed passes on.
# journeys/ci-rerun-refusal.sh is the done-done journey for the same script and is selected with this file.
# Usage: tests/jg-ci-rerun.test.sh
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/user TMPDIR=$d
H=$d/home
mkdir -p "$HOME" "$H/state" "$H/data" "$H/config"
ln -s "$ROOT/bin" "$H/bin"
# shellcheck source=core/lib/beads-test-env.sh
. "$ROOT/core/lib/beads-test-env.sh"
core_beads_home "$ROOT" "$H"
cat > "$d/gh" <<'STUB'
#!/usr/bin/env bash
# api repos/ex/r/actions/runs/<id> --jq .conclusion: 21 and 23 are red, 22 is green; run rerun <id> -R <repo> [--failed] is recorded.
case $1 in
  api) case $2 in repos/ex/r/actions/runs/21|repos/ex/r/actions/runs/23) echo failure ;; repos/ex/r/actions/runs/22) echo success ;; *) exit 1 ;; esac ;;
  run) shift; echo "$*" >> "$RERUNS" ;;
esac
STUB
chmod +x "$d/gh"
export RERUNS=$d/reruns JG_HOME=$H JG_CI_RERUN_GH=$d/gh
: > "$RERUNS"
rerun() { "$H/bin/jg-ci-rerun.sh" "$@" 2>"$d/err"; }
ok() { echo "ok: $1"; }
no() { echo "FAIL: $1" >&2; cat "$d/err" >&2; exit 1; }
rerun 21 --repo ex/r && no "a red run with no ticket was re-run"
grep -q 'no root-cause ticket yet' "$d/err" || no "the refusal does not say there is no ticket"
[ ! -s "$RERUNS" ] || no "a re-run was issued"
ok "a red run with no ticket is refused"
body="CI went red: CI, run 21 (failure). Find the root cause.
Never re-run; fix the root cause. bin/jg-ci-rerun.sh refuses a re-run of this run until this ticket carries a 'root-cause:' note."
"$H/bin/jg-tasks-axi.sh" add ci-red-run-21 "[blocker] CI red: CI shard 2: find the root cause" --kind ship --body "$body" >/dev/null
rerun 21 --repo ex/r && no "a red run with a note-less ticket was re-run"
grep -q 'no root-cause note' "$d/err" || no "the refusal does not say the note is missing"
[ ! -s "$RERUNS" ] || no "a re-run was issued"
ok "a red run whose ticket has no root-cause note is refused"
"$H/bin/jg-tasks-axi.sh" update ci-red-run-21 --body "$body
root-cause: the shard reads a clock that the fixture never freezes" >/dev/null
rerun 21 --repo ex/r --failed || no "a red run with a root-cause note was refused"
[ "$(cat "$RERUNS")" = "rerun 21 -R ex/r --failed" ] || no "want one re-run of 21 with --failed, got: $(cat "$RERUNS")"
ok "a red run is re-run once the ticket carries a root-cause note"
: > "$RERUNS"
rerun 22 --repo ex/r || no "a green run was refused"
[ "$(cat "$RERUNS")" = "rerun 22 -R ex/r" ] || no "want one re-run of 22, got: $(cat "$RERUNS")"
ok "a green run is re-run without a ticket"
rerun 23 --repo ex/r && no "a second red run rode on the first ticket"
ok "a note on one ticket does not clear another red run"
rerun 99 --repo ex/r && no "an unreadable run was re-run"
ok "an unreadable run is refused"
echo "all jg-ci-rerun checks passed"

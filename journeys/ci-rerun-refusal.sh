#!/usr/bin/env bash
# done-done journey: a red CI run is never re-run to see if it passes. The real bin/jg-ci-rerun.sh runs over the
# real jg-backlog.sh backlog and a recorded forge. Shows: (1) a red run with no ticket is refused; (2) a red run
# whose ticket has no "root-cause:" line is refused; (3) with that line the run is re-run once; (4) a green run
# is re-run without a ticket. tests/jg-ci-rerun.test.sh owns the edge cases.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
LOG=$OUT/ci-rerun-refusal.txt
: > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
fail() { log "FAIL: $*"; exit 1; }
export HOME=$T/user-home
mkdir -p "$HOME"
H=$T/home
mkdir -p "$H/state" "$H/data" "$H/config"
ln -s "$REPO/bin" "$H/bin"
# shellcheck source=core/lib/beads-test-env.sh
. "$REPO/core/lib/beads-test-env.sh"
core_beads_home "$REPO" "$H"
cat > "$T/gh" <<'STUB'
#!/usr/bin/env bash
# api repos/ex/r/actions/runs/<id> --jq .conclusion: 21 is red, 22 is green; run rerun <id> -R <repo> is recorded.
case $1 in
  api) case $2 in repos/ex/r/actions/runs/21) echo failure ;; repos/ex/r/actions/runs/22) echo success ;; *) exit 1 ;; esac ;;
  run) shift; echo "$*" >> "$RERUNS" ;;
esac
STUB
chmod +x "$T/gh"
export RERUNS=$T/reruns JG_HOME=$H JG_CI_RERUN_GH=$T/gh
: > "$RERUNS"
log "run: $(basename "$OUT") at $(git -C "$REPO" rev-parse --short HEAD)"
log "step 1: red run 21 with no ticket"
"$H/bin/jg-ci-rerun.sh" 21 --repo ex/r >> "$LOG" 2>&1 && fail "a red run with no ticket was re-run"
log "step 2: the watcher's ticket exists, but names no root cause"
body="CI went red: CI, run 21 (failure). Find the root cause.
Never re-run; fix the root cause. bin/jg-ci-rerun.sh refuses a re-run of this run until this ticket carries a 'root-cause:' note."
"$H/bin/jg-backlog.sh" add ci-red-run-21 "[blocker] CI red: CI shard 2: find the root cause" --kind ship --body "$body" >/dev/null || fail "cannot file the ticket"
"$H/bin/jg-ci-rerun.sh" 21 --repo ex/r >> "$LOG" 2>&1 && fail "a red run with a note-less ticket was re-run"
log "step 3: the ticket names the root cause"
"$H/bin/jg-backlog.sh" update ci-red-run-21 --body "$body
root-cause: the shard reads a clock the fixture never freezes" >/dev/null || fail "cannot add the note"
"$H/bin/jg-ci-rerun.sh" 21 --repo ex/r >> "$LOG" 2>&1 || fail "a red run with a root-cause note was refused"
[ "$(cat "$RERUNS")" = "rerun 21 -R ex/r" ] || fail "want exactly one re-run of 21, got: $(cat "$RERUNS")"
log "re-run issued: $(cat "$RERUNS")"
log "step 4: green run 22 needs no ticket"
"$H/bin/jg-ci-rerun.sh" 22 --repo ex/r >> "$LOG" 2>&1 || fail "a green run was refused"
log "re-runs issued in total: $(grep -c . "$RERUNS")"
printf '{"target":{"version":"jg-ci-rerun.sh over the real backlog"},"start":"a home with a backlog and a recorded forge holding a red run and a green run","steps":["re-run the red run with no ticket","file its ticket without a root-cause line and re-run it","add a root-cause line and re-run it","re-run the green run"],"result":"a red run is re-run only after its ticket names the root cause"}\n' > "$OUT/steps.json"
log "PASS: a red run is re-run only after its ticket names the root cause"

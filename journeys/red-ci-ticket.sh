#!/usr/bin/env bash
# done-done journey: a red CI run files a root-cause ticket instead of a re-run, driven by the real
# merge-on-green.sh watcher check, the real bin/jg-backlog.sh and the real Beads backlog. The forge is
# the recorded gh-axi stub in core/merge-on-green/tests/fixtures/red-ci-ticket, so no network is used.
# Shows: (1) one poll files one ticket per red run and prints one alert each; (2) the ticket in the backlog
# carries the run id, URL, failing job and first failing log line; (3) a second poll files none.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
LOG=$OUT/red-ci-ticket.txt
: > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
fail() { log "FAIL: $*"; exit 1; }
export HOME=$T/user-home
mkdir -p "$HOME"
H=$T/home
mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects/r"
ln -s "$REPO/bin" "$H/bin"
# shellcheck source=core/lib/beads-test-env.sh
. "$REPO/core/lib/beads-test-env.sh"
core_beads_home "$REPO" "$H"
printf -- '- r [direct-PR +yolo] - fixture project (ex/r) (added 2026-11-04)\n' > "$H/data/projects.md"
git -C "$H/projects/r" init -q && git -C "$H/projects/r" remote add origin https://github.com/ex/r.git
export JG_STALE_PR_GH=false JG_RED_CI_GH=$REPO/core/merge-on-green/tests/fixtures/red-ci-ticket/gh-axi JG_CHECK_TIMEOUT=60 JG_HOME=$H
poll() { "$REPO/core/merge-on-green/merge-on-green.sh" check "$H" 2>&1 | grep '^red-ci-ticket:'; }

log "run: $(basename "$OUT") at $(git -C "$REPO" rev-parse --short HEAD)"
log "step 1: first watcher poll over two red runs and one green run"
first=$(poll); log "$first"
[ "$(printf '%s\n' "$first" | grep -c .)" = 2 ] || fail "want two alerts, got: $first"
log "step 2: the backlog ticket for run 11"
"$H/bin/jg-backlog.sh" show ci-red-run-11 > "$OUT/ticket-11.txt" 2>&1 || fail "ticket ci-red-run-11 is not in the backlog"
cat "$OUT/ticket-11.txt" >> "$LOG"
for want in '[blocker] CI red: CI behaviour shard 2: find the root cause' 'Run: 11' 'actions/runs/11' 'Failing job: behaviour shard 2' 'not ok 2 journey reads the wake' 'Never re-run; fix the root cause'; do
  grep -qF -- "$want" "$OUT/ticket-11.txt" || fail "ticket 11 lacks: $want"
done
log "step 3: second poll files no ticket"
[ -z "$(poll)" ] || fail "the second poll alerted again"
for green in 12 13; do "$H/bin/jg-backlog.sh" show "ci-red-run-$green" >/dev/null 2>&1 && fail "a green run was ticketed: $green"; done
printf '{"target":{"version":"red-ci-ticket.sh via merge-on-green.sh check"},"start":"a home with a project whose default branch and an open PR have red CI runs","steps":["the watcher polls the project","a ticket is filed for each red run","the second poll files nothing"],"result":"one root-cause ticket per red run, none for green runs, none on the repeat poll"}\n' > "$OUT/steps.json"
log "PASS: red CI runs filed root-cause tickets once"

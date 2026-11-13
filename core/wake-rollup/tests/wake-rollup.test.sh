#!/usr/bin/env bash
# Journey through the real caller (bin/jg-wake-lib.sh jg_wake_append) in a disposable home:
# a) 100 routine events of one Squad Lead home in one window reach Main's queue as no row, and the check prints ONE digest
#    line for that home once the window closed, with the counts; the next check prints nothing;
# b) a P0 event (needs-decision, failed, blocked, security) of the same home rings at once, as an ordinary queued row;
# c) a worker's own status stream (no squad_lead meta) is never held;
# d) a second home gets its own digest line, not merged into the first;
# e) before the window closes the check prints nothing; config/wake-rollup-off restores today's wakes;
# f) the board file holds the day's rang, held and digests counts.
# Usage: wake-rollup/tests/wake-rollup.test.sh
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
H=$d/home; mkdir -p "$H/state" "$H/data" "$H/config"
printf 'kind=squad_lead\n' > "$H/state/lead-a.meta"; printf 'kind=squad_lead\n' > "$H/state/lead-b.meta"; printf 'kind=ship\n' > "$H/state/ship-1.meta"
fail() { echo "FAIL: $*" >&2; exit 1; }
# shellcheck disable=SC2016
append() { # <key> <status line>: write the line to the stream, then raise the wake the way the watcher does
  printf '%s\n' "$2" >> "$H/state/$1"
  env -u JG_WAKE_ROUTING JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" bash -c '. "$1/bin/jg-wake-lib.sh"; jg_wake_append signal "$2" "$3"' _ "$ROOT" "$1" "$2"
}
check() { JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_WAKE_ROLLUP_NOW="$1" bash "$ROOT/core/wake-rollup/rollup.sh" check "$H"; }
queued() { [ -f "$H/state/.wake-queue" ] || { echo 0; return; }; grep -cP "\t$1\t" "$H/state/.wake-queue" || true; }

t0=$(date +%s)
for i in $(seq 1 100); do append lead-a.status "working [at=$t0]: step $i"; done
append lead-b.status "done [at=$t0]: lane landed"
[ "$(queued lead-a.status)" -eq 0 ] || fail "a routine lead event reached the queue ($(queued lead-a.status) rows)"
[ -z "$(check $((t0 + 60)))" ] || fail "a digest came before the window closed"
out=$(check $((t0 + 700)))
[ "$(printf '%s\n' "$out" | grep -c '^wake-rollup: lead-a:')" -eq 1 ] || fail "lead-a did not get exactly one digest: $out"
printf '%s\n' "$out" | grep -q 'lead-a: 100 events in 10 min (working 100)' || fail "digest counts wrong: $out"
printf '%s\n' "$out" | grep -q 'lead-b: 1 events in 10 min (done 1)' || fail "lead-b has no digest of its own: $out"
[ -z "$(check $((t0 + 800)))" ] || fail "an empty window printed a digest"

append lead-a.status "blocked [at=$t0]: needs a key"
append lead-a.status "failed [at=$t0]: build red"
append lead-a.status "needs-decision [at=$t0]: pick one"
[ "$(queued lead-a.status)" -ge 3 ] || fail "P0 events did not reach the queue"
append ship-1.status "working [at=$t0]: coding"
[ "$(queued ship-1.status)" -ge 1 ] || fail "a worker stream was held"
[ -z "$(check $((t0 + 2000)))" ] || fail "a P0 or worker event was held for a digest"

touch "$H/config/wake-rollup-off"; before=$(queued lead-a.status)
append lead-a.status "working [at=$t0]: again"
[ "$(queued lead-a.status)" -gt "$before" ] || fail "the off switch did not restore the wake"
rm -f "$H/config/wake-rollup-off"

JG_HOME="$H" bash "$ROOT/core/wake-rollup/rollup.sh" board "$H"
row=$(sed -n 2p "$H/data/wake-rollup/wakes-per-day.tsv")
[ "$(printf '%s' "$row" | cut -f3)" = 101 ] && [ "$(printf '%s' "$row" | cut -f4)" = 2 ] || fail "board row wrong: $row"
echo "PASS: wake-rollup (100 events -> 1 digest, P0 rings, board counts)"

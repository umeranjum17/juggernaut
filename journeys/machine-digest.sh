#!/usr/bin/env bash
# done-done journey: the bounded machine digest (core/fleet-status/digest.sh). The behavior test drives it over a fixture home, a missing home,
# a small cap and a machine that does not answer; the real digest then reads the supervising home (JG_HOME) and writes what it printed.
# The comparison (core/fleet-status/compare.sh) then checks that view against the home's source records: every difference listed and explained.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/${DONE_DONE_RUN_ID:-run}.log
cd "$REPO" || exit 1
{ bash tests/jg-fleet-digest.test.sh && bash tests/jg-fleet-compare.test.sh && echo "--- the real digest of ${JG_HOME:-$REPO}" && bash core/fleet-status/digest.sh "${JG_HOME:-$REPO}" | tee "$OUT/${DONE_DONE_RUN_ID:-run}.live-digest.txt" && echo "--- the view compared with the source records of ${JG_HOME:-$REPO}" && bash core/fleet-status/compare.sh "${JG_HOME:-$REPO}" | tee "$OUT/${DONE_DONE_RUN_ID:-run}.live-compare.txt"; } > "$LOG" 2>&1 || { cat "$LOG"; exit 1; }
bytes=$(wc -c < "$OUT/${DONE_DONE_RUN_ID:-run}.live-digest.txt")
[ "$bytes" -le 3500 ] || { echo "the real digest is $bytes bytes, over its 3500 byte cap" >&2; exit 1; }
cat "$LOG"
cat > "$OUT/steps.json" <<J
{"target":{"version":"core/fleet-status/digest.sh"},"start":"a fixture home with one stale alert record, and the supervising home with its real records","steps":["print the digest of the fixture home","print the digest of a missing home","print it under a 700 byte cap","print it with one machine that cannot answer in its bound","print the digest of the supervising home","compare that view with the supervising home's source records"],"result":"the comparison lists every difference with its reason and exits 0 only when none is unexplained; every stale and unknown machine is named first, a missing home lists all 24 machines as unknown, a small cap cuts the last lines and counts what it cut, and the supervising home's digest is $bytes bytes, under its 3500 byte cap"}
J

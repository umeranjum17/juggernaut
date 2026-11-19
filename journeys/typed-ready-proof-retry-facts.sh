#!/usr/bin/env bash
# done-done journey: the typed ready, proof, retry and cursor facts of bin/jg-facts-lib.sh, read through the real
# `bin/jg-machine-guard.sh fact`, each for a legal and an illegal case, with the real guard edge, reference-transaction hook and lead sweep.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/${RUN_ID:-run}.log
cd "$REPO" || exit 1
{ bash tests/jg-typed-facts.test.sh && bash tests/jg-lead-sweep-end-states.test.sh && bash tests/jg-trunk-queue.test.sh; } > "$LOG" 2>&1 || { cat "$LOG"; exit 1; }
cat > "$OUT/steps.json" <<'J'
{"target":{"version":"bin/jg-machine-guard.sh fact with bin/jg-facts-lib.sh"},"start":"a fixture home with the shipped presence table, a fixture trunk repository with the installed hook, and lanes with no status line","steps":["read the guard policy of a legal and an illegal move, in shadow and enforced","read the proof-reuse switch and the trunk-writer capability and compare them with the real hook","read a lane's ready report and a queue's flush","read the lead sweep's relaunch budget and let the real sweep act","read a wake stream's positions with and without a marker"],"result":"each fact prints typed key and value lines; the real guard, hook, sweep and queue take the step the fact names, and the existing enforcement, sweep and queue journeys still pass"}
J

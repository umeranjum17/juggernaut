#!/usr/bin/env bash
set -eu
out=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}/routed-captain-order.log
bash tests/jg-routed-captain-order.test.sh > "$out" 2>&1 || { cat "$out"; exit 1; }
cat "$out"

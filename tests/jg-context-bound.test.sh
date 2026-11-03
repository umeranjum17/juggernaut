#!/usr/bin/env bash
# The captain's words come back verbatim after a compact, on a synthetic transcript with no model call. It also owns journeys/context-bound-at-wake.sh, so the changed-test map selects it.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
mkdir "$d/state"; t=$d/s.jsonl
for i in 1 2 3; do printf '{"type":"user","message":{"content":"the word for note %s is W%s"}}\n' "$i" "$i"; done >"$t"
printf '{"type":"user","message":{"content":"check: x needs a handling turn now"}}\n' >>"$t"
out=$(printf '{"source":"compact","transcript_path":"%s"}' "$t" | python3 "$ROOT/bin/jg-context-bound.py" emit --state "$d/state")
for want in "$t" "note 1 is W1" "note 3 is W3"; do
  [[ $out == *"$want"* ]] || { echo "FAIL: missing $want"; exit 1; }
done
[[ $out != *"handling turn"* ]] || { echo "FAIL: a wake was repeated as the captain"; exit 1; }
[ -s "$d/state/context-bound.log" ] || { echo "FAIL: compaction not logged"; exit 1; }
echo "context-bound: captain words verbatim, wake not repeated, compaction logged"

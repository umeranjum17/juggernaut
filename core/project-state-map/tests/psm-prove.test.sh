#!/usr/bin/env bash
# Host test table for psm-prove.sh: a fixture map with planted false lines over the fixture project.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
prove=$here/../bin/psm-prove.sh
fixture=$here/fixture-project
map=$here/fixture-map.json
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
fail=0
want() { # want <label> <got> <expected>
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got $2 want $3"; fail=1; fi
}

before=$(cd "$fixture" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
bash "$prove" "$map" "$fixture" --out "$d/p.json"
after=$(cd "$fixture" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
want 'schema is psm.proved.v1' "$(jq -r .schema "$d/p.json")" 'psm.proved.v1'
want 'true machines and parts are kept' "$(jq -r '[.machines[].id, .machinery[].id] | join(" ")' "$d/p.json")" 'ticket-stage gate-state stuck-flag http poll'
want 'planted false machine and part are dropped' "$(jq -r '[.proof.dropped[] | select(.reason | test("dropped$")) | .where] | join(" ")' "$d/p.json")" 'm:phantom p:queue'
want 'planted false lines are counted by reason' "$(jq -r '[.proof.dropped[].reason] | sort | join(",")' "$d/p.json")" 'file not found,line not in the file,move names a state the machine does not list,no evidence left, machine dropped,no evidence left, part dropped,text not on that line,text not on that line'
want 'checked, kept and dropped add up' "$(jq -r '"\(.proof.checked) \(.proof.kept) \(.proof.dropped_count)"' "$d/p.json")" '10 6 7'
want 'a false line on a true machine drops the line only' "$(jq -r '.machines[0] | "\(.evidence | length) \(.moves | length)"' "$d/p.json")" '1 3'
want 'the project is never changed' "$before" "$after"

# The same map and project give the same answer.
bash "$prove" "$map" "$fixture" > "$d/again.json"
want 'same map gives the same proof' "$(sha256sum < "$d/again.json")" "$(sha256sum < "$d/p.json")"

# Whitespace in the cited text is folded; a case change is not a match.
jq '.machinery = [{id: "w", name: "w", kind: "timer", evidence: [{file: "app/board.js", line: 3, text: "setInterval(load,   30000)"}, {file: "app/board.js", line: 3, text: "SETINTERVAL"}]}] | .machines = []' "$map" > "$d/ws.json"
want 'folded whitespace matches, other case does not' "$(bash "$prove" "$d/ws.json" "$fixture" | jq -r '"\(.proof.kept) \(.proof.dropped_count)"')" '1 1'

# A path outside the project and a secret-looking file are never read.
mkdir -p "$d/proj/sub" && printf 'oneOf(\x27a\x27, \x27b\x27)\n' > "$d/outside.txt" && printf 'TOKEN=abc123\n' > "$d/proj/.env" && printf 'x = 1\n' > "$d/proj/sub/ok.js"
ln -s ../../outside.txt "$d/proj/sub/link.js"
jq '.machinery = [{id: "e", name: "e", kind: "other", evidence: [{file: "../outside.txt", line: 1, text: "oneOf("}, {file: ".env", line: 1, text: "TOKEN=abc123"}, {file: "sub/link.js", line: 1, text: "oneOf("}, {file: "sub/ok.js", line: 1, text: "x = 1"}]}] | .machines = []' "$map" > "$d/esc.json"
want 'outside, secret and linked files are refused' "$(bash "$prove" "$d/esc.json" "$d/proj" | jq -r '[.proof.dropped[] | select(.file != "") | .reason] | join(",")')" 'path outside the project,secret-looking file, never read,file not found'

# A map that breaks the format is refused with every problem listed.
printf '{"schema": "psm.map.v1", "machines": [{"id": "a", "name": "A", "kind": "weird", "states": [], "evidence": []}], "machinery": [], "not_read": []}\n' > "$d/bad.json"
want 'broken map refused with every problem' "$(bash "$prove" "$d/bad.json" "$fixture" 2>&1 >/dev/null | tr '\n' '|')" 'psm-prove: the map breaks psm.map.v1:|  machine 0: kind must be explicit or hidden|  machine 0: states must be a non-empty list of names|  machine 0: evidence must be a non-empty list|'
printf '{"schema": "other"}\n' > "$d/other.json"
want 'wrong schema refused' "$(bash "$prove" "$d/other.json" "$fixture" 2>&1 >/dev/null | tail -1)" '  schema must be psm.map.v1'
printf 'not json' > "$d/nj.json"
want 'non-JSON refused' "$(bash "$prove" "$d/nj.json" "$fixture" 2>&1 >/dev/null || true)" "psm-prove: $d/nj.json is not JSON"
want 'missing directory refused' "$(bash "$prove" "$map" "$d/none" 2>&1 >/dev/null || true)" "psm-prove: not a directory: $d/none"
want 'unknown argument refused' "$(bash "$prove" "$map" "$fixture" --bogus 2>&1 >/dev/null || true)" 'psm-prove: unknown argument --bogus'
exit "$fail"

#!/usr/bin/env bash
# Host test table for psm-read.sh: replayed replies, opt-in, spend cap and bad replies. No real model is called.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
read_=$here/../bin/psm-read.sh
search=$here/../bin/psm-search.sh
fixture=$here/fixture-project
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
fail=0
want() { # want <label> <got> <expected>
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got $2 want $3"; fail=1; fi
}
bash "$search" "$fixture" --out "$d/hits.json"
# The saved reply is the fixture map (planted false lines included) as a model would send it, in a code fence.
{ echo '```json'; jq -c '{machines, machinery, not_read}' "$here/fixture-map.json"; echo '```'; } > "$d/fixture-reply.txt"

# A stub model: records the prompt, counts calls, answers with the saved reply.
cat > "$d/model" <<S
#!/usr/bin/env bash
cat > "$d/prompt"; echo x >> "$d/calls"; cat "$d/fixture-reply.txt"
S
chmod +x "$d/model"; : > "$d/calls"
calls() { wc -l < "$d/calls" | tr -d ' '; }

bash "$read_" "$d/hits.json" --replay "$d/fixture-reply.txt" --out "$d/map.json"
want 'replayed reply gives a map with the hit key' "$(jq -r --slurpfile h "$d/hits.json" '"\(.schema) \(.tree == $h[0].tree) \(.hit_hash == $h[0].hit_hash)"' "$d/map.json")" 'psm.map.v1 true true'
want 'the map has the replied machines and parts' "$(jq -r '"\(.machines | length) \(.machinery | length) \(.read.mode)"' "$d/map.json")" '4 3 replay'
want 'the replayed map goes through the proof' "$(bash "$here/../bin/psm-prove.sh" "$d/map.json" "$fixture" | jq -r '"\(.proof.kept) \(.proof.dropped_count)"')" '6 7'
bash "$read_" "$d/hits.json" --replay "$d/fixture-reply.txt" > "$d/again.json"
want 'replay needs no opt-in and sends nothing' "$(calls)" '0'
want 'same hits and reply give the same map' "$(sha256sum < "$d/again.json")" "$(sha256sum < "$d/map.json")"

# A live read needs the project's opt-in.
want 'no opt-in, no call' "$(PSM_READ_COMMAND="$d/model" bash "$read_" "$d/hits.json" 2>&1 >/dev/null | grep -c 'needs --opt-in for this project')" '1'
want 'no opt-in made no call' "$(calls)" '0'

# With the opt-in the prompt holds numbered excerpts and the format, never a secret-looking file.
mkdir -p "$d/proj" && cp -r "$fixture/." "$d/proj/" && printf 'stage = oneOf("a", "b")\n' > "$d/proj/.env"
jq '.hits += [{file: ".env", line: 1, passes: ["p1"], text: "stage = oneOf"}]' "$d/hits.json" > "$d/hits-env.json"
PSM_READ_COMMAND="$d/model" bash "$read_" "$d/hits-env.json" --project-dir "$d/proj" --opt-in --out "$d/live.json"
want 'live read makes one call and records the mode' "$(calls) $(jq -r .read.mode "$d/live.json")" '1 live'
want 'the prompt names the fixture states' "$(grep -c "oneOf('queued', 'working', 'review', 'done')" "$d/prompt")" '1'
want 'the prompt asks for the map format' "$(grep -c '"machinery":\[' "$d/prompt")" '1'
want 'a secret-looking file is never sent' "$(grep -c 'stage = oneOf("a"' "$d/prompt" || true)" '0'

# The spend cap stops a big run before any call; a cap of 0 turns the step off.
: > "$d/calls"
want 'over the cap is refused' "$(PSM_READ_COMMAND="$d/model" bash "$read_" "$d/hits.json" --opt-in --max-usd 0.001 2>&1 >/dev/null | grep -c 'is over the cap .0.001; no call was made')" '1'
want 'cap of 0 is refused' "$(PSM_READ_COMMAND="$d/model" bash "$read_" "$d/hits.json" --opt-in --max-usd 0 2>&1 >/dev/null | cut -c1-61)" 'psm-read: refused, the spend cap is 0 so the read step is off'
want 'refused runs made no call' "$(calls)" '0'
want 'a higher price raises the estimate over a cap' "$(PSM_PRICE_IN=1000 PSM_READ_COMMAND="$d/model" bash "$read_" "$d/hits.json" --opt-in 2>&1 >/dev/null | cut -c1-30)" 'psm-read: refused, the estimat'

# A reply that is not a valid map is refused with the problems listed.
printf '{"machines": [{"id": "a", "name": "A", "kind": "weird", "states": ["x"], "evidence": []}]}\n' > "$d/badreply.txt"
want 'a reply that breaks the format is refused' "$(bash "$read_" "$d/hits.json" --replay "$d/badreply.txt" 2>&1 >/dev/null | head -3 | tr '\n' '|')" 'psm-read: the reply is not a valid map|psm-prove: the map breaks psm.map.v1:|  machine 0: kind must be explicit or hidden|'
printf 'sorry, I cannot do that\n' > "$d/prose.txt"
want 'prose is refused' "$(bash "$read_" "$d/hits.json" --replay "$d/prose.txt" 2>&1 >/dev/null || true)" 'psm-read: the reply is not a JSON object'
want 'not a hit list is refused' "$(bash "$read_" "$here/fixture-map.json" 2>&1 >/dev/null || true)" "psm-read: $here/fixture-map.json is not a psm.hits.v1 hit list"
exit "$fail"

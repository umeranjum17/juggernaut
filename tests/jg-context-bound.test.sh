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

# The supervisor cap setting (docs/configuration.md "Supervisor context cap"): shipped defaults, override, malformed line, apply.
cb() { python3 "$ROOT/bin/jg-context-bound.py" "$@"; }
mkdir "$d/config" "$d/home"
[ "$(cb cap lead --config "$d/config")" = 150000 ] || { echo "FAIL: lead default is not 150000"; exit 1; }
[ "$(cb cap main --config "$d/config")" = off ] || { echo "FAIL: main is not off by default"; exit 1; }
[ "$(cb env lead --pairs --config "$d/config")" = '"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"183000","CLAUDE_AUTOCOMPACT_PCT_OVERRIDE":"100"' ] || { echo "FAIL: lead env pairs"; exit 1; }
printf '# pilot\nmain 120000\nlead off\n' >"$d/config/supervisor-context-cap"
[ "$(cb cap main --config "$d/config")" = 120000 ] && [ "$(cb cap lead --config "$d/config")" = off ] || { echo "FAIL: config override"; exit 1; }
printf 'lead 10\n' >"$d/config/supervisor-context-cap"
bad=$(cb cap lead --config "$d/config" 2>&1) && { echo "FAIL: a malformed cap was accepted"; exit 1; }
[[ $bad == *"line 1 must be"* ]] || { echo "FAIL: malformed cap not named: $bad"; exit 1; }
printf 'main 150000\n' >"$d/config/supervisor-context-cap"
mkdir "$d/home/.""claude"; printf '{"hooks":{"x":1},"env":{"KEEP":"1"}}\n' >"$d/home/.""claude/settings.local.json"
cb apply main --home "$d/home" --config "$d/config" >/dev/null
python3 -c 'import json,sys; e=json.load(open(sys.argv[1]))["env"]; assert e=={"KEEP":"1","CLAUDE_CODE_AUTO_COMPACT_WINDOW":"183000","CLAUDE_AUTOCOMPACT_PCT_OVERRIDE":"100"}, e' "$d/home/.""claude/settings.local.json" || { echo "FAIL: apply did not merge the cap"; exit 1; }
printf 'main off\n' >"$d/config/supervisor-context-cap"
cb apply main --home "$d/home" --config "$d/config" >/dev/null
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["env"]=={"KEEP":"1"} and d["hooks"]=={"x":1}, d' "$d/home/.""claude/settings.local.json" || { echo "FAIL: off did not remove only the cap keys"; exit 1; }
echo "context-bound: cap defaults, override, malformed line refused, apply merges and off removes only the cap"

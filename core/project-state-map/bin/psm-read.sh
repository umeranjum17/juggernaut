#!/usr/bin/env bash
# Project state map, step 2 (read): a small model reads the search hits and writes a map as data.
# Usage: psm-read.sh <hits.json> [--project-dir dir] [--out file] [--opt-in] [--max-usd N] [--replay reply.txt]
# Input is a psm.hits.v1 hit list. Output is one psm.map.v1 map (stdout, or --out) that psm-prove.sh checks next.
# Each hit is sent as numbered code lines with two lines of context; files with secret-looking names are never sent.
# A live call sends those excerpts to the model provider, so it runs only with --opt-in, which the caller gives per
#   project and only after the owner approved it. --replay reads a saved reply instead: nothing is sent, so it needs no opt-in.
# The model command is PSM_READ_COMMAND (prompt on stdin, reply on stdout); default `claude -p --model claude-haiku-5-5`
#   with tools and sessions off. Spend cap: the estimated price of the call (bytes/4 tokens in, 3000 out, at
#   PSM_PRICE_IN and PSM_PRICE_OUT dollars per million tokens, defaults 1 and 5, unverified) must not pass --max-usd
#   (default 0.05); a call over the cap is not made, and a cap of 0 turns the read step off.
# Exit: 2 bad input, 3 refused before any call (no opt-in, step off, over the cap), 4 the reply is not a valid map.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
hits='' pdir='' out='' optin=0 cap=${PSM_MAX_USD:-0.05} replay=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project-dir) pdir=${2:?}; shift 2 ;;
    --out) out=${2:?}; shift 2 ;;
    --opt-in) optin=1; shift ;;
    --max-usd) cap=${2:?}; shift 2 ;;
    --replay) replay=${2:?}; shift 2 ;;
    -h|--help) sed -n 2,14p "$0" | cut -c3-; exit 0 ;;
    -*) echo "psm-read: unknown argument $1" >&2; exit 2 ;;
    *) [ -z "$hits" ] || { echo 'psm-read: one hit list only' >&2; exit 2; }; hits=$1; shift ;;
  esac
done
[ -n "$hits" ] || { sed -n 2,3p "$0" | cut -c3- >&2; exit 2; }
[ -f "$hits" ] || { echo "psm-read: not a file: $hits" >&2; exit 2; }
for c in jq awk; do command -v "$c" >/dev/null || { echo "psm-read: needs $c" >&2; exit 2; }; done
[ "$(jq -r '.schema // ""' "$hits" 2>/dev/null)" = psm.hits.v1 ] || { echo "psm-read: $hits is not a psm.hits.v1 hit list" >&2; exit 2; }
[ -n "$pdir" ] || pdir=$(jq -r .project "$hits")
[ -d "$pdir" ] || { echo "psm-read: not a directory: $pdir" >&2; exit 2; }
pdir=$(cd "$pdir" && pwd -P)
[ -z "$replay" ] || [ -f "$replay" ] || { echo "psm-read: not a file: $replay" >&2; exit 2; }
case "$cap" in ''|*[!0-9.]*) echo 'psm-read: --max-usd needs a number' >&2; exit 2 ;; esac

t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT

# Excerpts: per file, the hit lines with two lines of context on each side, numbered, long lines cut.
{
  cat <<'P'
You read code excerpts and report the states and moving parts they show. Reply with one JSON object and nothing else:
{"machines":[{"id":"short-id","name":"Name","kind":"explicit"|"hidden","states":["a","b"],"moves":[{"from":"a","to":"b","why":"optional"}],"evidence":[{"file":"path","line":12,"text":"text copied from that line"}]}],
 "machinery":[{"id":"short-id","name":"Name","kind":"server"|"timer"|"client"|"store"|"job"|"process"|"other","evidence":[{"file":"path","line":12,"text":"text copied from that line"}]}],
 "not_read":["what the excerpts do not let you judge"]}
explicit = a closed set of named values. hidden = states kept in flags or empty fields (for example a field that is empty until something ends).
Every state, move and part needs an evidence line. Copy the text from the excerpt exactly. Leave out anything you cannot cite. Do not guess.
Excerpts (file, then "line: text"):
P
  jq -r '.hits | group_by(.file)[] | "\(.[0].file)\t\([.[].line] | join(","))"' "$hits" |
  while IFS=$'\t' read -r f lines; do
    case "/$f" in /*/../*|/../*|//*|*/.env|*/.env.*|*.pem|*.key|*.p12|*/id_rsa*) continue ;; esac
    [ -f "$pdir/$f" ] && [ ! -L "$pdir/$f" ] || continue
    printf '== %s\n' "$f"
    awk -v L="$lines" 'BEGIN { n = split(L, a, ","); for (i = 1; i <= n; i++) for (d = -2; d <= 2; d++) want[a[i] + d] = 1 }
      want[NR] { if (last && NR > last + 1) print "--"; print NR ": " substr($0, 1, 240); last = NR }' "$pdir/$f"
  done
} > "$t/prompt"

bytes=$(wc -c < "$t/prompt")
est=$(awk -v b="$bytes" -v i="${PSM_PRICE_IN:-1}" -v o="${PSM_PRICE_OUT:-5}" 'BEGIN { printf "%.4f", b / 4 * i / 1e6 + 3000 * o / 1e6 }')

if [ -n "$replay" ]; then
  cp "$replay" "$t/reply"; mode=replay
else
  if [ "$cap" = 0 ] || [ "$cap" = 0.0 ]; then echo 'psm-read: refused, the spend cap is 0 so the read step is off' >&2; exit 3; fi
  [ "$optin" = 1 ] || { echo 'psm-read: refused, a live read sends code excerpts to the model provider and needs --opt-in for this project' >&2; exit 3; }
  awk -v e="$est" -v c="$cap" 'BEGIN { exit !(e + 0 > c + 0) }' && { echo "psm-read: refused, the estimated price \$$est for $bytes bytes of excerpts is over the cap \$$cap; no call was made" >&2; exit 3; }
  read -r -a cmd <<< "${PSM_READ_COMMAND:-claude -p --model claude-haiku-5-5 --tools '' --no-session-persistence --disable-slash-commands --setting-sources project}"
  timeout "${PSM_READ_SECONDS:-120}" "${cmd[@]}" < "$t/prompt" > "$t/reply" || { echo 'psm-read: the model command failed' >&2; exit 4; }
  mode=live
fi

# The reply: drop code-fence lines, then it must be one JSON object.
grep -v '^[[:space:]]*```' "$t/reply" > "$t/json" || true
jq -e 'type == "object"' "$t/json" >/dev/null 2>&1 || { echo 'psm-read: the reply is not a JSON object' >&2; exit 4; }
jq --slurpfile h "$hits" --arg mode "$mode" --argjson bytes "$bytes" --arg est "$est" '
  {schema: "psm.map.v1", project: $h[0].project, tree: $h[0].tree, hit_hash: $h[0].hit_hash,
   machines: (.machines // []), machinery: (.machinery // []), not_read: (.not_read // []),
   read: {mode: $mode, excerpt_bytes: $bytes, estimated_usd: ($est | tonumber)}}' "$t/json" > "$t/map"
if ! bad=$(bash "$here/psm-prove.sh" "$t/map" "$pdir" 2>&1 >/dev/null); then
  echo "psm-read: the reply is not a valid map" >&2; printf '%s\n' "$bad" >&2; exit 4
fi
if [ -n "$out" ]; then cp "$t/map" "$out"; else cat "$t/map"; fi

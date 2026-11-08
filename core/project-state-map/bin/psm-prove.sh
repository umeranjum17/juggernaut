#!/usr/bin/env bash
# Project state map, step 3 (prove): check a map against the code and drop what the code does not show.
# Read only: nothing under the project is ever changed.
# Usage: psm-prove.sh <map.json> <project-dir> [--out <file>]
# A map is psm.map.v1 data, however it was made (a model reply, a hand-written file):
#   {schema, project, tree, hit_hash,
#    machines:  [{id, name, kind: explicit|hidden, states:[str], moves:[{from, to, why?}], evidence:[{file, line, text}]}],
#    machinery: [{id, name, kind: server|timer|client|store|job|process|other, evidence:[{file, line, text}]}],
#    not_read:  [str]}
# A map that breaks this format is refused (exit 2) with every problem listed.
# Proof: every evidence line is looked up again. It stays only when the file is a plain project file
#   (not a secret-looking name, not outside the project), the line exists, and the line contains the cited
#   text (whitespace folded). A move naming a state the machine does not list is dropped. A machine or
#   part left with no evidence is dropped. Writes one psm.proved.v1 document (stdout, or --out): the map
#   with only what held, plus proof:{checked, kept, dropped_count, dropped:[{where, file, line, reason}]}.
set -euo pipefail

out='' map='' dir=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) out=${2:?}; shift 2 ;;
    -h|--help) sed -n 2,16p "$0" | cut -c3-; exit 0 ;;
    -*) echo "psm-prove: unknown argument $1" >&2; exit 2 ;;
    *) if [ -z "$map" ]; then map=$1; elif [ -z "$dir" ]; then dir=$1; else echo 'psm-prove: two paths only' >&2; exit 2; fi; shift ;;
  esac
done
[ -n "$map" ] && [ -n "$dir" ] || { sed -n 2,4p "$0" | cut -c3- >&2; exit 2; }
[ -f "$map" ] || { echo "psm-prove: not a file: $map" >&2; exit 2; }
[ -d "$dir" ] || { echo "psm-prove: not a directory: $dir" >&2; exit 2; }
command -v jq >/dev/null || { echo 'psm-prove: needs jq' >&2; exit 2; }
dir=$(cd "$dir" && pwd -P)

# Format check: every problem, one per line.
problems=$(jq -r '
  def isstr: type == "string" and length > 0;
  def ev($w): (.evidence // null) as $e
    | if ($e | type) != "array" or ($e | length) == 0 then "\($w): evidence must be a non-empty list"
      else ($e | to_entries[] | .key as $i | .value
        | if (type != "object") or (.file | isstr | not) or ((.line | type) != "number") or (.line < 1 or .line != (.line | floor)) or ((.text | type) != "string") or ((.text | gsub("\\s+"; " ") | gsub("^ | $"; "") | length) < 3)
          then "\($w): evidence \($i) needs file, a whole line number from 1, and text of 3 or more characters" else empty end) end;
  if type != "object" then "the map must be a JSON object"
  elif .schema != "psm.map.v1" then "schema must be psm.map.v1"
  else
    (if (.machines | type) != "array" then "machines must be a list" else
      (.machines | to_entries[] | .key as $i | .value | "machine \($i)" as $w
        | (if type != "object" then "\($w): must be an object" else
            (if (.id | isstr | not) then "\($w): id missing" else empty end),
            (if (.name | isstr | not) then "\($w): name missing" else empty end),
            (if ([.kind] | inside(["explicit", "hidden"]) | not) then "\($w): kind must be explicit or hidden" else empty end),
            (if (.states | type) != "array" or (.states | length) == 0 or ([.states[] | isstr] | all | not) then "\($w): states must be a non-empty list of names" else empty end),
            (if ((.moves // []) | type) != "array" or ([(.moves // [])[] | (type == "object") and (.from | isstr) and (.to | isstr)] | all | not) then "\($w): each move needs from and to" else empty end),
            ev($w) end)) end),
    (if (.machinery | type) != "array" then "machinery must be a list" else
      (.machinery | to_entries[] | .key as $i | .value | "part \($i)" as $w
        | (if type != "object" then "\($w): must be an object" else
            (if (.id | isstr | not) then "\($w): id missing" else empty end),
            (if (.name | isstr | not) then "\($w): name missing" else empty end),
            (if ([.kind] | inside(["server", "timer", "client", "store", "job", "process", "other"]) | not) then "\($w): kind is not a known part kind" else empty end),
            ev($w) end)) end),
    (if (.not_read | type) != "array" or ([.not_read[] | type == "string"] | all | not) then "not_read must be a list of text" else empty end)
  end' "$map" 2>&1) || { echo "psm-prove: $map is not JSON" >&2; exit 2; }
if [ -n "$problems" ]; then
  echo "psm-prove: the map breaks psm.map.v1:" >&2
  printf '%s\n' "$problems" | sed 's/^/  /' >&2
  exit 2
fi

fold() { printf '%s' "$1" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'; }

# One result row per evidence entry: where, file, line, ok, reason.
t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT
jq --raw-output0 '
  ((.machines | to_entries[] | .value as $m | "m:\($m.id)" as $w | $m.evidence[] | [$w, .file, (.line | tostring), .text]),
   (.machinery | to_entries[] | .value as $p | "p:\($p.id)" as $w | $p.evidence[] | [$w, .file, (.line | tostring), .text])) | .[]' "$map" |
while IFS= read -r -d '' where && IFS= read -r -d '' file && IFS= read -r -d '' line && IFS= read -r -d '' text; do
  reason=''
  case "/$file" in
    /*/../*|/../*|//*|*/..) reason='path outside the project' ;;
    */.env|*/.env.*|*.pem|*.key|*.p12|*/id_rsa*) reason='secret-looking file, never read' ;;
  esac
  if [ -z "$reason" ]; then
    if [ ! -f "$dir/$file" ] || [ -L "$dir/$file" ]; then reason='file not found'
    else
      real=$(cd "$(dirname -- "$dir/$file")" && pwd -P)/$(basename -- "$file")
      case "$real" in "$dir"/*) ;; *) reason='path outside the project' ;; esac
    fi
  fi
  if [ -z "$reason" ]; then
    cur=$(sed -n "${line}p" -- "$dir/$file" | head -c 4000)
    if [ -z "$cur" ] && [ "$(wc -l < "$dir/$file")" -lt "$line" ]; then reason='line not in the file'
    else
      case "$(fold "$cur")" in *"$(fold "$text")"*) ;; *) reason='text not on that line' ;; esac
    fi
  fi
  jq -n -c --arg w "$where" --arg f "$file" --argjson l "$line" --arg r "$reason" '{where: $w, file: $f, line: $l, ok: ($r == ""), reason: $r}'
done > "$t/rows"

jq -s '.' "$t/rows" > "$t/rows.json"
jq --slurpfile rows "$t/rows.json" '
  ($rows[0]) as $r
  | def held($w; $e): [$e[] | . as $x | select(any($r[]; .where == $w and .file == $x.file and .line == $x.line and .ok))];
  def has_move_gap($m): ($m.states) as $s | ($m.moves // []) | map(select(((.from as $f | $s | index($f)) != null) and ((.to as $t | $s | index($t)) != null) | not));
  ([.machines[] | . as $m | has_move_gap($m)[] | {where: "m:\($m.id)", file: "", line: 0, reason: "move names a state the machine does not list"}]) as $badmoves
  | (.machines | map(. as $m | .evidence = held("m:\($m.id)"; $m.evidence)
        | .moves = [(.moves // [])[] | select(. as $mv | ($m.states | index($mv.from)) != null and ($m.states | index($mv.to)) != null)])) as $ms
  | (.machinery | map(. as $p | .evidence = held("p:\($p.id)"; $p.evidence))) as $ps
  | ([$r[] | select(.ok | not) | {where, file, line, reason}]) as $badev
  | ([$ms[] | select(.evidence | length == 0) | {where: "m:\(.id)", file: "", line: 0, reason: "no evidence left, machine dropped"}]
     + [$ps[] | select(.evidence | length == 0) | {where: "p:\(.id)", file: "", line: 0, reason: "no evidence left, part dropped"}]) as $emptied
  | ($badev + $badmoves + $emptied) as $dropped
  | .schema = "psm.proved.v1"
  | .machines = [$ms[] | select(.evidence | length > 0)]
  | .machinery = [$ps[] | select(.evidence | length > 0)]
  | .proof = {checked: ($r | length), kept: ([$r[] | select(.ok)] | length),
              dropped_count: ($dropped | length), dropped: $dropped}' "$map" > "$t/final"
if [ -n "$out" ]; then cp "$t/final" "$out"; else cat "$t/final"; fi

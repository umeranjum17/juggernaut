#!/usr/bin/env bash
# jg-clause.sh - the one generic evaluator over owner-rule clauses, and the preference blocks it reads.
#
# A rule is data, not code. A clause is one JSON object: {id, point, when, then, reason}. A decision
# point asks `decide` with the facts it has; the evaluator adds the standard facts (utcHour, weekday,
# peak) once, matches every clause for that point, and answers with the strongest action. A rule that
# needs a fact no point gathers is the only case for code: add the fact to the point in
# defaults/preferences/schema.json, never a per-rule script.
#
# Usage:
#   jg-clause.sh decide <point> [fact=value ...]    JSON decision; exit 0 always (the caller acts on .action)
#   jg-clause.sh facts <point> [fact=value ...]     the fact bundle the evaluator matches against
#   jg-clause.sh list [<point>]                     one line per clause
#   jg-clause.sh add --point P --when '<k=v ...|json>' --then ACTION [--reason R] [--id ID] [--rule ID]
#   jg-clause.sh validate                           check every block and clause against the schema
#
# decision: {"action":"allow|warn|skip|deny","clause":"<id>","reason":"...","matched":["<id>",...]}
# Strength: deny > skip > warn > allow. Facts typed on the command line: true/false are booleans,
# digits are numbers, anything else is a string.
# `when` forms: a scalar equals; an array is any-of; a string with * is a glob; "a-b" against a number
# is an inclusive range; true/false against a boolean.
#
# Blocks: a home's config/preferences/<block>.json wins over the shipped defaults/preferences/<block>.json
# of the same name. A home block that does not parse or fails the schema is one stderr warning and the
# shipped block is used, so a bad edit never silences a rule and never stops work.
# JG_CLAUSE_NOW (epoch seconds) replaces the clock, for tests.
set -u

_jg_clause_self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JG_CLAUSE_ROOT=${JG_ROOT_OVERRIDE:-$(cd "$_jg_clause_self/.." && pwd)}
JG_CLAUSE_DEFAULTS="$JG_CLAUSE_ROOT/defaults/preferences"
_jg_clause_home=${JG_HOME:-$JG_CLAUSE_ROOT}
JG_CLAUSE_CONFIG=${JG_CONFIG_OVERRIDE:-$_jg_clause_home/config}
JG_CLAUSE_PREFS="$JG_CLAUSE_CONFIG/preferences"

# The block shape, checked once for the whole schema: required keys, value kinds, and the clause
# points, facts and actions the schema declares. Prints the first problem, or nothing.
_jg_clause_block_problem() { # <block file>
  jq -r --slurpfile s "$JG_CLAUSE_DEFAULTS/schema.json" '
    $s[0] as $sc
    | def kinds: $sc.block.valueTypeKinds;
      def known($p): $sc.points[$p];
      def clause_problem:
        . as $c
        | if (($sc.clause.required - ($c | keys)) | length) > 0 then "clause \($c.id // "?") lacks \(($sc.clause.required - ($c | keys)) | join(", "))"
          elif (known($c.point) == null) then "clause \($c.id): unknown point \($c.point)"
          elif (known($c.point).wired | not) then "clause \($c.id): point \($c.point) is declared but not wired yet"
          elif (known($c.point).actions | index($c.then)) == null then "clause \($c.id): action \($c.then) is not allowed at \($c.point) (\(known($c.point).actions | join("|")))"
          elif ($c.when | type) != "object" or ($c.when | length) == 0 then "clause \($c.id): when must be a non-empty object"
          else ([$c.when | keys[] | . as $k | select((known($c.point).facts | has($k)) or ($sc.standardFacts | has($k)) | not)] ) as $bad
            | if ($bad | length) > 0 then "clause \($c.id): fact \($bad[0]) is not gathered at \($c.point); add it to the point in schema.json" else empty end
          end;
      if type != "object" then "a block must be a JSON object"
      elif (($sc.block.required - keys) | length) > 0 then "missing \(($sc.block.required - keys) | join(", "))"
      elif .schema != "jg-preference/1" then "schema must be jg-preference/1"
      elif ((.block | type) != "string") then "block must be a name"
      elif ([(.valueTypes // {}) | to_entries[] | select(.value as $k | kinds | index($k) | not)] | length) > 0 then "valueTypes holds an unknown kind"
      else ([(.clauses // [])[] | clause_problem] | first // empty) end
  ' "$1" 2>&1
}

# jg_clause_block_file <name>: the file that decides this block now (home copy when valid, else shipped).
jg_clause_block_file() {
  local name=$1 home="$JG_CLAUSE_PREFS/$1.json" shipped="$JG_CLAUSE_DEFAULTS/$1.json" why
  if [ -f "$home" ]; then
    why=$(_jg_clause_block_problem "$home")
    if [ -z "$why" ] && [ "$(jq -r '.block' "$home" 2>/dev/null)" = "$name" ]; then
      printf '%s\n' "$home"
      return 0
    fi
    printf 'jg-clause: warning: %s is not a valid %s block (%s); using the shipped block\n' "$home" "$name" "${why:-block name differs from file name}" >&2
  fi
  [ -f "$shipped" ] || return 1
  printf '%s\n' "$shipped"
}

# jg_clause_block_names: every block name, shipped or home, one per line.
jg_clause_block_names() {
  local f
  for f in "$JG_CLAUSE_DEFAULTS"/*.json "$JG_CLAUSE_PREFS"/*.json; do
    [ -f "$f" ] || continue
    f=${f##*/}; f=${f%.json}
    [ "$f" = schema ] || printf '%s\n' "$f"
  done | sort -u
}

# jg_clause_blocks_json: every effective block as one JSON array.
jg_clause_blocks_json() {
  local name file files=()
  while IFS= read -r name; do
    file=$(jg_clause_block_file "$name") || continue
    files+=("$file")
  done < <(jg_clause_block_names)
  [ ${#files[@]} -gt 0 ] || { printf '[]\n'; return 0; }
  jq -s '.' "${files[@]}"
}

_jg_clause_typed_facts() { # fact=value ... -> JSON object
  local pair k v out='{}'
  for pair in "$@"; do
    k=${pair%%=*}; v=${pair#*=}
    case $v in true | false) out=$(jq -c --arg k "$k" --argjson v "$v" '.[$k]=$v' <<<"$out") ;;
      '' | *[!0-9]*) out=$(jq -c --arg k "$k" --arg v "$v" '.[$k]=$v' <<<"$out") ;;
      *) out=$(jq -c --arg k "$k" --argjson v "$v" '.[$k]=$v' <<<"$out") ;;
    esac
  done
  printf '%s\n' "$out"
}

# jg_clause_facts <point> [fact=value ...]: the point's facts plus the standard ones, gathered once.
jg_clause_facts() {
  local point=$1 now given
  shift
  now=${JG_CLAUSE_NOW:-$(date +%s)}
  given=$(_jg_clause_typed_facts "$@")
  jq -n --argjson blocks "$(jg_clause_blocks_json)" --argjson given "$given" --argjson now "$now" '
    def inr($v; $s): ($s | split("-") | map(tonumber)) as $r | $v >= $r[0] and $v <= $r[1];
    ($now | gmtime) as $t
    | ($t[3]) as $h
    | (if $t[6] == 0 then 7 else $t[6] end) as $wd
    | (([$blocks[] | select(.block == "peak-hours") | .values][0]) // {}) as $p
    | $given + {utcHour: $h, weekday: $wd,
        peak: (($p.utcHours // "") != "" and ($p.weekdays // "") != "" and inr($h; $p.utcHours) and inr($wd; $p.weekdays))}'
}

# jg_clause_decide <point> [fact=value ...]: the decision JSON.
jg_clause_decide() {
  local point=$1 facts blocks
  shift
  facts=$(jg_clause_facts "$point" "$@") || return 1
  blocks=$(jg_clause_blocks_json)
  jq -nc --argjson facts "$facts" --argjson blocks "$blocks" --arg point "$point" '
    def inr($v; $s): ($s | split("-") | map(tonumber)) as $r | $v >= $r[0] and $v <= $r[1];
    def glob_re: gsub("(?<c>[.+?()\\[\\]{}|^$\\\\])"; "\\" + .c) | gsub("\\*"; ".*") | "^" + . + "$";
    def one($f; $w):
      if ($w | type) == "array" then any($w[]; one($f; .))
      elif ($w | type) == "string" and ($w | contains("*")) then ($f | type) == "string" and ($f | test($w | glob_re))
      elif ($w | type) == "string" and ($w | test("^[0-9]+-[0-9]+$")) and ($f | type) == "number" then inr($f; $w)
      else $f == $w end;
    def rank: {"allow": 0, "warn": 1, "skip": 2, "deny": 3}[.];
    [ $blocks[] | (.clauses // [])[] | select(.point == $point)
      | . as $c | select(all($c.when | to_entries[]; one($facts[.key]; .value))) ] as $hit
    | ($hit | sort_by(-(.then | rank)) | first) as $top
    | if $top == null then {action: "allow", clause: null, reason: null, matched: []}
      else {action: $top.then, clause: $top.id, reason: ($top.reason // $top.id), matched: [$hit[].id]} end'
}

jg_clause_validate() {
  local name file rc=0 why
  [ -f "$JG_CLAUSE_DEFAULTS/schema.json" ] || { echo "jg-clause: no schema at $JG_CLAUSE_DEFAULTS/schema.json" >&2; return 2; }
  for file in "$JG_CLAUSE_DEFAULTS"/*.json "$JG_CLAUSE_PREFS"/*.json; do
    [ -f "$file" ] || continue
    [ "${file##*/}" = schema.json ] && continue
    if ! jq -e . "$file" >/dev/null 2>&1; then printf 'not ok - %s: not JSON\n' "$file"; rc=1; continue; fi
    why=$(_jg_clause_block_problem "$file")
    [ -z "$why" ] && [ "$(jq -r .block "$file")" = "$(basename "$file" .json)" ] || { printf 'not ok - %s: %s\n' "$file" "${why:-block name differs from file name}"; rc=1; continue; }
    printf 'ok - %s\n' "$file"
  done
  return "$rc"
}

# Parse --when: a JSON object, or space-separated k=v pairs (comma = any-of, true/false and digits typed).
_jg_clause_when_json() {
  local w=$1 pair k v out='{}'
  if jq -e 'type == "object"' <<<"$w" >/dev/null 2>&1; then jq -c . <<<"$w"; return; fi
  for pair in $w; do
    case $pair in *=*) ;; *) echo "jg-clause: --when needs k=v pairs or a JSON object (got '$pair')" >&2; return 1 ;; esac
    k=${pair%%=*}; v=${pair#*=}
    out=$(jq -c --arg k "$k" --arg v "$v" '
      def typed: if . == "true" then true elif . == "false" then false elif test("^[0-9]+$") then tonumber else . end;
      .[$k] = (if ($v | contains(",")) then ($v | split(",") | map(typed)) else ($v | typed) end)' <<<"$out")
  done
  printf '%s\n' "$out"
}

# jg_clause_add <point> <when> <then> <reason> <id> <rule>: append to the home's rules block.
jg_clause_add() {
  local point=$1 when=$2 then=$3 reason=$4 id=$5 rule=${6:-} wj dest tmp
  wj=$(_jg_clause_when_json "$when") || return 2
  dest="$JG_CLAUSE_PREFS/rules.json"
  mkdir -p "$JG_CLAUSE_PREFS" || return 2
  [ -f "$dest" ] || cp "$JG_CLAUSE_DEFAULTS/rules.json" "$dest" || return 2
  if jq -e --arg id "$id" '(.clauses // []) | any(.id == $id)' "$dest" >/dev/null; then
    echo "jg-clause: a clause with id $id already exists" >&2; return 2
  fi
  tmp=$(mktemp "$dest.XXXXXX") || return 2
  jq --arg id "$id" --arg point "$point" --argjson when "$wj" --arg act "$then" --arg reason "$reason" --arg rule "$rule" '
    .clauses = ((.clauses // []) + [{id: $id, point: $point, when: $when, then: $act, reason: $reason}
      + (if $rule == "" then {} else {rule: $rule} end)])' "$dest" >"$tmp" || { rm -f -- "$tmp"; return 2; }
  local why
  why=$(_jg_clause_block_problem "$tmp")
  if [ -n "$why" ]; then rm -f -- "$tmp"; echo "jg-clause: refused: $why" >&2; return 2; fi
  mv -f -- "$tmp" "$dest"
}

jg_clause_main() {
  local verb=${1:-}
  shift || true
  case $verb in
    decide) [ $# -ge 1 ] || { echo "usage: jg-clause.sh decide <point> [fact=value ...]" >&2; return 2; }; jg_clause_decide "$@" ;;
    facts) [ $# -ge 1 ] || { echo "usage: jg-clause.sh facts <point> [fact=value ...]" >&2; return 2; }; jg_clause_facts "$@" ;;
    list) jg_clause_blocks_json | jq -r --arg p "${1:-}" '.[] | (.clauses // [])[] | select($p == "" or .point == $p) | "\(.id)\t\(.point)\t\(.then)\t\(.when | tojson)\t\(.reason // "")"' ;;
    validate) jg_clause_validate ;;
    add)
      local point='' when='' then='' reason='' id='' rule=''
      while [ $# -gt 0 ]; do
        case $1 in
          --point) point=${2:-}; shift ;; --when) when=${2:-}; shift ;; --then) then=${2:-}; shift ;;
          --reason) reason=${2:-}; shift ;; --id) id=${2:-}; shift ;; --rule) rule=${2:-}; shift ;;
          *) echo "jg-clause: unknown argument $1" >&2; return 2 ;;
        esac
        shift
      done
      [ -n "$point" ] && [ -n "$when" ] && [ -n "$then" ] && [ -n "$id" ] || { echo "usage: jg-clause.sh add --id ID --point P --when '<k=v ...>' --then ACTION [--reason R]" >&2; return 2; }
      jg_clause_add "$point" "$when" "$then" "${reason:-$id}" "$id" "$rule" ;;
    *) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  jg_clause_main "$@"
  exit $?
fi

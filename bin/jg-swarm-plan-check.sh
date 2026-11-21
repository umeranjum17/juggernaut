#!/usr/bin/env bash
# jg-swarm-plan-check.sh - check a swarm plan file before anything is written.
#
# Usage: jg-swarm-plan-check.sh <plan.json> [--repo <dir> --ref <ref>]
#
# Reads the plan file and the order files beside it; needs no home and no store, and writes nothing (with --repo and
# --ref it also reads that git repository, read-only).
# Exit 0 prints `wave 1: <n> slices can start at once` (the slices with no `depends_on`), then
# `plan <plan>: <n> slices ok`. Exit 2 prints one `refused: <plan id or slice id>: <reason>` line for
# every problem found, all of them, and nothing else. (A usage error also exits 2.)
#
# Checks:
#   - the file is JSON; `plan`, `title`, `report`, `intent` and `prior_art` are set; there is at least one slice;
#   - the plan title and each slice title pass jg_backlog_title_refusal (bin/jg-backlog-lib.sh);
#   - each slice id is lowercase letters and digits, and used once;
#   - each slice has `owner_home` and `project`, and its `order` file exists beside the plan file;
#   - each `depends_on` names another slice of this plan with the same `owner_home`, and the dependencies hold no loop
#     (tsort does not see a slice that names itself, so that is its own check);
#   - an `owner_word` has a question (12 words at most), options `a` and `b` (80 characters each), `outcomes.a` and
#     `outcomes.b` (120 each), `why` (one line, 200), `recommend` a or b with `recommend_reason` (160), `default` a or b
#     and `must` design-pick, and jg_ask_card_refusal (bin/jg-ask-gate-lib.sh) passes for the question, options, why and
#     outcomes: the fields the board's `sign-off-axi raise` requires, so the swarm's card step posts on the first try;
#   - `files` is a list of strings; each entry, after one trailing ` (new)` is removed, is a relative path (not empty,
#     no leading `/`, `./` or `../`, no `..` part, only the characters A-Za-z0-9._/@+-), so prose is refused;
#   - two slices of one `project` that name the same path (` (new)` removed) have a `depends_on` path between them,
#     direct or through other slices; else one line names the pair and the first shared path;
#   - with `--repo <dir> --ref <ref>` (both or neither): an entry not marked ` (new)` exists in <ref> of <dir>;
#   - a `gate` is null, {waits_for: "<home>:<row id>"} or {tool, min};
#   - an optional `muster` block (formats.md section 5 of the muster skill), shape and order only, no store and no
#     manifest: `ticket`, `depth` full or complete, `manifest_sha` (12 hex), `journeys` (kind new or preserve),
#     `batches`, `charter` and `milestones` are well formed; no batch waits on itself; a charter row names a batch
#     and tickets of the block; a slice's `journeys` and `charter` name only ids of the block; every `new` journey,
#     every charter ticket and every milestone journey is claimed by a slice; a slice that claims ticket T depends,
#     directly or through other slices, on every slice that claims a ticket T depends on or a ticket of a batch T's
#     batch starts after, so no slice claims a ticket together with one it must follow. Tickets of one batch with no
#     dependency between them may start together. A plan with no block is checked as before.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/jg-backlog-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-backlog-lib.sh"
# shellcheck source=bin/jg-ask-gate-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-ask-gate-lib.sh"

case ${1-} in
  -h | --help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
esac
usage() { echo "usage: jg-swarm-plan-check.sh <plan.json> [--repo <dir> --ref <ref>]" >&2; exit 2; }
PLAN_FILE=${1-}
[ -n "$PLAN_FILE" ] || usage
shift
REPO='' REF=''
while [ $# -gt 0 ]; do
  case $1 in
    --repo) [ $# -ge 2 ] || usage; REPO=$2; shift 2 ;;
    --ref) [ $# -ge 2 ] || usage; REF=$2; shift 2 ;;
    *) usage ;;
  esac
done
{ [ -n "$REPO" ] && [ -n "$REF" ]; } || { [ -z "$REPO" ] && [ -z "$REF" ]; } || usage
if [ -n "$REPO" ]; then
  case $REF in -*) echo "jg-swarm-plan-check: the ref must not start with a dash: $REF" >&2; exit 2 ;; esac
  git -C "$REPO" rev-parse --verify -q "$REF^{commit}" >/dev/null ||
    { echo "jg-swarm-plan-check: no commit $REF in the repository $REPO" >&2; exit 2; }
fi
[ -f "$PLAN_FILE" ] || { echo "jg-swarm-plan-check: no such plan file: $PLAN_FILE" >&2; exit 2; }
PLAN_DIR=$(cd "$(dirname "$PLAN_FILE")" && pwd)

REFUSALS=()
refuse() { REFUSALS+=("refused: $1: $2"); }  # <plan or slice id> <reason>
finish() {
  [ ${#REFUSALS[@]} -eq 0 ] || { printf '%s\n' "${REFUSALS[@]}"; exit 2; }
  printf 'wave 1: %s slices can start at once\n' \
    "$(jq '[.slices[] | select((.depends_on // []) | length == 0)] | length' "$PLAN_FILE")"
  printf 'plan %s: %s slices ok\n' "$PLAN" "$(jq '.slices | length' "$PLAN_FILE")"
}
field() { jq -r --arg k "$2" '.[$k] | if type == "string" then . else empty end' <<<"$1"; }  # <json> <key>

if ! jq -e 'type == "object"' "$PLAN_FILE" >/dev/null 2>&1; then
  REFUSALS=("refused: plan: not JSON, or not a JSON object")
  finish
fi
PLAN=$(field "$(cat "$PLAN_FILE")" plan)
P=${PLAN:-plan}
PLAN_JSON=$(cat "$PLAN_FILE")
for k in plan title report intent prior_art; do
  [ -n "$(field "$PLAN_JSON" "$k")" ] || refuse "$P" "no $k"
done
if t=$(field "$PLAN_JSON" title) && [ -n "$t" ] && ! why=$(jg_backlog_title_refusal "$t"); then
  refuse "$P" "the plan title: $why"
fi
if ! jq -e '.slices | type == "array" and length > 0' <<<"$PLAN_JSON" >/dev/null 2>&1; then
  refuse "$P" "no slices"
  finish
fi

word_field() {  # <slice id> <field> <value> <max characters>: one owner_word text the board requires, on one line
  local id=$1 f=$2 v=$3 max=$4
  [ -n "$v" ] || { refuse "$id" "owner_word has no $f"; return 0; }
  case $v in *$'\n'*) refuse "$id" "owner_word $f is not one line"; return 0 ;; esac
  [ "$(jq -n --arg v "$v" '$v | length')" -le "$max" ] || refuse "$id" "owner_word $f is over $max characters"
}

check_word() {  # <slice id> <slice json>: the owner_word rules
  local id=$1 s=$2 w q a b why oa ob wy rr n
  w=$(jq -c '.owner_word' <<<"$s")
  [ "$w" != null ] || return 0
  q=$(jq -r '.question | strings' <<<"$w" 2>/dev/null || true)
  a=$(jq -r '.options.a | strings' <<<"$w" 2>/dev/null || true)
  b=$(jq -r '.options.b | strings' <<<"$w" 2>/dev/null || true)
  [ -n "$q" ] || { refuse "$id" "owner_word has no question"; return 0; }
  [ -n "$a" ] && [ -n "$b" ] || { refuse "$id" "owner_word needs options a and b"; return 0; }
  oa=$(jq -r '.outcomes.a | strings' <<<"$w" 2>/dev/null || true)
  ob=$(jq -r '.outcomes.b | strings' <<<"$w" 2>/dev/null || true)
  wy=$(jq -r '.why | strings' <<<"$w" 2>/dev/null || true)
  rr=$(jq -r '.recommend_reason | strings' <<<"$w" 2>/dev/null || true)
  n=$(wc -w <<<"$q")
  [ "$n" -le 12 ] || refuse "$id" "owner_word question has $n words, 12 at most"
  word_field "$id" why "$wy" 200
  word_field "$id" "options.a" "$a" 80
  word_field "$id" "options.b" "$b" 80
  word_field "$id" "outcomes.a" "$oa" 120
  word_field "$id" "outcomes.b" "$ob" 120
  word_field "$id" recommend_reason "$rr" 160
  jq -e '.default == "a" or .default == "b"' <<<"$w" >/dev/null || refuse "$id" "owner_word default is not a or b"
  jq -e '.recommend == "a" or .recommend == "b"' <<<"$w" >/dev/null || refuse "$id" "owner_word recommend is not a or b"
  case $(jq -r '.must // empty' <<<"$w") in
    design-pick) ;;
    *) refuse "$id" "owner_word must is $(jq -r '.must // "unset"' <<<"$w"), not design-pick: an owner word is a product pick only" ;;
  esac
  if ! why=$(jg_ask_card_refusal "$PLAN-word-$id" 2 "$q" "$wy" "$a" "$b" "$oa" "$ob" "$rr"); then
    refuse "$id" "owner_word: ${why#refused: }"
  fi
}

check_gate() {  # <slice id> <slice json>
  local id=$1 g
  g=$(jq -c '.gate' <<<"$2")
  [ "$g" != null ] && [ "$g" != '{"waits_for":""}' ] || return 0
  jq -e '(type == "object") and
         ((keys == ["waits_for"] and (.waits_for | type == "string" and test("^[^:[:space:]]+:[^:[:space:]]+$"))) or
          (keys == ["min", "tool"] and (.tool | type == "string" and length > 0) and (.min | type == "string" and length > 0)))' \
    <<<"$g" >/dev/null || refuse "$id" "gate is neither {waits_for: \"<home>:<row id>\"} nor {tool, min}"
}

check_files() {  # <slice id> <slice json>: `files` are paths; with --repo/--ref the existing ones are in the ref
  local id=$1 e p
  if ! jq -e '.files | type == "array" and length > 0 and all(.[]; type == "string")' <<<"$2" >/dev/null; then
    refuse "$id" "files is missing, empty, or not a list of strings"
    return 0
  fi
  while IFS= read -r e; do
    p=${e%" (new)"}
    if [ -z "$p" ] || [[ $p == /* || $p == ./* || $p == ../* || $p =~ (^|/)\.\.(/|$) || ! $p =~ ^[A-Za-z0-9._/@+-]+$ ]]; then
      refuse "$id" "files entry is not a path: $e"
    elif [ -n "$REPO" ] && [ "$p" = "$e" ] && ! git -C "$REPO" cat-file -e "$REF:$p" 2>/dev/null; then
      refuse "$id" "files entry is not in $REF: $e"
    fi
  done < <(jq -r '.files[]' <<<"$2")
}

# Unordered slices of one project that name one path: one line per pair, the first shared path only. A slice reaches
# another through depends_on, directly or through others; the closure is a fixpoint, so a loop (refused below) ends it.
shared_file_pairs() {  # <plan json>: prints `<a> <b> <path>` per pair, in plan order
  jq -r '
    def paths: [.files // [] | .[] | strings | sub(" \\(new\\)$"; "") | select(test("^[A-Za-z0-9._/@+-]+$"))];
    [.slices[] | select((.id | type) == "string")] as $ss
    | ($ss | map({key: .id, value: ((.depends_on // []) | if type == "array" then map(tostring) else [] end)}) | from_entries) as $dep
    | def up: (. + (map($dep[.] // []) | add // [])) | unique;
      def reach($i): [$i] | until(up == .; up);
      range(0; $ss | length) as $x | range($x + 1; $ss | length) as $y
    | $ss[$x] as $a | $ss[$y] as $b
    | select($a.id != $b.id and $a.project == $b.project)
    | select((reach($a.id) | index($b.id)) == null and (reach($b.id) | index($a.id)) == null)
    | ([($a | paths | .[]) as $p | select(($b | paths | index($p)) != null) | $p] | first) as $path
    | select($path != null)
    | "\($a.id) \($b.id) \($path)"' <<<"$1"
}

# The muster block's rules, all in one jq program that prints `<who>|<reason>` per problem (who is `-` for the plan).
# Structure first; then the block's own graph (batches, charter rows); then the slices' claims and their order, which
# mean nothing over a broken graph. A slice reaches another through depends_on, directly or through others.
# shellcheck disable=SC2016
MUSTER_JQ='
def ob: type == "object";
def strs: type == "array" and all(.[]; type == "string" and length > 0);
def ids: [.[] | select(type == "string")];
def dups: group_by(.) | map(select(length > 1) | .[0]);
def row($who; $why): "\($who)|\($why)";
def has($arr; $x): any($arr[]; . == $x);
(.muster) as $m
| [.slices[] | select(ob and ((.id | type) == "string"))] as $ss
| if $m == null then
    $ss[] | select(((.journeys // []) | length) > 0 or ((.charter // []) | length) > 0)
    | row(.id; "names journeys or a charter ticket and the plan has no muster block")
  elif ($m | ob | not) then row("-"; "muster is not an object")
  else
    ([ (if ($m.ticket | type) == "string" and ($m.ticket | length) > 0 then empty else "muster has no ticket" end),
       (if ($m.depth | type) == "string" and has(["full", "complete"]; $m.depth) then empty
        else "muster depth is \($m.depth // "unset"), not full or complete" end),
       (if ($m.manifest_sha | type) == "string" and ($m.manifest_sha | test("^[0-9a-f]{12}$")) then empty
        else "muster manifest_sha is not 12 hex digits" end),
       (if ($m.journeys | type) == "array" and all($m.journeys[]; ob and (.id | type) == "string" and (.id | length) > 0)
        then ($m.journeys[] | select((.kind | type) != "string" or (has(["new", "preserve"]; .kind) | not))
              | "muster journey \(.id) has kind \(.kind // "unset"), not new or preserve")
        else "muster journeys is not a list of {id, kind}" end),
       (if ($m.batches | type) == "array" and all($m.batches[]; ob and (.id | type) == "string" and (.after | strs))
        then empty else "muster batches is not a list of {id, after}" end),
       (if ($m.charter | type) == "array" and all($m.charter[]; ob and (.ticket | type) == "string" and
            (.batch | type) == "string" and (.depends | strs)) then empty
        else "muster charter is not a list of {ticket, batch, depends}" end),
       (if ($m.milestones | type) == "array" and all($m.milestones[]; ob and (.id | type) == "string" and (.journeys | strs))
        then empty else "muster milestones is not a list of {id, journeys}" end)
     ]) as $bad
  | if ($bad | length) > 0 then $bad[] | row("-"; .)
    else
      ($m.journeys | map(.id)) as $J | ($m.batches | map(.id)) as $B | ($m.charter | map(.ticket)) as $T
      | ($m.batches | map({key: .id, value: .after}) | from_entries) as $after
      | ($m.charter | map({key: .ticket, value: .}) | from_entries) as $row
      | [ ($J | dups[] | "muster journey \(.) is listed twice"),
          ($B | dups[] | "muster batch \(.) is listed twice"),
          ($T | dups[] | "muster charter ticket \(.) is listed twice"),
          ($m.batches[] | .id as $b | .after[]
            | if . == $b then "batch \($b) waits on itself"
              elif (has($B; .) | not) then "batch \($b) starts after \(.), which is not in the block" else empty end),
          ($m.charter[] | .ticket as $t
            | (if (has($B; .batch) | not) then "charter ticket \($t) names batch \(.batch), which is not in the block" else empty end),
              (.depends[] | if . == $t then "charter ticket \($t) depends on itself"
                            elif (has($T; .) | not) then "charter ticket \($t) depends on \(.), which is not in the block"
                            else empty end))
        ] as $graph
      | if ($graph | length) > 0 then $graph[] | row("-"; .)
        else
          ($ss | map({key: .id, value: ((.depends_on // []) | if type == "array" then map(tostring) else [] end)}) | from_entries) as $dep
          | def up: (. + (map($dep[.] // []) | add // [])) | unique;
            def reach($i): [$i] | until(up == .; up);
          ([ $ss[] | select(((.journeys // []) | strs | not) or ((.charter // []) | strs | not))
             | row(.id; "journeys and charter must each be a list of ids") ]) as $typed
          | ($ss | map(select(((.journeys // []) | strs) and ((.charter // []) | strs)))) as $ok
          | ($ok | map({id, journeys: (.journeys // []), charter: (.charter // [])})) as $cl
          | def claimers($t): [$cl[] | select(has(.charter; $t)) | .id];
          def need($t): ($row[$t].depends + [$m.charter[] | select(.batch as $b | has($after[$row[$t].batch] // []; $b)) | .ticket]) | unique;
          $typed[],
          ($cl[] | .id as $s
            | (.journeys[] | . as $j | select(has($J; $j) | not) | row($s; "names journey \(.), which is not in the muster block")),
              (.charter[] | . as $t | select(has($T; $t) | not) | row($s; "names charter ticket \(.), which is not in the muster block"))),
          ($m.journeys[] | select(.kind == "new") | .id as $j | select([$cl[] | select(has(.journeys; $j))] | length == 0)
            | row("-"; "muster journey \($j) (new) is claimed by no slice")),
          ($T[] | . as $t | select(claimers($t) | length == 0) | row("-"; "muster charter ticket \($t) is claimed by no slice")),
          ($m.milestones[] | .id as $mi | .journeys[] | . as $j | select([$cl[] | select(has(.journeys; $j))] | length == 0)
            | row("-"; "milestone \($mi) journey \($j) is claimed by no slice")),
          ($cl[] | .id as $s | .charter[] | . as $t | select(has($T; $t)) | need($t)[] | . as $u | claimers($u)[]
            | . as $x | select($x == $s)
            | row($s; "claims \($t) together with \($u), which it must follow: use one slice for each"))
          ,
          ($cl[] | .id as $s | .charter[] | . as $t | select(has($T; $t)) | need($t)[] | . as $u | claimers($u)[]
            | . as $x | select($x != $s and (has(reach($s); $x) | not))
            | row($s; "claims \($t) and must depend on \($x), which claims \($u), but does not"))
        end
    end
  end'
check_muster() {  # the optional muster block: shape and order only
  local who why
  while IFS='|' read -r who why; do
    [ -n "$why" ] || continue
    if [ "$who" = - ]; then refuse "$P" "$why"; else refuse "$who" "$why"; fi
  done < <(jq -r "$MUSTER_JQ" <<<"$PLAN_JSON" | sort -u)
}

declare -A HOME_OF=()
SLICES=$(jq -c '.slices[]' <<<"$PLAN_JSON")
while IFS= read -r s; do  # first pass: ids and owner homes
  id=$(field "$s" id)
  [ -n "$id" ] || continue
  [[ $id =~ ^[a-z0-9]+$ ]] || continue
  HOME_OF[$id]=${HOME_OF[$id]-$(field "$s" owner_home)}
done <<<"$SLICES"

declare -A SEEN=()
while IFS= read -r s; do
  id=$(field "$s" id)
  if [ -z "$id" ]; then refuse "$P" "a slice has no id"; continue; fi
  if [[ ! $id =~ ^[a-z0-9]+$ ]]; then
    refuse "$id" "the id is not lowercase letters and digits"
  elif [ -n "${SEEN[$id]-}" ]; then
    refuse "$id" "the id is used twice"
  fi
  SEEN[$id]=1
  t=$(field "$s" title)
  if [ -z "$t" ]; then refuse "$id" "no title"
  elif ! why=$(jg_backlog_title_refusal "$t"); then refuse "$id" "title: $why"; fi
  home=$(field "$s" owner_home)
  [ -n "$home" ] || refuse "$id" "no owner_home"
  [ -n "$(field "$s" project)" ] || refuse "$id" "no project"
  o=$(field "$s" order)
  if [ -z "$o" ]; then refuse "$id" "no order file named"
  elif [ ! -f "$PLAN_DIR/$o" ]; then refuse "$id" "the order file $o is not beside the plan file"; fi
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ "$d" = "$id" ]; then refuse "$id" "depends_on names itself"
    elif [ -z "${SEEN[$d]+x}" ] && [ -z "${HOME_OF[$d]+x}" ]; then refuse "$id" "depends_on names no slice: $d"
    elif [ "${HOME_OF[$d]-}" != "$home" ]; then refuse "$id" "depends_on $d, which has another owner_home"; fi
  done < <(jq -r '.depends_on // [] | .[] | tostring' <<<"$s")
  check_files "$id" "$s"
  check_word "$id" "$s"
  check_gate "$id" "$s"
done <<<"$SLICES"

if ! jq -r '.slices[] | .id as $s | (.depends_on // [])[] | select(. != $s) | "\(.) \($s)"' <<<"$PLAN_JSON" | tsort >/dev/null 2>&1; then
  refuse "$P" "dependency loop among the slices"
fi
while read -r a b path; do
  [ -z "$a" ] || refuse "$a" "shares a file with $b and neither depends on the other: $path"
done < <(shared_file_pairs "$PLAN_JSON")
check_muster
finish

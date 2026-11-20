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
#   - an `owner_word` has a question, options `a` and `b`, `recommend` a or b and `must` design-pick, and
#     jg_ask_card_refusal (bin/jg-ask-gate-lib.sh) passes for it;
#   - `files` is a list of strings; each entry, after one trailing ` (new)` is removed, is a relative path (not empty,
#     no leading `/`, `./` or `../`, no `..` part, only the characters A-Za-z0-9._/@+-), so prose is refused;
#   - two slices of one `project` that name the same path (` (new)` removed) have a `depends_on` path between them,
#     direct or through other slices; else one line names the pair and the first shared path;
#   - with `--repo <dir> --ref <ref>` (both or neither): an entry not marked ` (new)` exists in <ref> of <dir>;
#   - a `gate` is null, {waits_for: "<home>:<row id>"} or {tool, min}.
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

check_word() {  # <slice id> <slice json>: the owner_word rules
  local id=$1 s=$2 w q a b why
  w=$(jq -c '.owner_word' <<<"$s")
  [ "$w" != null ] || return 0
  q=$(jq -r '.question | strings' <<<"$w" 2>/dev/null || true)
  a=$(jq -r '.options.a | strings' <<<"$w" 2>/dev/null || true)
  b=$(jq -r '.options.b | strings' <<<"$w" 2>/dev/null || true)
  [ -n "$q" ] || { refuse "$id" "owner_word has no question"; return 0; }
  [ -n "$a" ] && [ -n "$b" ] || { refuse "$id" "owner_word needs options a and b"; return 0; }
  jq -e '.recommend == "a" or .recommend == "b"' <<<"$w" >/dev/null || refuse "$id" "owner_word recommend is not a or b"
  case $(jq -r '.must // empty' <<<"$w") in
    design-pick) ;;
    *) refuse "$id" "owner_word must is $(jq -r '.must // "unset"' <<<"$w"), not design-pick: an owner word is a product pick only" ;;
  esac
  if ! why=$(jg_ask_card_refusal "$PLAN-word-$id" 2 "$q" "$a" "$b"); then
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
finish

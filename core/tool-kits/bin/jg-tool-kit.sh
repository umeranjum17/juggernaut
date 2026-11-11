#!/usr/bin/env bash
# jg-tool-kit.sh - the one owner of the tool-kit contract (core/tool-kits/README.md).
#
# Usage: jg-tool-kit.sh list                                    each kit and what it is for
#        jg-tool-kit.sh resolve "<ask>"                         `specialist <kit>`, or `none`: no model, words only
#        jg-tool-kit.sh section <kit> [<task>]                  the kit's instruction text, for the scaffold
#        jg-tool-kit.sh board                                   the board file this home posts to
#        jg-tool-kit.sh receipt <task> --card <key> <path>...   save the tool's run record, the hash of each output and the card key
#        jg-tool-kit.sh check <task>                            the done check: the receipt, the card on the board and the kit's own check
#
# A kit is one folder of data under kits/<name>/ (kit.json, brief.md, check.sh, asks.txt, journey.sh): the tool, the words that
# pick it, the stage text, and the check on the tool's own record. The kit a task runs is the `Tool kit: <name>` line of
# <data>/<task>/brief.md; the receipt, the saved record and report.md live beside it (<data>/<task>/kit/receipt.json, kit/record/).
# Every refusal prints one line, `jg-tool-kit: refused: <reason>`, and exits 1; a usage error exits 2. A caller refuses on every
# exit code but 0, so a missing kit folder or a crashed kit check never reads as a pass.
# JG_HOME is the home (default: this repository); JG_DATA_OVERRIDE its data folder; JG_TOOL_KITS_DIR another kit folder (tests).
set -u

TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROOT=$(cd "$TK/../.." && pwd)
SELF=$TK/bin/jg-tool-kit.sh
KITS=${JG_TOOL_KITS_DIR:-$TK/kits}
HOME_DIR=${JG_HOME:-$ROOT}
DATA=${JG_DATA_OVERRIDE:-$HOME_DIR/data}

usage() { sed -n '4,9p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 2; }
refuse() { echo "jg-tool-kit: refused: $*"; exit 1; }
command -v jq >/dev/null 2>&1 || refuse "jq is not installed"

plain() { case $1 in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
kit_ok() { plain "$1" && jq -e --arg n "$1" '.name == $n and (.names | type == "array") and (.words | type == "array") and (.tool.bin | type == "string") and (.card | type == "string")' "$KITS/$1/kit.json" >/dev/null 2>&1; }
need_kit() { kit_ok "$1" || refuse "unknown kit '$1': kits/$1/kit.json is missing or not a kit"; }
kit_names() { local f; for f in "$KITS"/*/kit.json; do [ -f "$f" ] && basename "$(dirname "$f")"; done; return 0; }
field() { jq -r "$2 // empty" "$KITS/$1/kit.json"; }  # <kit> <jq path>

norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' ' ' | tr -s ' ' | sed 's/^ //; s/ $//'; }
in_ask() { local p; for p in "$@"; do p=$(norm "$p"); [ -n "$p" ] || continue; case $ASK in *" $p "*) return 0 ;; esac; done; return 1; }

cmd_list() {
  local k
  for k in $(kit_names); do if kit_ok "$k"; then printf '%s\t%s\n' "$k" "$(field "$k" .says)"; fi; done
}

# resolve: a kit the ask names wins; else build words make it a Ship; else exactly one kit's words pick it; two or none: no Specialist.
cmd_resolve() {
  local k w named=() worded=() build=() pick=()
  ASK=" $(norm "${1:-}") "
  mapfile -t build < "$TK/build-words.txt"
  for k in $(kit_names); do
    kit_ok "$k" || continue
    mapfile -t w < <(jq -r '.names[]' "$KITS/$k/kit.json"); if in_ask "${w[@]}"; then named+=("$k"); fi
    mapfile -t w < <(jq -r '.words[]' "$KITS/$k/kit.json"); if in_ask "${w[@]}"; then worded+=("$k"); fi
  done
  if [ ${#named[@]} -gt 0 ]; then pick=("${named[@]}")
  elif ! in_ask "${build[@]}"; then pick=("${worded[@]}"); fi
  if [ ${#pick[@]} -eq 1 ]; then echo "specialist ${pick[0]}"; else echo none; fi
}

cmd_section() {
  local kit=${1:-} task=${2:-<task-id>}
  need_kit "$kit"; [ -f "$KITS/$kit/brief.md" ] || refuse "kit '$kit' has no brief.md"
  [ "$task" = '<task-id>' ] || plain "$task" || refuse "'$task' is not a plain task id"
  sed -e "s|{task}|$task|g" -e "s|{data}|$DATA/$task|g" -e "s|{tool-kit}|$SELF|g" "$KITS/$kit/brief.md"
}

find_board() {
  local l
  for l in jg-compat jg-squad-lead-parent-lib jg-board-link-lib; do
    # shellcheck source=/dev/null
    [ -f "$ROOT/bin/$l.sh" ] && . "$ROOT/bin/$l.sh"
  done
  BOARD=$(jg_board_file "$HOME_DIR") || refuse "no board found: JG_PROOF_BOARD, or --board in config/post-merge of $HOME_DIR or its parent home"
}

task_kit() {  # <task>: set KIT from the task's instructions
  local f=$DATA/$1/brief.md
  [ -f "$f" ] || refuse "no instructions at $f"
  KIT=$(sed -n 's/^Tool kit:[[:space:]]*//p' "$f" | head -n 1 | tr -d '[:space:]')
  [ -n "$KIT" ] || refuse "the instructions of $1 have no 'Tool kit:' line"
}

version_ok() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]; }  # <version> <minimum>

cmd_receipt() {
  local task=${1:-} card='' paths=() dir kj p g f rel n=0 files='[]' secs min
  shift 2>/dev/null || usage
  while [ $# -gt 0 ]; do
    case $1 in --card) card=${2:-}; shift 2 || usage ;; -*) usage ;; *) paths+=("$1"); shift ;; esac
  done
  plain "$task" && plain "$card" && [ ${#paths[@]} -gt 0 ] || usage
  task_kit "$task"; need_kit "$KIT"; kj=$KITS/$KIT/kit.json
  command -v "$(field "$KIT" .tool.bin)" >/dev/null 2>&1 || refuse "the tool '$(field "$KIT" .tool.bin)' is not installed"
  VER=$("$(field "$KIT" .tool.bin)" --version 2>&1 | grep -o -E '[0-9]+(\.[0-9]+)+' | head -n 1)
  min=$(field "$KIT" .tool.min)
  { [ -n "$VER" ] && version_ok "$VER" "${min:-0}"; } || refuse "$(field "$KIT" .tool.bin) '${VER:-unknown}' is older than the kit's minimum ${min:-0}"
  dir=$DATA/$task/kit; mkdir -p "$dir/record"
  for p in "${paths[@]}"; do
    [ -d "$p" ] || refuse "$p is not a folder"
    while IFS= read -r g; do
      [ -f "$p/$g" ] || continue
      mkdir -p "$dir/record/$(dirname "$g")"; cp "$p/$g" "$dir/record/$g"; n=$((n + 1))
    done < <(jq -r '.record[]?' "$kj")
    [ "$n" -gt 0 ] || refuse "no run record in $p: the $KIT kit expects $(jq -r '.record | join(", ")' "$kj")"
    while IFS= read -r g; do
      while IFS= read -r f; do
        rel=${f#"$p"/}; secs=''
        case $f in *.mp4|*.webm) secs=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f") || refuse "ffprobe cannot read $rel" ;; esac
        files=$(jq -c --arg p "$rel" --argjson s "$(stat -c %s "$f")" --arg h "$(sha256sum "$f" | cut -d' ' -f1)" --arg t "$secs" \
          '. + [{path: $p, size: $s, sha256: $h} + (if $t == "" then {} else {seconds: ($t | tonumber)} end)]' <<<"$files")
      done < <(compgen -G "$p/$g")
    done < <(jq -r '.outputs[]?' "$kj")
  done
  [ "$files" != '[]' ] || refuse "no output file in ${paths[*]}: the $KIT kit expects $(jq -r '.outputs | join(", ")' "$kj")"
  jq -n --arg task "$task" --arg kit "$KIT" --arg bin "$(field "$KIT" .tool.bin)" --arg ver "$VER" --arg card "$card" --argjson files "$files" --argjson at "$(date +%s)" \
    '{schema: 1, task: $task, kit: $kit, tool: {bin: $bin, version: $ver}, card: $card, files: $files, at: $at}' > "$dir/receipt.json.new" && mv "$dir/receipt.json.new" "$dir/receipt.json"
  echo "jg-tool-kit: receipt saved: $dir/receipt.json ($(jq '.files | length' "$dir/receipt.json") output files, card $card)"
}

cmd_check() {
  local task=${1:-} dir rc line out card min
  plain "$task" || usage
  task_kit "$task"; need_kit "$KIT"
  dir=$DATA/$task/kit
  [ -f "$dir/receipt.json" ] || refuse "no kit receipt at $dir/receipt.json"
  jq -e '.schema == 1 and (.card | type == "string") and (.tool.version | type == "string")' "$dir/receipt.json" >/dev/null 2>&1 || refuse "the kit receipt of $task is not readable"
  [ "$(jq -r .kit "$dir/receipt.json")" = "$KIT" ] || refuse "the receipt names kit '$(jq -r .kit "$dir/receipt.json")', the instructions name '$KIT'"
  min=$(field "$KIT" .tool.min)
  version_ok "$(jq -r .tool.version "$dir/receipt.json")" "${min:-0}" || refuse "the receipt's tool version is older than the kit's minimum ${min:-0}"
  card=$(jq -r .card "$dir/receipt.json")
  find_board
  jq -ce --arg k "$card" --arg t "$(field "$KIT" .card)" '[.items[]? | select(.key == $k and .type == $t)][0] // empty' "$BOARD" > "$dir/card.json" 2>/dev/null \
    || refuse "the board $BOARD holds no $(field "$KIT" .card) card under key $card"
  out=$(bash "$KITS/$KIT/check.sh" "$dir" "$BOARD" "$dir/card.json" 2>&1); rc=$?
  line=$(printf '%s\n' "$out" | tail -n 1)
  case $rc:$line in
    0:PASS*) ;;
    1:refused:*) refuse "${line#refused: }" ;;
    *) refuse "the $KIT check crashed (exit $rc): $line" ;;
  esac
  if ! { [ -f "$DATA/$task/report.md" ] && grep -qwF -- "$card" "$DATA/$task/report.md"; }; then refuse "report.md is missing or does not name the card $card"; fi
  echo "jg-tool-kit: PASS - $KIT: ${line#PASS - }"
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case $cmd in
  list) cmd_list ;;
  resolve) [ $# -eq 1 ] || usage; cmd_resolve "$1" ;;
  section) [ $# -ge 1 ] || usage; cmd_section "$@" ;;
  board) find_board; echo "$BOARD" ;;
  receipt) cmd_receipt "$@" ;;
  check) [ $# -eq 1 ] || usage; cmd_check "$1" ;;
  *) usage ;;
esac

#!/usr/bin/env bash
# Project state map, the refresh: search, read, prove and draw one project's card, and only when the code changed.
# Usage: psm-refresh.sh run <project-dir> --state <dir> --board <board.json> [--force] [--opt-in] [--max-usd N] [--replay reply.txt] [--filed iso]
#        psm-refresh.sh tick <home> [--force]
# run   Searches the project and forms the refresh key: the tree plus the hash of the hit text. When the key equals the
#       one stored in --state (and a card exists) it prints "unchanged: ..." and stops: no model call, no board write.
#       Otherwise it reads (psm-read.sh, so --opt-in, the spend cap and --replay apply), proves, posts the new card and
#       dismisses the one it replaces, then stores the key. --force skips the comparison. A refused or failed read leaves the
#       old card and the stored key alone. Each card gets a new key (tree plus the run time) because a board refuses a key it holds.
# tick  For the scheduled check. Reads <home>/config/project-state-map, one line per project: "<project-dir> [opt-in]"
#       (# starts a comment), and the board from <home>/config/fleet-board. Keeps state under <home>/state/project-state-map/.
#       Silent when nothing changed, when the file is absent, and when a project has no opt-in; prints one line per refresh or failure.
# Exit: 0 refreshed or unchanged, 2 bad input, 3 the read was refused, 4 the read, proof or post failed.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

run() { # run <project-dir> <state> <board> <force> <optin> <cap> <replay> <filed>
  local pdir=$1 state=$2 board=$3 force=$4 optin=$5 cap=$6 replay=$7 filed=$8 t name key rc=0 prev='' ck now
  [ -d "$pdir" ] || { echo "psm-refresh: not a directory: $pdir" >&2; return 2; }
  pdir=$(cd "$pdir" && pwd -P); name=$(basename "$pdir")
  t=$(mktemp -d); mkdir -p "$state"
  bash "$here/psm-search.sh" "$pdir" --out "$t/hits.json" || { rm -rf -- "$t"; return 4; }
  key=$(jq -r '"\(.tree):\(.hit_hash)"' "$t/hits.json")
  if [ "$force" = 0 ] && [ -s "$state/key" ] && [ -s "$state/card-key" ] && [ "$(cat "$state/key")" = "$key" ]; then
    echo "unchanged: $name (tree $(jq -r '.tree[:8]' "$t/hits.json"))"; rm -rf -- "$t"; return 0
  fi
  local args=("$t/hits.json" --project-dir "$pdir" --out "$t/map.json" --max-usd "$cap")
  [ "$optin" = 0 ] || args+=(--opt-in)
  [ -z "$replay" ] || args+=(--replay "$replay")
  bash "$here/psm-read.sh" "${args[@]}" 2>"$t/err" || rc=$?
  if [ "$rc" != 0 ]; then
    echo "refused: $name: $(tail -1 "$t/err")" >&2; rm -rf -- "$t"; [ "$rc" = 3 ] && return 3; return 4
  fi
  bash "$here/psm-prove.sh" "$t/map.json" "$pdir" --out "$t/proved.json" 2>"$t/err" || { echo "failed: $name: $(tail -1 "$t/err")" >&2; rm -rf -- "$t"; return 4; }
  now=$(date +%s); [ -n "$filed" ] || filed=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  [ ! -s "$state/card-key" ] || prev=$(cat "$state/card-key")
  bash "$here/psm-card.sh" "$t/proved.json" --out-dir "$t/card" --filed "$filed" --rev "$now" --post "$board" ${prev:+--replaces "$prev"} >/dev/null 2>"$t/err" ||
    { echo "failed: $name: card not posted: $(tail -1 "$t/err")" >&2; rm -rf -- "$t"; return 4; }
  ck=$(jq -r .key "$t/card/report.json")
  printf '%s\n' "$key" > "$state/key.new" && mv "$state/key.new" "$state/key"
  printf '%s\n' "$ck" > "$state/card-key.new" && mv "$state/card-key.new" "$state/card-key"
  cp "$t/proved.json" "$state/proved.json"
  jq -r --arg n "$name" --arg c "$ck" '"refreshed: \($n) card \($c): \(.machines | length) machines, \(.machinery | length) parts, \(.proof.dropped_count) lines dropped"' "$t/proved.json"
  rm -rf -- "$t"
}

mode=${1:-}; shift || true
case "$mode" in
  run)
    pdir='' state='' board='' force=0 optin=0 cap=${PSM_MAX_USD:-0.05} replay='' filed=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --state) state=${2:?}; shift 2 ;;
        --board) board=${2:?}; shift 2 ;;
        --force) force=1; shift ;;
        --opt-in) optin=1; shift ;;
        --max-usd) cap=${2:?}; shift 2 ;;
        --replay) replay=${2:?}; shift 2 ;;
        --filed) filed=${2:?}; shift 2 ;;
        -*) echo "psm-refresh: unknown argument $1" >&2; exit 2 ;;
        *) [ -z "$pdir" ] || { echo 'psm-refresh: one project only' >&2; exit 2; }; pdir=$1; shift ;;
      esac
    done
    [ -n "$pdir" ] && [ -n "$state" ] && [ -n "$board" ] || { sed -n 2,3p "$0" | cut -c3- >&2; exit 2; }
    run "$pdir" "$state" "$board" "$force" "$optin" "$cap" "$replay" "$filed" ;;
  tick)
    home=${1:?psm-refresh: tick needs a home}; shift; force=0
    [ "${1:-}" != --force ] || force=1
    [ -f "$home/config/project-state-map" ] || exit 0
    board=$(tr -d '\n' < "$home/config/fleet-board" 2>/dev/null || true)
    [ -n "$board" ] || { echo 'psm-refresh: config/fleet-board names no board' >&2; exit 4; }
    status=0
    while read -r dir flag _; do
      case "$dir" in ''|'#'*) continue ;; esac
      [ "$flag" = opt-in ] || continue
      out=$(run "$dir" "$home/state/project-state-map/$(basename "$dir")" "$board" "$force" 1 "${PSM_MAX_USD:-0.05}" '' '' 2>&1) || status=4
      case "$out" in unchanged:*|'') ;; *) printf '%s\n' "$out" ;; esac
    done < "$home/config/project-state-map"
    exit "$status" ;;
  -h|--help) sed -n 2,4p "$0" | cut -c3-; exit 0 ;;
  '') sed -n 2,4p "$0" | cut -c3- >&2; exit 2 ;;
  *) echo "psm-refresh: unknown mode $mode" >&2; exit 2 ;;
esac

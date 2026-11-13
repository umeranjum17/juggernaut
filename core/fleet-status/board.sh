#!/usr/bin/env bash
# board.sh - the fleet status board: every state machine of core/machines/tables, in every registered home, as one row per
# machine and home. It reads today's tables and observers and writes nothing.
#
# Usage:
#   board.sh [--json]          print the board model (juggernaut-axi.v1, view board) as JSON; `juggernaut-axi board` renders it
#   board.sh --cell <home> <machine>   one row, tab separated (the board runs this under the time bound)
#   board.sh --digest <home>           write the home's digest, data/fleet-status/digest.tsv: every row of the home, read once, and its steps rollup
#   board.sh --steps [--json]          time per step from every home's rollup (steps.sh, H48)
#
# A row says: records (the ones the machine lists), the count in each state, past_limit (records that stayed in a state with a
# time limit longer than that limit; the age is the age of the record file), no_state (records whose observer names no state of
# the table) and wired (the machine has a record lister in records.tsv and an observer in its table).
# Each row is read within JG_BOARD_BOUND seconds (default 10); a row not read in that time, and a home with no tables, is named
# in `unread`, never left out. words.tsv maps the four delivery words (Built, Landed, In use, Released) onto machine states.
set -u
export LC_ALL=C
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
BOUND=${JG_BOARD_BOUND:-10}

secs() { case "$1" in *s) echo "${1%s}" ;; *m) echo $((${1%m} * 60)) ;; *h) echo $((${1%h} * 3600)) ;; *d) echo $((${1%d} * 86400)) ;; esac; }

cell() {  # <home> <machine>
  local home=$1 m=$2 tbl obs lister word i epoch now n=0 none=0 past=0 lim s
  tbl=$home/core/machines/tables
  [ -f "$tbl/$m.tsv" ] || { printf '%s\t%s\tno\t0\t\t0\t0\n' "$(basename "$home")" "$m"; return; }
  obs=$(awk -F'\t' '$1 == "observer" { print $2; exit }' "$tbl/$m.tsv")
  lister=$(awk -F'\t' -v m="$m" '$1 == m { print $2; exit }' "$HERE/records.tsv")
  if [ -z "$obs" ] || [ -z "$lister" ]; then printf '%s\t%s\tno\t0\t\t0\t0\n' "$(basename "$home")" "$m"; return; fi
  export JG_HOME=$home JG_STATE_OVERRIDE=$home/state JG_DATA_OVERRIDE=$home/data JG_MACHINES_TABLES=$tbl
  [ ! -d "$home/config" ] || export JG_CONFIG_OVERRIDE=$home/config
  STATE=$home/state DATA=$home/data; export STATE DATA
  now=$(date +%s)
  declare -A cnt=() limit=()
  while IFS=$'\t' read -r s lim; do limit[$s]=$lim; cnt[$s]=0; done < <(awk -F'\t' '$1 == "state" && $3 != "composite" { print $2 "\t" $7 }' "$tbl/$m.tsv")
  while IFS=$'\t' read -r i epoch; do
    [ -n "$i" ] || continue
    n=$((n + 1))
    word=$(bash -c "$obs" _ "$i" 2>/dev/null | head -1)
    if [ -z "$word" ] || [ -z "${cnt[$word]+x}" ]; then none=$((none + 1)); continue; fi
    cnt[$word]=$((cnt[$word] + 1))
    if [[ ${limit[$word]:-} =~ ^([0-9]+[smhd])\ -\> ]] && [[ $epoch =~ ^[0-9]+$ ]]; then
      lim=$(secs "${limit[$word]%% *}"); [ $((now - epoch)) -le "$lim" ] || past=$((past + 1))
    fi
  done < <(bash -c "$lister")
  local list="" k
  for k in "${!cnt[@]}"; do [ "${cnt[$k]}" -eq 0 ] || list+="${list:+,}$k=${cnt[$k]}"; done
  printf '%s\t%s\tyes\t%s\t%s\t%s\t%s\n' "$(basename "$home")" "$m" "$n" "$list" "$past" "$none"
}

if [ "${1:-}" = --cell ]; then cell "${2:?home}" "${3:?machine}"; exit 0; fi
if [ "${1:-}" = --digest ]; then  # <home>: the home's rows, read once, written whole or not at all
  home=${2:?home}; dir=$home/data/fleet-status; mkdir -p "$dir" || exit 1
  moves=$(JG_HOME=$home JG_STATE_OVERRIDE=$home/state JG_DATA_OVERRIDE=$home/data bash "$HERE/../machines/observers/cursor.sh" read board 2>/dev/null | wc -l)
  { printf '#digest\t%s\t%s\n' "$(date +%s)" "$moves"
    for t in "$home"/core/machines/tables/*.tsv; do m=${t##*/}; cell "$home" "${m%.tsv}"; done; } > "$dir/digest.tsv.tmp" \
    && mv -f -- "$dir/digest.tsv.tmp" "$dir/digest.tsv" && bash "$HERE/steps.sh" --rollup "$home"
  exit $?
fi
if [ "${1:-}" = --steps ]; then shift; exec bash "$HERE/steps.sh" "$@"; fi
if [ "${1:-}" = --run ] && [ "${5:-}" = - ]; then  # <out dir> <home id> <home dir> -: the home's rows from its digest
  out=$2 id=$3 dir=$4 f=$4/data/fleet-status/digest.tsv
  age=$(( $(date +%s) - $(awk -F'\t' 'NR == 1 && $1 == "#digest" { print $2 }' "$f" 2>/dev/null | grep -E '^[0-9]+$' || echo 0) ))
  if [ "$age" -le "${JG_BOARD_DIGEST_AGE:-900}" ]; then awk -F'\t' -v id="$id" 'NR > 1 { print id "\t" $0 }' "$f" > "$out/$id.digest"
  else printf '%s\t-\tthe digest is late: %s s old\n' "$id" "$age" > "$out/$id.late"; fi
  exit 0
fi
if [ "${1:-}" = --run ]; then  # <out dir> <home id> <home dir> <machine>: one row under the bound, into its own file
  out=$2 id=$3 dir=$4 m=$5
  line=$(timeout "$BOUND" bash "$HERE/board.sh" --cell "$dir" "$m" 2>/dev/null); rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$line" ]; then printf '%s\t%s\n' "$id" "$line" > "$out/$id.$m.row"
  else printf '%s\t%s\t%s\n' "$id" "$m" "$([ "$rc" -eq 124 ] && echo "not read in ${BOUND} s" || echo "the read failed")" > "$out/$id.$m.unread"; fi
  exit 0
fi
[ "${1:-}" = "" ] || [ "${1:-}" = --json ] || { echo "usage: board.sh [--json]" >&2; exit 2; }

# The homes: every local registered home, then Main (jg_fleet_homes), each read as it is today.
# shellcheck disable=SC1091
. "$ROOT/bin/jg-compat.sh"; . "$ROOT/bin/jg-squad-lead-parent-lib.sh"; . "$ROOT/bin/jg-squad-lead-registry-lib.sh"; . "$ROOT/bin/jg-fleet-homes-lib.sh"
HOME_DIR=${JG_HOME:-$ROOT}
JG_ROOT=$HOME_DIR
out=$(mktemp -d); trap 'rm -rf -- "$out"' EXIT; rows=$out/rows unread=$out/unread
: > "$rows"; : > "$unread"
mkdir "$out/cells"
# shellcheck disable=SC2016
{
  while IFS=$'\t' read -r _ id dir; do
    [ ! -s "$dir/data/fleet-status/digest.tsv" ] || { printf '%s\0%s\0%s\0' "$id" "$dir" -; continue; }
    [ -d "$dir/core/machines/tables" ] || { printf '%s\t-\tthe home has no machine tables\n' "$id" >> "$unread"; continue; }
    for t in "$dir"/core/machines/tables/*.tsv; do m=${t##*/}; printf '%s\0%s\0%s\0' "$id" "$dir" "${m%.tsv}"; done
  done < <(jg_fleet_homes "$HOME_DIR" "$JG_ROOT")
} | xargs -0 -n3 -P "${JG_BOARD_JOBS:-6}" bash -c 'bash "$0" --run "$1" "$2" "$3" "$4"' "$HERE/board.sh" "$out/cells" 2>/dev/null || true
cat "$out"/cells/*.row "$out"/cells/*.digest >> "$rows" 2>/dev/null; cat "$out"/cells/*.unread "$out"/cells/*.late >> "$unread" 2>/dev/null
jq -Rn --slurpfile _ /dev/null --arg bound "$BOUND" --rawfile rows "$rows" --rawfile unread "$unread" --rawfile words "$HERE/words.tsv" '
  ($rows | split("\n") | map(select(. != "") | split("\t"))) as $r
  | ($unread | split("\n") | map(select(. != "") | split("\t") | {home: .[0], machine: .[1], why: .[2]})) as $u
  | ($r | map({home: .[0], machine: .[2], wired: (.[3] == "yes"), records: (.[4] | tonumber), past_limit: (.[6] | tonumber), no_state: (.[7] | tonumber),
               states: (.[5] | if . == "" then {} else split(",") | map(split("=") | {key: .[0], value: (.[1] | tonumber)}) | from_entries end)})) as $m
  | ($words | split("\n") | map(select(. != "") | split("\t"))) as $w
  | {schema: "juggernaut-axi.v1", view: "board", bound_seconds: ($bound | tonumber),
     words: [$m | group_by(.home)[] | .[0].home as $h | {home: $h} + ([$w[] | . as $x
        | {key: $x[0], value: ([$m[] | select(.home == $h and .machine == $x[1]) | .states | to_entries[] | select(.key as $k | $x[2:] | index($k)) | .value] | add // 0)}] | from_entries)],
     count: ($m | length), rows: $m, unread: $u}'

#!/usr/bin/env bash
# compare.sh - compare the machine view with the source records, for one home: every difference is listed and explained.
# The view is readings.sh under the digest's bound (the same read digest.sh rolls up). The source is compare-sources.tsv: each machine's raw
# files read by plain find/stat/awk, not by its lister. It writes nothing.
#
# Usage: compare.sh <home> [--bound <seconds>] [--now <epoch>]
# Output: one line for each difference: `<machine> <kind> <id> <detail> - <reason>`, or `UNEXPLAINED` in place of the reason; one line for each
#   machine that matched (`<machine> ok <n> records`); a last line `compared: <n> machines, <d> differences, <u> unexplained`.
# A missing home is one `home unreadable` difference. The difference kinds are in compare-explain.tsv.
# Exit: 0 every difference explained, 1 an unexplained difference, 2 usage.
set -u
export LC_ALL=C
# shellcheck source=core/fleet-status/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
usage() { echo "usage: compare.sh <home> [--bound <seconds>] [--now <epoch>]" >&2; exit 2; }
home=${1:-}; [ -n "$home" ] || usage; shift
bound=${JG_MACHINE_DIGEST_BOUND:-10} now=$(date +%s)
while [ $# -gt 0 ]; do
  case $1 in --bound) bound=${2:-}; shift 2 || usage ;; --now) now=${2:-}; shift 2 || usage ;; *) usage ;; esac
done
[[ $bound =~ ^[1-9][0-9]*$ ]] && [[ $now =~ ^[0-9]+$ ]] || usage
nd=0 nu=0
explain() { awk -F'\t' -v k="$1" -v m="$2" '$1 !~ /^#/ && $1 == k && ($2 == m || $2 == "*") { r = $3; if ($2 == m) { print r; exit } else if (g == "") g = r } END { if (g != "") print g }' "$FS_DIR/compare-explain.tsv" | head -1; }
differ() {  # <machine> <kind> <id> <detail>
  local why; why=$(explain "$2" "$1"); nd=$((nd + 1)); [ -n "$why" ] || { why=UNEXPLAINED; nu=$((nu + 1)); }
  printf '%s %s %s %s - %s\n' "$1" "$2" "$3" "$4" "$why"
}
home=$(cd "$home" 2>/dev/null && pwd -P) || { differ home unreadable - "no such home"; printf 'compared: 0 machines, %d differences, %d unexplained\n' "$nd" "$nu"; [ "$nu" -eq 0 ]; exit; }
fs_env "$home"
# not a jg-* name: the cleanup machine lists those, and the comparison must not read itself
tmp=$(mktemp -d "${TMPDIR:-/tmp}/machine-compare.XXXXXX") || exit 1
trap 'rm -rf -- "$tmp"' EXIT
machines=$(cut -f1 "$FS_DIR/records.tsv" | sort)
for m in $machines; do
  { timeout "$bound" bash "$FS_DIR/readings.sh" "$home" "$m" --now "$now" > "$tmp/$m.view" 2>/dev/null || echo timeout > "$tmp/$m.timeout"; } &
done
wait
n=0
for m in $machines; do
  n=$((n + 1))
  src=$(awk -F'\t' -v m="$m" '$1 == m { print $2; exit }' "$FS_DIR/compare-sources.tsv")
  if [ -e "$tmp/$m.timeout" ]; then
    cnt=''; [ -z "$src" ] || cnt=$(bash -c "$src" 2>/dev/null | grep -c .)
    differ "$m" timeout - "no reading in ${bound}s; source holds ${cnt:-?} records"; continue
  fi
  if [ -z "$src" ]; then differ "$m" nosource - "$(grep -c . "$tmp/$m.view") records in the view"; continue; fi
  bash -c "$src" 2>/dev/null | awk -F'\t' 'NF >= 1 && $1 != "" { print $1 "\t" $2 }' | sort -u -t "$(printf '\t')" -k1,1 > "$tmp/$m.src"
  awk -F'\t' '$2 != "-" { print $2 "\t" $4 "\t" $5 }' "$tmp/$m.view" | sort -u -t "$(printf '\t')" -k1,1 > "$tmp/$m.vw"
  bad=0
  while IFS= read -r id; do differ "$m" missing "$id" "in the source, not in the view"; bad=1; done < <(comm -23 <(cut -f1 "$tmp/$m.src") <(cut -f1 "$tmp/$m.vw"))
  while IFS= read -r id; do differ "$m" extra "$id" "in the view, not in the source"; bad=1; done < <(comm -13 <(cut -f1 "$tmp/$m.src") <(cut -f1 "$tmp/$m.vw"))
  # the age of each record both hold: the view's age against now minus the source's time
  while IFS=$'\t' read -r id sepoch vage; do
    [[ $sepoch =~ ^[0-9]+$ ]] && [[ $vage =~ ^[0-9]+$ ]] || continue
    d=$(( (now - sepoch) - vage )); d=${d#-}
    [ "$d" -le 2 ] || { differ "$m" age "$id" "source age $((now - sepoch))s, view age ${vage}s"; bad=1; }
  done < <(join -t "$(printf '\t')" -j1 "$tmp/$m.src" "$tmp/$m.vw" | awk -F'\t' '{ print $1 "\t" $2 "\t" $4 }')
  [ "$bad" -eq 1 ] || printf '%s ok %d records\n' "$m" "$(grep -c . "$tmp/$m.src")"
done
printf 'compared: %d machines, %d differences, %d unexplained\n' "$n" "$nd" "$nu"
[ "$nu" -eq 0 ]

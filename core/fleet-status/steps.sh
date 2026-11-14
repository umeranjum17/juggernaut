#!/usr/bin/env bash
# steps.sh - time per step on the fleet status board (H48): for every machine and step, n, median, p90 and worst time over 7 days,
# and the records waiting in the step now (count, oldest). Each home rolls its own move log up; the board reads only the rollups.
#
# Usage:
#   steps.sh --rollup <home>   write <home>/data/fleet-status/steps.tsv from <home>/data/machine-moves.log (board.sh --digest runs it on the tick)
#   steps.sh [--json]          print the steps model (juggernaut-axi.v1, view board-steps) from every home's rollup; `juggernaut-axi board --steps` renders it
#
# A step is a state a record left: the time from the move that put the record in `from` to the move that took it out to `to`
# (table words, `from -> to`). A move counts when it is in the last 7 days. The percentile is the nearest rank (ceil(p * n)) of the
# step's times, so a hand count of the log gives the same number. A record whose last move put it in a non-terminal state is waiting
# there; its wait is shown on the step of that state with the most moves, or on its own `from -> (still here)` row when no record left it.
# The longest total waiting time leads the list, then the worst time. A home with no rollup is named in `unread`; nothing is guessed.
# Rollup file: `#steps <epoch>` then `<machine> <from> <to> <n> <median s> <p90 s> <worst s> <waiting> <oldest s> <waiting sum s>`, tab separated.
set -u
export LC_ALL=C
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
WINDOW=604800

rollup() {  # <home>: written whole or not at all
  local home=$1 dir=$1/data/fleet-status log=$1/data/machine-moves.log t m term
  mkdir -p "$dir" || return 1
  term=$(mktemp) || return 1
  for t in "$home"/core/machines/tables/*.tsv; do
    [ -f "$t" ] || continue; m=${t##*/}
    awk -F'\t' -v m="${m%.tsv}" '$1 == "state" && $3 == "terminal" { print m "\t" $2 }' "$t"
  done > "$term"
  {
    printf '#steps\t%s\n' "$(date +%s)"
    if [ -s "$log" ]; then
      sort -s -n -k1,1 "$log" | awk -F'\t' -v now="$(date +%s)" -v win="$WINDOW" -v termf="$term" '
        BEGIN { while ((getline l < termf) > 0) { split(l, a, "\t"); terminal[a[1] SUBSEP a[2]] = 1 } }
        $1 ~ /^[0-9]+$/ && NF >= 6 && $3 != "-" && $3 != "" {
          rec = $2 SUBSEP $3
          if ((rec in state) && state[rec] == $4 && $1 >= now - win) {
            k = $2 "\t" $4 "\t" $6; d = $1 - at[rec]; if (d < 0) d = 0
            if (!(k in n)) order[++nk] = k
            dur[k, ++n[k]] = d
          }
          state[rec] = $6; at[rec] = $1; mach[rec] = $2
        }
        function sorted(k, arr,   i, j, v) {  # insertion sort of the step'"'"'s times
          for (i = 1; i <= n[k]; i++) arr[i] = dur[k, i]
          for (i = 2; i <= n[k]; i++) { v = arr[i]; for (j = i - 1; j >= 1 && arr[j] > v; j--) arr[j + 1] = arr[j]; arr[j + 1] = v }
        }
        function rank(c, p,   r) { r = int(p * c); if (r < p * c) r++; return r < 1 ? 1 : r }
        END {
          for (rec in state) {
            if ((mach[rec] SUBSEP state[rec]) in terminal) continue
            w = mach[rec] "\t" state[rec]; wn[w]++; age = now - at[rec]; if (age < 0) age = 0
            ws[w] += age; if (age > wo[w]) wo[w] = age
          }
          for (i = 1; i <= nk; i++) {
            k = order[i]; split(k, p, "\t"); w = p[1] "\t" p[2]
            if (!(w in host) || n[k] > n[host[w]]) host[w] = k
          }
          for (i = 1; i <= nk; i++) {
            k = order[i]; split(k, p, "\t"); w = p[1] "\t" p[2]; delete arr; sorted(k, arr)
            wc = 0; wold = 0; wsum = 0
            if (host[w] == k) { wc = wn[w]; wold = wo[w]; wsum = ws[w]; used[w] = 1 }
            printf "%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", p[1], p[2], p[3], n[k], arr[rank(n[k], 0.5)], arr[rank(n[k], 0.9)], arr[n[k]], wc, wold, wsum
          }
          for (w in wn) if (!(w in used)) { split(w, p, "\t"); printf "%s\t%s\t(still here)\t0\t0\t0\t0\t%d\t%d\t%d\n", p[1], p[2], wn[w], wo[w], ws[w] }
        }'
    fi
  } > "$dir/steps.tsv.tmp" && mv -f -- "$dir/steps.tsv.tmp" "$dir/steps.tsv"
  local rc=$?; rm -f -- "$term"; return $rc
}

if [ "${1:-}" = --rollup ]; then rollup "${2:?home}"; exit $?; fi
[ "${1:-}" = "" ] || [ "${1:-}" = --json ] || { echo "usage: steps.sh [--rollup <home>|--json]" >&2; exit 2; }

# shellcheck disable=SC1091
. "$ROOT/bin/jg-compat.sh"; . "$ROOT/bin/jg-squad-lead-parent-lib.sh"; . "$ROOT/bin/jg-squad-lead-registry-lib.sh"; . "$ROOT/bin/jg-fleet-homes-lib.sh"
HOME_DIR=${JG_HOME:-$ROOT}; JG_ROOT=$HOME_DIR
rows=$(mktemp); unread=$(mktemp); trap 'rm -f -- "$rows" "$unread"' EXIT
while IFS=$'\t' read -r _ id dir; do
  f=$dir/data/fleet-status/steps.tsv
  if [ -s "$f" ]; then awk -F'\t' -v id="$id" 'NR > 1 { print id "\t" $0 }' "$f" >> "$rows"
  else printf '%s\t-\tno steps rollup yet\n' "$id" >> "$unread"; fi
done < <(jg_fleet_homes "$HOME_DIR" "$JG_ROOT")
jq -Rn --rawfile rows "$rows" --rawfile unread "$unread" '
  def human: if . < 120 then "\(.) s" elif . < 7200 then "\(. / 60 * 10 | round / 10) m" elif . < 172800 then "\(. / 3600 * 10 | round / 10) h" else "\(. / 86400 * 10 | round / 10) d" end;
  ($rows | split("\n") | map(select(. != "") | split("\t"))) as $r
  | ($unread | split("\n") | map(select(. != "") | split("\t") | {home: .[0], why: .[2]})) as $u
  | ($r | map({home: .[0], machine: .[1], step: "\(.[2]) -> \(.[3])", n: (.[4] | tonumber), median_s: (.[5] | tonumber), p90_s: (.[6] | tonumber),
               worst_s: (.[7] | tonumber), waiting: (.[8] | tonumber), oldest_s: (.[9] | tonumber), waiting_sum_s: (.[10] | tonumber)})
     | sort_by([-.waiting_sum_s, -.worst_s])
     | map(. + {median: (if .n == 0 then "-" else (.median_s | human) end), p90: (if .n == 0 then "-" else (.p90_s | human) end),
                worst: (if .n == 0 then "-" else (.worst_s | human) end),
                waiting_now: (if .waiting == 0 then "-" else "\(.waiting) (\(.oldest_s | human))" end)})) as $s
  | {schema: "juggernaut-axi.v1", view: "board-steps", window_days: 7, count: ($s | length), steps: $s, unread: $u}'

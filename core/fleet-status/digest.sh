#!/usr/bin/env bash
# digest.sh - the bounded machine digest: one line for each declared machine of one home, stale and unknown first, under a byte cap.
# It rolls up readings.sh (the s1 listers) and writes nothing; the session digest prints it.
#
# Usage: digest.sh <home> [--cap <bytes>] [--now <epoch>]
# Output: a summary line (how many machines are fresh, stale and unknown), one line for each machine that is not fresh
# (unknown first, then stale, then by name), and last one line that names the fresh machines. When the cap is too small
# for all of it, the last lines are cut and a marker says how many machines were cut and how many of those are stale or unknown;
# the summary line and the first lines are never the part cut, so a stale or unknown machine drops only after every fresh one.
# The machines are read in parallel; one that does not answer in JG_MACHINE_DIGEST_BOUND seconds (default 10) reads unknown. A missing home reads
# unknown for every machine. A machine with no records is quiet and counts as fresh.
# Exit: 0 printed, 2 usage.
set -u
export LC_ALL=C
FS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
usage() { echo "usage: digest.sh <home> [--cap <bytes>] [--now <epoch>]" >&2; exit 2; }
home=${1:-}; [ -n "$home" ] || usage; shift
cap=3500 now=$(date +%s)
while [ $# -gt 0 ]; do
  case $1 in
    --cap) cap=${2:-}; shift 2 || usage ;;
    --now) now=${2:-}; shift 2 || usage ;;
    *) usage ;;
  esac
done
[[ $cap =~ ^[1-9][0-9]*$ ]] && [[ $now =~ ^[0-9]+$ ]] || usage
bound=${JG_MACHINE_DIGEST_BOUND:-10}; [[ $bound =~ ^[1-9][0-9]*$ ]] || bound=10

# One reading file for each machine, read in parallel so the whole read takes about one bound, not 24. A machine that has not
# answered in the bound writes a `timeout` line: it reads unknown, and is named, never left out.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jg-machine-digest.XXXXXX") || exit 0
trap 'rm -rf -- "$tmp"' EXIT
machines=$(cut -f1 "$FS_DIR/records.tsv" | sort)
for m in $machines; do
  { timeout "$bound" bash "$FS_DIR/readings.sh" "$home" "$m" --now "$now" > "$tmp/$m" 2>/dev/null || printf '%s\ttimeout\tunknown\t\t\tunknown\n' "$m" > "$tmp/$m"; } &
done
wait
# One row per machine: rank (0 unknown, 1 stale, 2 fresh), name, then the words of its line.
rows=$(
  for m in $machines; do
    awk -F'\t' -v m="$m" -v bound="$bound" '
      NF >= 6 { n++; if ($6 == "stale") { s++; if ($5 + 0 > worst) { worst = $5 + 0; wid = $2 } } else if ($6 == "unknown") { u++; if (uid == "") uid = $2 } }
      END {
        why = (uid == "timeout" ? " (no reading in " bound "s)" : uid == "-" ? " (home, machine or lister unreadable)" : " (first: " uid ")")
        if (u > 0) printf "0\t%s\t%s: unknown - %d of %d records unknown%s%s\n", m, m, u, n, why, (s > 0 ? "; " s " stale" : "")
        else if (s > 0) printf "1\t%s\t%s: stale - %d of %d records stale, oldest %s is %ds old\n", m, m, s, n, wid, worst
        else printf "2\t%s\t%s\n", m, m
      }' "$tmp/$m"
  done | sort -t "$(printf '\t')" -k1,1n -k2,2
)
total=$(printf '%s\n' "$rows" | grep -c .)
nu=$(printf '%s\n' "$rows" | grep -c '^0'); ns=$(printf '%s\n' "$rows" | grep -c '^1'); nf=$((total - nu - ns))

lines=$(printf 'machines: %d declared, %d fresh, %d stale, %d unknown\n' "$total" "$nf" "$ns" "$nu")$'\n'
lines+=$(printf '%s\n' "$rows" | awk -F'\t' '$1 != 2 { print $3 }')$'\n'
[ "$nf" -eq 0 ] || lines+="fresh ($nf): $(printf '%s\n' "$rows" | awk -F'\t' '$1 == 2 { printf "%s%s", sep, $2; sep = " " }')"$'\n'

printf '%s' "$lines" | awk -v cap="$cap" -v nu="$nu" -v ns="$ns" -v total="$total" '
  { line[++n] = $0 }
  END {
    # The marker is paid for out of the cap. The summary line is always kept.
    reserve = 150; used = 0; keep = 0
    for (i = 1; i <= n; i++) { if (i > 1 && used + length(line[i]) + 1 > cap - reserve) break; used += length(line[i]) + 1; keep = i }
    for (i = 1; i <= keep; i++) print line[i]
    if (keep < n) {
      # What was cut: every machine line after the summary, then the fresh line (which holds all fresh machines).
      cutm = 0; cutbad = 0
      for (i = keep + 1; i <= n; i++) { if (line[i] ~ /^fresh \(/) { match(line[i], /\([0-9]+\)/); cutm += substr(line[i], RSTART + 1, RLENGTH - 2) } else { cutm++; cutbad++ } }
      printf "[cut: %d of %d machines not shown, %d of them stale or unknown; all of them: core/fleet-status/digest.sh <home> --cap 100000]\n", cutm, total, cutbad
    }
  }'
exit 0

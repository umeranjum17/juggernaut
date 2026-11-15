#!/usr/bin/env bash
# release-ledger - one dated row per landing: when it was Built, Landed, In use and Released, and when it was reverted.
#
# Usage: ledger.sh build [--dry-run]
#
# Reads only the records the lander and the release already write and changes none of them:
#   built      the lane's done time: `done=<epoch>` on the landing's row of data/trunk-landing-proofs.tsv, else the ready
#              time of the older data/trunk-latency.tsv (no longer written, still read for the landings before the proofs)
#   landed     data/trunk-landings.tsv (one row per landing; a `revert-<lane>` row is a revert, never a landing)
#   in_use     the first `live` row of data/trunk-in-use.tsv whose commit holds the landing
#   released   the first row of data/trunk-versions.tsv whose cut commit holds the landing (the cut is the nearest record
#              of the release merge); `release` names that version's branch
#   reverted   the revert row whose `reverts-<12 hex>` mode names the landing's commit, and `reverted_by` its commit
# A stage that was never reached is an empty column, never a guess. "Holds" is git ancestry in projects/<project>
# (the home itself for a project with no clone here), found once per distinct commit with one incremental rev-list.
# `build` rewrites data/release-ledger.tsv from the records each time, so a second run on unchanged records is byte-equal.
# Columns (tab separated, epoch seconds): ticket project commit built landed in_use released release reverted reverted_by
# Env: JG_HOME (default: this repository), JG_DATA_OVERRIDE (default <home>/data).
set -u
export LC_ALL=C
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); root=$(cd "$here/../.." && pwd -P)
JG_HOME=${JG_HOME:-$root}
DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}
OUT=$DATA/release-ledger.tsv
usage() { sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
dry=0
[ "${1:-}" = build ] || usage
case "${2:-}" in --dry-run) dry=1 ;; '') ;; *) usage ;; esac
[ -s "$DATA/trunk-landings.tsv" ] || { echo "release-ledger: no landings in $DATA/trunk-landings.tsv" >&2; exit 1; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# hold_times <repo> <pairs-file of "sha<TAB>epoch<TAB>label"> -> "commit<TAB>epoch<TAB>label" for every commit a sha holds,
# at the earliest pair that holds it. Pairs are walked oldest first; each rev-list stops at what earlier shas already hold.
hold_times() {
  local repo=$1 pairs=$2 sha at label seen=$tmp/seen.$$
  : >"$seen"
  sort -t$'\t' -k2,2n -s "$pairs" | while IFS=$'\t' read -r sha at label; do
    git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null || continue
    grep -qx "$sha" "$seen" && continue
    { printf '%s\n' "$sha"; sed 's/^/^/' "$seen"; } | git -C "$repo" rev-list --stdin 2>/dev/null | awk -v a="$at" -v l="$label" '{ print $1 "\t" a "\t" l }'
    printf '%s\n' "$sha" >>"$seen"
  done
}

# built times, keyed task and commit: the older latency rows first, then the proofs' done times over them
{ awk -F'\t' 'NR > 1 && $5 + 0 > 0 { print $1 "\t" $3 "\t" $5 }' "$DATA/trunk-latency.tsv" 2>/dev/null
  awk -F'\t' '{ for (i = 5; i <= NF; i++) if ($i ~ /^done=[0-9]+$/) print $1 "\t" $3 "\t" substr($i, 6) }' "$DATA/trunk-landing-proofs.tsv" 2>/dev/null
} | awk -F'\t' '{ b[$1 "\t" $2] = $3 } END { for (k in b) print k "\t" b[k] }' >"$tmp/built"

: >"$tmp/rows"
while read -r proj; do
  repo=$JG_HOME/projects/$proj; git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || repo=$JG_HOME
  awk -F'\t' -v p="$proj" '$1 == p && $4 ~ /^live/ && $3 + 0 > 0 { print $2 "\t" $3 "\t-" }' "$DATA/trunk-in-use.tsv" 2>/dev/null >"$tmp/live.pairs"
  awk -F'\t' -v p="$proj" '$1 == p && $5 + 0 > 0 { print $4 "\t" $5 "\t" $3 }' "$DATA/trunk-versions.tsv" 2>/dev/null >"$tmp/ver.pairs"
  hold_times "$repo" "$tmp/live.pairs" | awk -F'\t' '!s[$1]++' >"$tmp/live.holds"
  hold_times "$repo" "$tmp/ver.pairs" | awk -F'\t' '!s[$1]++' >"$tmp/ver.holds"
  awk -F'\t' -v p="$proj" -v dir="$tmp" '
    BEGIN { while ((getline l < (dir "/built")) > 0) { split(l, f, "\t"); built[f[1] "\t" f[2]] = f[3] }
            while ((getline l < (dir "/live.holds")) > 0) { split(l, f, "\t"); live[f[1]] = f[2] }
            while ((getline l < (dir "/ver.holds")) > 0) { split(l, f, "\t"); ver[f[1]] = f[2]; vname[f[1]] = f[3] } }
    $2 != p { next }
    $1 ~ /^revert-/ { if ($5 ~ /^reverts-/) { n++; rp[n] = substr($5, 9); rat[n] = $4; rby[n] = $3 } next }
    { n2++; t[n2] = $1; c[n2] = $3; at[n2] = $4 }
    END { for (i = 1; i <= n2; i++) {
            rt = ""; rb = ""
            for (j = 1; j <= n; j++) if (rp[j] != "" && index(c[i], rp[j]) == 1) { rt = rat[j]; rb = rby[j] }
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", t[i], p, c[i], built[t[i] "\t" c[i]], at[i], live[c[i]], ver[c[i]], vname[c[i]], rt, rb } }
  ' "$DATA/trunk-landings.tsv" >>"$tmp/rows"
done < <(awk -F'\t' '$1 !~ /^revert-/ { print $2 }' "$DATA/trunk-landings.tsv" | sort -u)

{ printf 'ticket\tproject\tcommit\tbuilt\tlanded\tin_use\treleased\trelease\treverted\treverted_by\n'; sort -t$'\t' -k5,5n -k1,1 -s "$tmp/rows"; } >"$tmp/ledger"
if [ "$dry" -eq 1 ]; then cat "$tmp/ledger"; else mkdir -p "$DATA" && cat "$tmp/ledger" >"$OUT.new" && mv "$OUT.new" "$OUT" || exit 1; fi
echo "release-ledger: $(($(wc -l <"$tmp/ledger") - 1)) row(s) $([ "$dry" -eq 1 ] && echo "would be ")written" >&2
exit 0

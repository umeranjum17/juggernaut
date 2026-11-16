#!/usr/bin/env bash
# jg-ledger-reconcile.sh - replay every release against the outcome ledger and say where the totals differ and why.
#
# Usage: jg-ledger-reconcile.sh [<project>]     writes $DATA/jg-ledger/reconcile.md and prints the same report on stdout
# Exit:  0 every difference has a class; 1 at least one difference is `unexplained` (printed as such, first in the report);
#        2 a source record the ledger needs was missing (named on stderr and in the report); 64 usage.
#
# A release is the commit range between the final head of one trunk branch in data/trunk-releases.tsv and the final head of the
# branch before it (git rev-list <head> ^<previous head>); the first branch's range is its whole history. For each release the report
# shows three totals - git commits, trunk-landing rows, ledger tickets - and puts every commit of the range in exactly one class:
#   landed             a trunk-landings.tsv row (not a revert, not a repeat) names this commit; the row's ticket is its ticket
#   revert             the commit is the revert that a `reverts-<sha12>` landings row records
#   revert-unrecorded  the subject starts `Revert "` (git's own revert form) and no landings row records it: a revert made outside the landing
#   rebased-copy       no row names this sha, but the subject starts with a ticket id that landed under another sha (the lander rebases)
#   merge              a merge commit (a release or lane pull request merge); it carries no ticket of its own
#   pre-ledger         older than the first landings row of the project: history from before the trunk flow kept records
#   unexplained        none of the above. Never folded into another class; the command exits 1.
# Landing-side classes: a landings row for a commit that an earlier row already landed is `duplicate`. A landing whose commit is in no
# release range is `superseded-sha` when a commit of the same ticket is in a release (the lander rebased it), `after-last-release` when
# the commit is newer than the last release head, else `unexplained`. A landed commit that a revert undid counts as landed and is named
# `reverted` in the detail; the ledger still shows its release row, flagged reverted.
# Ledger check: a landed commit of a range must show a released or release-raised row in the ledger (jg-outcome-ledger.sh build), and a
# ledger release row for a commit of the range must come from a landed commit; either gap is `unexplained`.
# Only the report is written; the source records and $JG_HOME/projects are only read.
set -u
export LC_ALL=C
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}}
DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}
LANDINGS=$DATA/trunk-landings.tsv RELEASES=$DATA/trunk-releases.tsv
REPORT=$DATA/jg-ledger/reconcile.md
[ "$#" -le 1 ] || { echo "usage: jg-ledger-reconcile.sh [<project>]" >&2; exit 64; }
ONLY=${1-}
export JG_HOME

tmp=$(mktemp -d) || exit 2
trap 'rm -rf -- "$tmp"' EXIT

ledger_rc=0
"$SCRIPT_DIR/jg-outcome-ledger.sh" build ${ONLY:+"$ONLY"} > "$tmp/ledger.tsv" 2> "$tmp/ledger.err" || ledger_rc=$?
if [ "$ledger_rc" -ne 0 ] && [ "$ledger_rc" -ne 2 ]; then cat "$tmp/ledger.err" >&2; exit "$ledger_rc"; fi
if [ ! -r "$LANDINGS" ] || [ ! -r "$RELEASES" ]; then
  cat "$tmp/ledger.err" >&2
  [ -r "$RELEASES" ] || echo "jg-ledger-reconcile: missing source record: $RELEASES" >&2
  exit 2
fi

: > "$tmp/body"; : > "$tmp/unexplained"
say() { printf '%s\n' "$*" >> "$tmp/body"; }
unexpl() { printf -- '- %s\n' "$*" >> "$tmp/unexplained"; }
# rows_in <ranged-sha-file> <rows-file>: the rows of <rows-file> whose first column is in the range
rows_in() { awk -F'\t' 'NR == FNR { r[$1] = 1; next } $1 in r' "$1" "$2"; }

awk -F'\t' 'NF >= 6 { print $1 }' "$RELEASES" | awk '!s[$0]++' > "$tmp/projects"
while read -r proj; do
  [ -z "$ONLY" ] || [ "$proj" = "$ONLY" ] || continue
  repo=$JG_HOME/projects/$proj
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then unexpl "$proj: no readable clone at $repo, so none of its releases was replayed"; continue; fi
  say "## Project $proj"; say

  # Landing records of this project. The first row of a commit lands it, later rows repeat it, reverts-<sha12> rows are reverts.
  rm -f "$tmp/land" "$tmp/dup" "$tmp/rev"
  awk -F'\t' -v p="$proj" -v o="$tmp" '$2 == p {
      if ($5 ~ /^reverts-/) { print $3 "\t" $1 "\t" substr($5, 9) > (o "/rev"); next }
      if ($3 in seen) { print $3 "\t" $1 > (o "/dup"); next }
      seen[$3] = 1; print $3 "\t" $1 "\t" $4 > (o "/land") }' "$LANDINGS"
  for k in rev dup land; do [ -f "$tmp/$k" ] || : > "$tmp/$k"; done
  first_epoch=$(awk -F'\t' 'NR == 1 || $3 < m { m = $3 } END { print m + 0 }' "$tmp/land")
  awk -F'\t' '{ print $2 }' "$tmp/land" | sort -u > "$tmp/tickets"
  # ledger rows of this project: ticket, commit12, stage, flag
  awk -F'\t' -v p="$proj" '$3 == p { print $2 "\t" $4 "\t" $5 "\t" $8 }' "$tmp/ledger.tsv" > "$tmp/pl"
  awk -F'\t' '{ print substr($3, 1, 12) }' "$tmp/rev" | sort -u > "$tmp/undone12"

  # The releases in order of first appearance, each with the last head recorded for its branch.
  awk -F'\t' -v p="$proj" 'NF >= 6 && $1 == p { if (!($2 in o)) { o[$2] = ++n; ord[n] = $2 } h[$2] = $3 } END { for (i = 1; i <= n; i++) print ord[i] "\t" h[ord[i]] }' "$RELEASES" > "$tmp/rels"
  prev=; last_head=; : > "$tmp/inrange"; : > "$tmp/copied"; : > "$tmp/detail"
  say "| release | git commits | landing rows | ledger tickets | landed | revert | revert-unrecorded | rebased-copy | merge | pre-ledger | duplicate rows | unexplained |"
  say "|---|---|---|---|---|---|---|---|---|---|---|---|"
  while IFS=$'\t' read -r br head; do
    if ! full=$(git -C "$repo" rev-parse -q --verify "$head^{commit}" 2>/dev/null); then
      unexpl "$proj $br: release head $head does not resolve in the clone, so this release was not replayed"; continue
    fi
    git -C "$repo" log --format='%H%x09%P%x09%ct%x09%s' "$full" ${prev:+"^$prev"} > "$tmp/log"
    awk -F'\t' '{ print $1 }' "$tmp/log" >> "$tmp/inrange"
    # one line per commit of the range: sha, class, ticket, subject
    awk -F'\t' -v first="$first_epoch" -v land="$tmp/land" -v rev="$tmp/rev" -v tk="$tmp/tickets" '
      BEGIN { while ((getline l < land) > 0) { split(l, a, "\t"); lt[a[1]] = a[2] }
              while ((getline l < rev) > 0) { split(l, a, "\t"); rv[a[1]] = a[2] }
              while ((getline l < tk) > 0) tick[l] = 1 }
      { sha = $1; n = split($2, par, " "); subj = $4; w = subj; sub(/[: ].*/, "", w); c = "unexplained"; t = "-"
        if (sha in lt) { c = "landed"; t = lt[sha] }
        else if (sha in rv) { c = "revert"; t = rv[sha] }
        else if (subj ~ /^Revert "/) c = "revert-unrecorded"
        else if (w in tick) { c = "rebased-copy"; t = w }
        else if (n > 1) c = "merge"
        else if ($3 + 0 < first) c = "pre-ledger"
        print sha "\t" c "\t" t "\t" subj }' "$tmp/log" > "$tmp/cls"
    total=$(wc -l < "$tmp/cls")
    cnt() { awk -F'\t' -v c="$1" '$2 == c' "$tmp/cls" | wc -l; }
    nl=$(cnt landed); nr=$(cnt revert); nv=$(cnt revert-unrecorded); nb=$(cnt rebased-copy); nm=$(cnt merge); npl=$(cnt pre-ledger); nu=$(cnt unexplained)
    nd=$(rows_in "$tmp/cls" "$tmp/dup" | wc -l)
    rows=$(( $(rows_in "$tmp/cls" "$tmp/land" | wc -l) + $(rows_in "$tmp/cls" "$tmp/rev" | wc -l) + nd ))
    sum=$(( nl + nr + nv + nb + nm + npl + nu ))
    [ "$sum" -eq "$total" ] || unexpl "$proj $br: the classes add to $sum but git shows $total commits"
    while IFS=$'\t' read -r sha _ _ subj; do
      unexpl "$proj $br: commit ${sha:0:12} is in no landing row, no revert, no ticket-named copy, not a merge and not older than the records: $subj"
    done < <(awk -F'\t' '$2 == "unexplained"' "$tmp/cls")
    awk -F'\t' '$2 == "rebased-copy" { print $3 }' "$tmp/cls" >> "$tmp/copied"

    # ledger side: the release rows the ledger shows for this range, against the landed commits of the range
    awk -F'\t' '{ print substr($1, 1, 12) }' "$tmp/cls" | sort -u > "$tmp/range12"
    awk -F'\t' 'NR == FNR { r[$1] = 1; next } ($2 in r) && ($3 == "released" || $3 == "release-raised") { print $1 "\t" $2 }' "$tmp/range12" "$tmp/pl" | sort -u > "$tmp/led"
    awk -F'\t' '$2 == "landed" { print substr($1, 1, 12) }' "$tmp/cls" | sort -u > "$tmp/land12"
    nt=$(awk -F'\t' '{ print $1 }' "$tmp/led" | sort -u | wc -l)
    awk -F'\t' '{ print $2 }' "$tmp/led" | sort -u > "$tmp/led12"
    while read -r c; do unexpl "$proj $br: landed commit $c shows no released or release-raised row in the ledger"; done < <(comm -23 "$tmp/land12" "$tmp/led12")
    while read -r c; do unexpl "$proj $br: the ledger shows a release row for commit $c, which no landing row of this release names"; done < <(comm -13 "$tmp/land12" "$tmp/led12")
    undone=$(comm -12 "$tmp/land12" "$tmp/undone12" | wc -l)

    say "| $br | $total | $rows | $nt | $nl | $nr | $nv | $nb | $nm | $npl | $nd | $nu |"
    {
      printf '### %s\n\n' "$br"
      printf 'Head %s. Git has %s commits, the landing records have %s rows for them, the ledger lists %s tickets with a release row.\n' "\`${full:0:12}\`" "$total" "$rows" "$nt"
      printf 'Commits minus landing rows is %s. Commits with no row of their own: merges (%s), ticket-named copies (%s), unrecorded reverts (%s), pre-ledger (%s). Repeated rows with no commit of their own: %s.\n' \
        "$(( total - rows ))" "$nm" "$nb" "$nv" "$npl" "$nd"
      printf 'Landed commits that a revert undid (counted as landed, ledger flag reverted): %s.\n\n' "$undone"
      printf 'Tickets: '
      awk -F'\t' '$3 != "-" { print $3 }' "$tmp/cls" | sort -u | tr '\n' ' '
      printf '\n\n'
    } >> "$tmp/detail"
    prev=$full; last_head=$full
  done < "$tmp/rels"
  say; cat "$tmp/detail" >> "$tmp/body"

  # landings whose commit is in no release range
  [ -n "$last_head" ] || continue
  sort -u "$tmp/inrange" > "$tmp/inrange.s"; sort -u "$tmp/copied" > "$tmp/copied.s"
  last_ct=$(git -C "$repo" log -1 --format=%ct "$last_head")
  while IFS=$'\t' read -r commit ticket _; do
    grep -qx "$commit" "$tmp/inrange.s" && continue
    if ! ct=$(git -C "$repo" log -1 --format=%ct "$commit" 2>/dev/null) || [ -z "$ct" ]; then
      unexpl "$proj: landing $ticket names commit ${commit:0:12}, which the clone does not have"
    elif grep -qx "$ticket" "$tmp/copied.s"; then say "- superseded-sha: ticket $ticket landed as ${commit:0:12}; a rebased copy of it is in a release"
    elif [ "$ct" -gt "$last_ct" ]; then say "- after-last-release: ticket $ticket, commit ${commit:0:12}"
    else unexpl "$proj: landing $ticket commit ${commit:0:12} is older than the last release head but in no release range and has no copy in one"
    fi
  done < "$tmp/land"
  say
done < "$tmp/projects"

{
  printf '# Ledger reconcile\n\n'
  printf 'Replay of the releases in data/trunk-releases.tsv against the outcome ledger (bin/jg-outcome-ledger.sh build). The class meanings are in the header of bin/jg-ledger-reconcile.sh.\n\n'
  if [ -s "$tmp/unexplained" ]; then
    printf '## Unexplained differences (%s)\n\n' "$(wc -l < "$tmp/unexplained")"; cat "$tmp/unexplained"; printf '\n'
  else
    printf '## Unexplained differences\n\nnone: every difference has a class.\n\n'
  fi
  [ ! -s "$tmp/ledger.err" ] || { printf '## Source records the ledger could not read\n\n'; sed 's/^/- /' "$tmp/ledger.err"; printf '\n'; }
  cat "$tmp/body"
} > "$tmp/report"
if ! { mkdir -p "$(dirname "$REPORT")" && cp "$tmp/report" "$REPORT.new" && mv "$REPORT.new" "$REPORT"; }; then
  echo "jg-ledger-reconcile: cannot write $REPORT" >&2; exit 2
fi
cat "$tmp/report"
[ ! -s "$tmp/unexplained" ] || exit 1
[ "$ledger_rc" -eq 0 ] || exit 2
exit 0

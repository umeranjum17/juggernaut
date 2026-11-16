#!/usr/bin/env bash
# jg-outcome-ledger.sh - the outcome ledger: one dated row per ticket and stage, rebuilt from the records this home already keeps.
#
# Usage: jg-outcome-ledger.sh build [<project>]         print the ledger on stdout (tab separated, sorted, no header comments)
#        jg-outcome-ledger.sh columns                   print the column names
#        jg-outcome-ledger.sh publications [<project>]  print one timing row per release publication (columns below)
# Nothing is written: the ledger is a pure read of the sources, so a rerun on the same sources prints the same rows.
#
# Columns: date (UTC day), ticket, project, commit (12), stage, proof, bypass, flag, owner.
# Stages, each shown only by the record named here (a stage no record shows is never inferred):
#   built         data/trunk-landing-proofs.tsv row (the proof the lane carried to its landing)
#   landed        data/trunk-landings.tsv row
#   in-use        data/trunk-in-use.tsv row whose status is `live` or `live,...`, at a commit that contains the landed commit (git ancestry)
#   release-raised  data/trunk-releases.tsv row whose head contains the commit: a release pull request was raised; nothing here says it merged
#   released      the release above, once data/trunk-versions.tsv shows the project rolled over to a later trunk branch (the old release merged);
#                 the date is the rollover's
#   reverted      a trunk-landings.tsv row whose gate is `reverts-<sha12>`; the row of the reverted commit, dated by the revert
# proof: `receipt`, `merge-card`, `signature` joined by `+` for what the proofs row records as present, `bypass` when a genuine bypass
#   record stands in the place of a receipt, `none-recorded` when no proofs row names that landing.
# bypass: `bypass` when state/<task>.bypass-record.json names the commit and the owner's bypass row holds; `bypass-unverified` when the
#   record exists but does not hold; `-` otherwise.
# flag: `-` for a normal row. `duplicate` marks a landings row for a commit an earlier row already landed: it is never counted as a
#   second landing and has no later stage. `revert:<sha12>` marks the revert row; `reverted` marks every row of a commit that a revert
#   undid, so a count of rows with flag `-` holds no reverted or duplicate change. The revert commit itself is no landing.
#   `revert-target-unrecorded` marks a revert whose original commit has no landings row (ticket `unknown`).
#
# owner: who had to act for the ticket, from recorded words and waivers only, never guessed. First that holds wins:
#   bypass          the bypass column says bypass (a record the owner's bypass row backs)
#   captain-word    a `word` answer at gated (data/trunk-gated.tsv row of the ticket), or a captain word (data/trunk-words.tsv, kind in-use or
#                   release) whose commit contains the landing
#   standing-waiver a `yolo` answer at gated (data/trunk-gated.tsv row of the ticket)
#   none            the landing has a proofs row (so its record is whole) and no word, waiver or bypass names it
#   unknown         no record names the ticket at all; a duplicate, a revert and a later stage of a flagged row print `-`
#
# publications: one row per publication, from data/trunk-publications.tsv (written by jg-trunk.sh when a batch is pushed) joined to the
# release row and the rollover that shows it merged. Columns: project, commit (12), path, due, attempt, open, merged (UTC, `-` when no
# record shows it), minutes-due-to-merge (`-` when either end is not recorded). path is `automatic` (the tick's publish) or `fallback`
# (a release run by hand on the captain's word); a release with no publications row (older than the writer) reads `unknown`, and its
# attempt is the release row's time. Open is `-` when the push went into a pull request already open. Merged is the rollover's time.
#
# Sources and where they sit: $DATA = ${JG_DATA_OVERRIDE:-$JG_HOME/data}, $STATE = ${JG_STATE_OVERRIDE:-$JG_HOME/state}, the project clone
# is $JG_HOME/projects/<project>. A source file that is absent is named on stderr as `missing source record: <path>` and the command
# exits 2 after it printed what the other records show; a clone git cannot read, or a commit it cannot resolve, is named the same way.
# Needs git and jq. Exit: 0 clean, 2 a source record was missing or unreadable, 64 usage.
set -u
export LC_ALL=C
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}}
DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
# shellcheck source=bin/jg-bypass-record-lib.sh
. "$SCRIPT_DIR/jg-bypass-record-lib.sh"

COLUMNS_LINE=$'date\tticket\tproject\tcommit\tstage\tproof\tbypass\tflag\towner'
missing=0
miss() { printf 'jg-outcome-ledger: missing source record: %s\n' "$1" >&2; missing=1; }

case ${1-} in
  columns) printf '%s\n' "$COLUMNS_LINE"; exit 0 ;;
  build|publications) MODE=$1; shift ;;
  *) echo "usage: jg-outcome-ledger.sh build [<project>] | columns | publications [<project>]" >&2; exit 64 ;;
esac
ONLY=${1-}
if ! command -v git >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then echo 'jg-outcome-ledger: needs git and jq' >&2; exit 2; fi

LANDINGS=$DATA/trunk-landings.tsv PROOFS=$DATA/trunk-landing-proofs.tsv
INUSE=$DATA/trunk-in-use.tsv RELEASES=$DATA/trunk-releases.tsv VERSIONS=$DATA/trunk-versions.tsv
GATED=$DATA/trunk-gated.tsv WORDS=$DATA/trunk-words.tsv PUBLICATIONS=$DATA/trunk-publications.tsv
# trunk-gated.tsv and trunk-words.tsv are optional: a home with neither has no word or waiver to show, so every owner reads from what is left.
if [ "$MODE" = publications ]; then needed=("$RELEASES" "$VERSIONS" "$PUBLICATIONS"); else needed=("$LANDINGS" "$PROOFS" "$INUSE" "$RELEASES" "$VERSIONS"); fi
for f in "${needed[@]}"; do [ -r "$f" ] || miss "$f"; done
[ -d "$STATE" ] || miss "$STATE"
if [ "$MODE" = publications ]; then
  # Per release row (project, trunk, commit, n, epoch, url): the publications row of the same commit and url, and the first later versions
  # row on another trunk branch, which is the rollover that shows the release merged.
  [ -r "$RELEASES" ] || exit 2
  awk -F'\t' -v only="$ONLY" -v OFS='\t' '
    function ts(e) { if (e == "" || e == "-") return "-"; cmd = "date -u -d @" e " +%Y-%m-%dT%H:%M:%SZ"; cmd | getline v; close(cmd); return v }
    FILENAME == ARGV[1] { if (NF >= 8) pub[$1 SUBSEP $3 SUBSEP $8] = $7 OFS $4 OFS $5 OFS $6; next }
    FILENAME == ARGV[2] { n = ++nv; vp[n] = $1; vb[n] = $3; ve[n] = $5; next }
    NF >= 6 && (only == "" || $1 == only) {
      k = $1 SUBSEP $3 SUBSEP $6; path = "unknown"; due = "-"; att = $5; opn = "-"
      if (k in pub) { split(pub[k], f, OFS); path = f[1]; due = f[2]; att = f[3]; opn = f[4] }
      mer = "-"
      for (i = 1; i <= nv; i++) if (vp[i] == $1 && vb[i] != $2 && ve[i] + 0 > att + 0 && (mer == "-" || ve[i] + 0 < mer + 0)) mer = ve[i]
      mins = (due != "-" && mer != "-") ? int((mer - due) / 60) : "-"
      print $1, substr($3, 1, 12), path, ts(due), ts(att), ts(opn), ts(mer), mins
    }' "$PUBLICATIONS" "$VERSIONS" "$RELEASES" 2>/dev/null
  [ "$missing" = 0 ] || exit 2
  exit 0
fi
[ -r "$LANDINGS" ] || exit 2   # without its landings the ledger has nothing to stand on

tmp=$(mktemp -d) || exit 2
trap 'rm -rf -- "$tmp"' EXIT

# cover <project> <epoch-commit-file>: for each commit that a listed commit contains, the earliest epoch (commit<TAB>epoch). Input rows
# are `epoch<TAB>commit`; a commit git cannot resolve is named and covers nothing.
cover() {
  local proj=$1 repo=$JG_HOME/projects/$1 e c
  while IFS=$'\t' read -r e c; do
    [ -n "$c" ] || continue
    if git -C "$repo" rev-list "$c" 2>/dev/null | awk -v e="$e" '{ print $1 "\t" e }'; then :; fi
    git -C "$repo" cat-file -e "$c^{commit}" 2>/dev/null || printf 'jg-outcome-ledger: cannot resolve %s in project %s\n' "$c" "$proj" >&2
  done | sort -k1,1 -k2,2n | awk -F'\t' '!s[$1]++'
}

: > "$tmp/rows"   # epoch<TAB>rank<TAB>ticket<TAB>project<TAB>commit12<TAB>stage<TAB>proof<TAB>bypass<TAB>flag
projects=$(awk -F'\t' '{ print $2 }' "$LANDINGS" | sort -u)
for proj in $projects; do
  [ -z "$ONLY" ] || [ "$proj" = "$ONLY" ] || continue
  repo=$JG_HOME/projects/$proj
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then miss "$repo (no readable clone of $proj)"; continue; fi

  # Landings in file order. A commit seen before is a duplicate; a reverts-<sha12> row is the revert of an earlier commit.
  awk -F'\t' -v p="$proj" -v out="$tmp" '
    $2 != p { next }
    $5 ~ /^reverts-/ { sub(/^reverts-/, "", $5); print $1 "\t" $3 "\t" $4 "\t" $5 > (out "/rev." p); next }
    ($3 in seen) { print $1 "\t" $3 "\t" $4 > (out "/dup." p); next }
    { seen[$3] = 1; print $1 "\t" $3 "\t" $4 > (out "/land." p) }
  ' "$LANDINGS"
  for k in rev dup land; do [ -f "$tmp/$k.$proj" ] || : > "$tmp/$k.$proj"; done
  # reverted: the 12-character prefix -> the revert's epoch and commit
  awk -F'\t' '{ print substr($4, 1, 12) "\t" $3 "\t" substr($2, 1, 12) }' "$tmp/rev.$proj" > "$tmp/revmap.$proj"

  # proofs by task+commit
  awk -F'\t' -v p="$proj" '$2 == p { r = ""; for (i = 5; i <= NF; i++) {
      if ($i == "receipt=absent" || $i == "signature=absent" || $i == "merge-card=absent") continue
      if ($i ~ /^receipt=PASS/) r = r "+receipt"; else if ($i == "signature=present") r = r "+signature"; else if ($i == "merge-card=present") r = r "+merge-card" }
      sub(/^\+/, "", r); print $1 "\t" $3 "\t" $4 "\t" (r == "" ? "none-recorded" : r) }' "$PROOFS" 2>/dev/null > "$tmp/proofs.$proj"

  # owner involvement: the answer given at gated per ticket, and the captain words with the commits they cover by ancestry
  awk -F'\t' -v p="$proj" '$1 == p { print $4 "\t" $5 }' "$GATED" 2>/dev/null > "$tmp/gated.$proj"
  awk -F'\t' -v p="$proj" '$1 == p && ($2 == "in-use" || $2 == "release" || $2 == "live") { print $4 "\t" $3 }' "$WORDS" 2>/dev/null | sort -k1,1n | cover "$proj" > "$tmp/words.$proj"

  # in use and released coverage by ancestry
  awk -F'\t' -v p="$proj" '$1 == p && $4 ~ /^live(,|$)/ { print $3 "\t" $2 }' "$INUSE" 2>/dev/null | sort -k1,1n | cover "$proj" > "$tmp/inuse.$proj"
  awk -F'\t' -v p="$proj" 'NF >= 6 && $1 == p { print $5 "\t" $3 }' "$RELEASES" 2>/dev/null | sort -k1,1n | cover "$proj" > "$tmp/rel.$proj"
  # the rollover that proves a release merged: the first later versions row on another trunk branch than the release row's
  awk -F'\t' -v p="$proj" 'NF >= 6 && $1 == p { print $2 "\t" $5 "\t" $3 }' "$RELEASES" 2>/dev/null > "$tmp/relrows.$proj"
  awk -F'\t' -v p="$proj" '$1 == p { print $3 "\t" $5 }' "$VERSIONS" 2>/dev/null | sort -k2,2n > "$tmp/ver.$proj"
  # per release row: confirm date (rollover epoch) or none; written as `head-epoch<TAB>confirm-epoch`
  while IFS=$'\t' read -r br ep _; do
    conf=$(awk -F'\t' -v br="$br" -v ep="$ep" '$1 != br && $2 > ep { print $2; exit }' "$tmp/ver.$proj")
    printf '%s\t%s\n' "$ep" "${conf:--}"
  done < "$tmp/relrows.$proj" | sort -u > "$tmp/relconf.$proj"

  while IFS=$'\t' read -r task commit epoch; do
    c12=${commit:0:12}
    flag=-; [ -z "$(awk -F'\t' -v c="$c12" '$1 == c { print 1 }' "$tmp/revmap.$proj")" ] || flag=reverted
    proof=$(awk -F'\t' -v t="$task" -v c="$commit" '$1 == t && $2 == c { print $4; exit }' "$tmp/proofs.$proj")
    pepoch=$(awk -F'\t' -v t="$task" -v c="$commit" '$1 == t && $2 == c { print $3; exit }' "$tmp/proofs.$proj")
    bypass=-
    if [ -f "$(jg_bypass_record_file "$STATE" "$task")" ] && jq -e --arg c "$commit" '.commit == $c' "$(jg_bypass_record_file "$STATE" "$task")" >/dev/null 2>&1; then
      if jg_bypass_record_holds "$JG_HOME" "$STATE" "$task" "$commit"; then bypass=bypass; proof=bypass; else bypass='bypass-unverified'; fi
    fi
    [ -n "$proof" ] || proof=none-recorded
    answer=$(awk -F'\t' -v t="$task" '$1 == t { a = (a == "word" || $2 == "word") ? "word" : $2 } END { print a }' "$tmp/gated.$proj")
    if [ "$bypass" = bypass ]; then owner=bypass
    elif [ "$answer" = word ] || [ -n "$(awk -F'\t' -v c="$commit" '$1 == c { print 1 }' "$tmp/words.$proj")" ]; then owner=captain-word
    elif [ "$answer" = yolo ]; then owner=standing-waiver
    elif [ -n "$pepoch" ]; then owner=none
    else owner=unknown; fi
    if [ -n "$pepoch" ] || [ "$bypass" = bypass ]; then
      printf '%s\t1\t%s\t%s\t%s\tbuilt\t%s\t%s\t%s\t%s\n' "${pepoch:-$epoch}" "$task" "$proj" "$c12" "$proof" "$bypass" "$flag" "$owner" >> "$tmp/rows"
    fi
    printf '%s\t2\t%s\t%s\t%s\tlanded\t%s\t%s\t%s\t%s\n' "$epoch" "$task" "$proj" "$c12" "$proof" "$bypass" "$flag" "$owner" >> "$tmp/rows"
    u=$(awk -F'\t' -v c="$commit" '$1 == c { print $2 }' "$tmp/inuse.$proj")
    [ -z "$u" ] || printf '%s\t3\t%s\t%s\t%s\tin-use\t%s\t%s\t%s\t%s\n' "$u" "$task" "$proj" "$c12" "$proof" "$bypass" "$flag" "$owner" >> "$tmp/rows"
    r=$(awk -F'\t' -v c="$commit" '$1 == c { print $2 }' "$tmp/rel.$proj")
    if [ -n "$r" ]; then
      conf=$(awk -F'\t' -v e="$r" '$1 == e { print $2; exit }' "$tmp/relconf.$proj")
      if [ -n "$conf" ] && [ "$conf" != - ]; then
        printf '%s\t4\t%s\t%s\t%s\treleased\t%s\t%s\t%s\t%s\n' "$conf" "$task" "$proj" "$c12" "$proof" "$bypass" "$flag" "$owner" >> "$tmp/rows"
      else
        printf '%s\t4\t%s\t%s\t%s\trelease-raised\t%s\t%s\t%s\t%s\n' "$r" "$task" "$proj" "$c12" "$proof" "$bypass" "$flag" "$owner" >> "$tmp/rows"
      fi
    fi
  done < "$tmp/land.$proj"

  # duplicates: the landed row only, marked, with nothing after it
  while IFS=$'\t' read -r task commit epoch; do
    printf '%s\t2\t%s\t%s\t%s\tlanded\t%s\t-\tduplicate\t-\n' "$epoch" "$task" "$proj" "${commit:0:12}" none-recorded >> "$tmp/rows"
  done < "$tmp/dup.$proj"

  # reverts: the row of the reverted commit; the revert commit is never a landing
  while IFS=$'\t' read -r p12 repoch rcommit; do
    orig=$(awk -F'\t' -v p="$p12" 'substr($2, 1, 12) == p { print $1 "\t" substr($2, 1, 12); exit }' "$tmp/land.$proj")
    if [ -n "$orig" ]; then
      printf '%s\t5\t%s\t%s\t%s\treverted\t-\t-\trevert:%s\t-\n' "$repoch" "${orig%%$'\t'*}" "$proj" "${orig##*$'\t'}" "$rcommit" >> "$tmp/rows"
    else
      printf '%s\t5\tunknown\t%s\t%s\treverted\t-\t-\trevert-target-unrecorded\t-\n' "$repoch" "$proj" "$p12" >> "$tmp/rows"
    fi
  done < "$tmp/revmap.$proj"
done

sort -t$'\t' -k1,1n -k2,2n -k3,3 -k5,5 -k9,9 "$tmp/rows" | awk -F'\t' -v OFS='\t' '
  { cmd = "date -u -d @" $1 " +%Y-%m-%d"; if (!($1 in day)) { cmd | getline day[$1]; close(cmd) }
    print day[$1], $3, $4, $5, $6, $7, $8, $9, $10 }'
[ "$missing" = 0 ] || exit 2
exit 0

#!/usr/bin/env bash
# jg-migration-card.sh - keep the migration card current from the merge path.
#
# Usage: jg-migration-card.sh merge <pr-url> | milestone <kind> [text]
#
# Opt-in through config/migration-card (key=value lines): branch (the release
# branch watched), target (lines to delete), board (sign-off board.json, else
# $JG_PROOF_BOARD), card (the key of the card already posted), baseline-deleted
# and baseline-added (totals before the first recorded merge), filer.
# bin/jg-merge-outcome-lib.sh calls `merge` after every confirmed merge.
#
# merge  A PR whose base is the watched branch is added once to the ledger
#        (data/migration-card/ledger.tsv: url, deleted, added, title). The card
#        then shows the step, the lines removed and added, the running total
#        against the target and what is left. A report key cannot be re-posted
#        with a changed message and dismiss does not free a key, so every
#        update posts a fresh key (<card>-<n>) and dismisses the previous card.
#        The view page is <board folder>/reports/<key>/index.html, written
#        with the board's own forms: system colours, no cards, short text
#        blocks, a viewport tag, a dark-mode block, one picture, one tap-through
#        element and a details block.
# milestone  A switch live, a Go port done, each 5,000 deleted lines and the
#        release pull request ready record a captain outcome of three lines
#        (done / left / release blockers) plus the card link. `merge` finds the
#        first three by the PR title and the line count; the release pull
#        request is `milestone release-ready "<blockers>"`.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$SCRIPT_DIR/..}}"
CFG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}/migration-card"
DIR="${JG_DATA_OVERRIDE:-$JG_HOME/data}/migration-card"
LEDGER=$DIR/ledger.tsv
die() { echo "jg-migration-card: $*" >&2; exit 1; }
cfg() { sed -n "s/^$1=//p" "$CFG" 2>/dev/null | tail -n 1; }
fmt() { printf '%s' "$1" | sed ':a;s/\([0-9]\)\([0-9]\{3\}\)\($\|,\)/\1,\2\3/;ta'; }
# shellcheck source=bin/jg-board-link-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/jg-board-link-lib.sh"

[ -r "$CFG" ] || exit 0
BRANCH=$(cfg branch) TARGET=$(cfg target) BOARD=$(cfg board) CARD=$(cfg card) FILER=$(cfg filer)
BOARD=${BOARD:-${JG_PROOF_BOARD:-}}
[ -n "$BRANCH" ] && [ -n "$TARGET" ] && [ -d "$(dirname "${BOARD:-/nonexistent}")" ] || die "config/migration-card needs branch, target and a board file in an existing folder"
mkdir -p "$DIR"

# Totals: baseline plus every ledger row (deleted added).
totals() { awk -F'\t' -v d="$(cfg baseline-deleted)" -v a="$(cfg baseline-added)" \
  '{d+=$2;a+=$3} END{print d+0, a+0, NR}' "$LEDGER" 2>/dev/null || echo "0 0 0"; }

# The page: progress picture, tap through the latest changes, the rest in details.
write_page() {  # <dir> <del> <add> <step> <n>
  local dir=$1 del=$2 add=$3 pct left rows
  pct=$((del * 100 / TARGET)); [ "$pct" -le 100 ] || pct=100; left=$((TARGET - del)); [ "$left" -ge 0 ] || left=0
  rows=$(tail -n 8 "$LEDGER" | jq -R -s -c 'split("\n")[:-1]|map(split("\t")|"\(.[3]) (-\(.[1]) +\(.[2]))")')
  mkdir -p "$dir"
  printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 40" width="400" height="40"><rect width="400" height="40" fill="none" stroke="GrayText"/><rect width="%s" height="40" fill="GrayText"/></svg>\n' "$((pct * 4))" > "$dir/preview.svg"
  cat > "$dir/index.html" <<HTML
<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width, initial-scale=1"><title>Migration: where it stands</title>
<style>:root{color-scheme:light dark}body{background:Canvas;color:CanvasText;font:16px/1.5 system-ui,sans-serif;margin:0 auto;padding:24px;max-width:700px}
.sub,summary{color:GrayText}button{background:Canvas;color:CanvasText;border:1px solid GrayText;padding:8px 16px}svg{max-width:100%;height:auto}
@media (prefers-color-scheme:dark){:root{color-scheme:dark light}body{background:Canvas;color:CanvasText}}</style>
<h1>Migration: $(fmt "$del") of $(fmt "$TARGET") lines deleted</h1>
<p>$(fmt "$left") lines are left to delete. $(fmt "$5") merges are recorded on this card since the baseline.</p>
$(cat "$dir/preview.svg")
<p class=sub>Latest change: $(printf '%s' "$4" | cut -c1-150). It removed and added the lines shown under Tap through.</p>
<p id=t></p><button id=b>Next change</button>
<details><summary>Details</summary><p>Added in total: $(fmt "$add") lines. Net change: $(fmt "$((add - del))") lines.</p>
<p>Each merge into $BRANCH adds its own removed and added lines to the running total.</p></details>
<script>var R=$rows,i=0,t=document.getElementById('t');function d(){t.textContent=(i+1)+' of '+R.length+': '+R[i]}
document.getElementById('b').onclick=function(){i=(i+1)%R.length;d()};d()</script>
HTML
}

milestone() {  # <kind> <done> <left> <blockers> <card-key>
  local link summary
  link=$(jg_board_link reports "$5" 2>/dev/null) || link="card $5"
  summary=$(printf 'Migration milestone: %s\nDone: %s\nLeft: %s\nRelease blockers: %s\nCard: %s' "$1" "$2" "$3" "$4" "$link")
  "$SCRIPT_DIR/jg-branch-outcome.sh" append --task migration-card --verdict captain --summary "$summary" >/dev/null \
    || echo "jg-migration-card: captain outcome not recorded" >&2
}

post_card() {  # <step> <pr-url> <kind>; posts the next card and records the milestone
  local n del add rows key prev title
  read -r del add n <<<"$(totals)"
  key="${CARD%-[0-9]*}-$n"; prev=$CARD
  [ -n "$prev" ] || prev=${key%-*}
  write_page "$(dirname "$BOARD")/reports/$key" "$del" "$add" "$1" "$n"
  title="Migration: $(fmt "$del") of $(fmt "$TARGET") lines deleted, $(fmt "$((TARGET - del))") left"
  sign-off-axi post "$BOARD" --type report --purpose status --project "$(cfg project)" --key "$key" --title "$title" \
    --about "Latest: $(printf '%s' "$1" | cut -c1-120). Total deleted $(fmt "$del"), added $(fmt "$add")." \
    --view "reports/$key/index.html" --preview "reports/$key/preview.svg" --link "$2" \
    --filer "${FILER:-migration-card}" >/dev/null || die "card post refused for $key"
  sign-off-axi dismiss "$prev" "$BOARD" --reason replaced >/dev/null 2>&1 || echo "jg-migration-card: could not dismiss $prev" >&2
  CARD=$key; printf 'card=%s\n' "$key" > "$DIR/current"
  sed -i '/^card=/d' "$CFG"; printf 'card=%s\n' "$key" >> "$CFG"
  [ -z "${3-}" ] || milestone "$3" "$(fmt "$del") of $(fmt "$TARGET") lines deleted; last change: $1" \
    "$(fmt "$((TARGET - del))") lines" "${4:-none recorded}" "$key"
  printf '%s\n' "$key"
}

case "${1-}" in
  merge)
    URL=${2-}; [ -n "$URL" ] || die "merge needs a pull request URL"
    grep -qF "$URL	" "$LEDGER" 2>/dev/null && exit 0
    info=$(gh pr view "$URL" --json baseRefName,title,additions,deletions) || die "cannot read $URL"
    [ "$(jq -r .baseRefName <<<"$info")" = "$BRANCH" ] || exit 0
    read -r before _ _ <<<"$(totals)"
    title=$(jq -r '.title|gsub("[\t\n]";" ")' <<<"$info")
    printf '%s\t%s\t%s\t%s\n' "$URL" "$(jq .deletions <<<"$info")" "$(jq .additions <<<"$info")" "$title" >> "$LEDGER"
    read -r after _ _ <<<"$(totals)"
    kind=''
    if grep -qiE 'switch.*(live|on)|live.*switch' <<<"$title"; then kind='a switch is live'
    elif grep -qiE 'go port.*(done|complete|landed)' <<<"$title"; then kind='a Go port is done'
    elif [ $((after / 5000)) -gt $((before / 5000)) ]; then kind="$((after / 5000 * 5000)) lines deleted"; fi
    post_card "$title" "$URL" "$kind" ;;
  milestone)
    [ -n "${2-}" ] || die "milestone needs a kind"
    read -r del _ n <<<"$(totals)"
    milestone "$2" "$(fmt "$del") of $(fmt "$TARGET") lines deleted" "$(fmt "$((TARGET - del))") lines" "${3:-none recorded}" "${CARD:-}" ;;
  *) die "usage: jg-migration-card.sh merge <pr-url> | milestone <kind> [blockers]" ;;
esac

#!/usr/bin/env bash
# jg-migration-card.sh - keep the migration card current from the merge path.
#
# Usage: jg-migration-card.sh merge <pr-url> | milestone <kind> [text]
#        jg-migration-card.sh live [--quiet] | arm | disarm
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
# live   Probe every part of the stack on this machine with
#        bin/jg-migration-live.sh and post the card again, so the page answers
#        "what is live now and what is pending" from measurement: runs here,
#        pending, or not installed, with the pid, port, real message or traffic
#        count behind it. Every card post probes first, so a merge card is
#        current too. `live --quiet` is the cadence form: it refreshes the
#        posted card's page in place, posts a fresh card only when a part
#        changed, and prints nothing, so the watcher spends no wake and no model
#        turn on it. `arm` writes state/migration-card.check.sh, binds it with
#        jg-check-register.sh and runs one pass; `disarm` removes them.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$SCRIPT_DIR/..}}"
CFG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}/migration-card"
DIR="${JG_DATA_OVERRIDE:-$JG_HOME/data}/migration-card"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
SHIM="$STATE/migration-card.check.sh"
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
mkdir -p "$DIR" && touch "$LEDGER"

# Totals: baseline plus every ledger row (deleted added).
totals() { awk -F'\t' -v d="$(cfg baseline-deleted)" -v a="$(cfg baseline-added)" \
  '{d+=$2;a+=$3} END{print d+0, a+0, NR}' "$LEDGER" 2>/dev/null || echo "0 0 0"; }

# live_rows: the probed parts as table rows, in the words a reader needs.
live_rows() {
  local part state detail word
  [ -r "$DIR/live.tsv" ] || { printf '<tr><td colspan=3>No part is probed yet. Run bin/jg-migration-card.sh live.</td></tr>\n'; return 0; }
  while IFS=$'\t' read -r part state detail; do
    case $state in live) word='runs here' ;; pending) word='pending' ;; *) word='not installed' ;; esac
    printf '<tr><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$part" "$word" "$detail"
  done < "$DIR/live.tsv"
}

# probed_at: when the parts were last measured, or a plain line when never.
probed_at() {
  local at
  at=$(cat "$DIR/live.at" 2>/dev/null)
  [ -n "$at" ] && date -u -d "@$at" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || printf 'never'
}

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
table{border-collapse:collapse}td,th{text-align:left;padding:2px 10px 2px 0;vertical-align:top;border-bottom:1px solid GrayText}
@media (prefers-color-scheme:dark){:root{color-scheme:dark light}body{background:Canvas;color:CanvasText}}</style>
<h1>Migration: $(fmt "$del") of $(fmt "$TARGET") lines deleted</h1>
<p>$(fmt "$left") lines are left to delete. $(fmt "$5") merges are recorded on this card since the baseline.</p>
$(cat "$dir/preview.svg")
<h2>What runs on this machine</h2>
<p class=sub>Each line is a probe of this machine, last run $(probed_at).</p>
<table><tr><th>Part</th><th>State</th><th>Measured</th></tr>
$(live_rows)
</table>
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
  summary=$(printf 'Done (%s): %s\nLeft: %s\nRelease blockers: %s. Card: %s' "$1" "$2" "$3" "$4" "$link")
  "$SCRIPT_DIR/jg-branch-outcome.sh" append --task migration-card --verdict captain --summary "$summary" >/dev/null \
    || echo "jg-migration-card: captain outcome not recorded" >&2
}

post_card() {  # <step> <pr-url> <kind>; posts the next card and records the milestone
  local n del add rows key prev rev title link=()
  [ -z "${2-}" ] || link=(--link "$2")
  "$SCRIPT_DIR/jg-migration-live.sh" --quiet >/dev/null 2>&1 \
    || echo "jg-migration-card: the live probe could not run" >&2
  read -r del add n <<<"$(totals)"
  key="${CARD%-[0-9]*}-$n"; prev=$CARD
  if [ -e "$(dirname "$BOARD")/reports/$key" ]; then
    # A key cannot be re-posted with a changed message, and a live probe that
    # finds one part changed adds no merge, so that key would repeat.
    rev=$(( $(cat "$DIR/rev" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$rev" > "$DIR/rev"
    key="$key-$rev"
  fi
  [ -n "$prev" ] || prev=${key%-*}
  write_page "$(dirname "$BOARD")/reports/$key" "$del" "$add" "$1" "$n"
  title="Migration: $(fmt "$del") of $(fmt "$TARGET") lines deleted, $(fmt "$((TARGET - del))") left"
  sign-off-axi post "$BOARD" --type report --purpose status --project "$(cfg project)" --key "$key" --title "$title" \
    --about "Latest: $(printf '%s' "$1" | cut -c1-120). Total deleted $(fmt "$del"), added $(fmt "$add")." \
    --view "reports/$key/index.html" --preview "reports/$key/preview.svg" ${link[@]+"${link[@]}"} \
    --filer "${FILER:-migration-card}" >/dev/null || die "card post refused for $key"
  sign-off-axi dismiss "$prev" "$BOARD" --reason replaced >/dev/null 2>&1 || echo "jg-migration-card: could not dismiss $prev" >&2
  CARD=$key; printf 'card=%s\n' "$key" > "$DIR/current"
  sed -i '/^card=/d' "$CFG"; printf 'card=%s\n' "$key" >> "$CFG"
  [ -z "${3-}" ] || milestone "$3" "$(fmt "$del") of $(fmt "$TARGET") lines deleted; last change: $1" \
    "$(fmt "$((TARGET - del))") lines" "${4:-none recorded}" "$key"
  printf '%s\n' "$key"
}

# cmd_live [--quiet]: measure every part again, then put the result in front of
# the captain. On demand it posts a fresh card and says which key it posted. The
# cadence form (--quiet) refreshes the posted card's own page in place and posts
# only when a part changed, so a part going live reaches the board without a wake.
cmd_live() {
  local quiet=${1-} before after changed=0 key del add n
  before=$(cat "$DIR/live.tsv" 2>/dev/null)
  "$SCRIPT_DIR/jg-migration-live.sh" --quiet >/dev/null 2>&1 \
    || die "the live probe could not run"
  after=$(cat "$DIR/live.tsv" 2>/dev/null)
  [ "$before" = "$after" ] || changed=1
  if [ "$quiet" != --quiet ]; then
    post_card "every part of the stack was probed on this machine" "" ""
    return 0
  fi
  key=$(cfg card)
  [ -n "$key" ] || key=$(cat "$DIR/current" 2>/dev/null)
  if [ -n "$key" ]; then
    read -r del add n <<<"$(totals)"
    write_page "$(dirname "$BOARD")/reports/$key" "$del" "$add" "every part of the stack was probed again" "$n"
  fi
  [ "$changed" -eq 0 ] || post_card "a part of the stack changed state" "" "" >/dev/null
  return 0
}

# cmd_arm: run the probe from the watcher's own check slot, every cycle it is due.
cmd_arm() {
  local tmp
  tmp=$(umask 077; mktemp "$STATE/.jg-migration-card.XXXXXX") || die "cannot write the check shim"
  { printf '#!/usr/bin/env bash\nexport JG_HOME=%q JG_CONFIG_OVERRIDE=%q JG_DATA_OVERRIDE=%q JG_STATE_OVERRIDE=%q\nexec %q live --quiet\n' \
      "$JG_HOME" "${CFG%/migration-card}" "${DIR%/migration-card}" "$STATE" "$SCRIPT_DIR/jg-migration-card.sh" > "$tmp" \
    && chmod 0700 "$tmp" && mv -f -- "$tmp" "$SHIM"; } || { rm -f -- "$tmp"; die "cannot write the check shim"; }
  JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-check-register.sh" migration-card || die "cannot register the check"
  cmd_live --quiet
  printf 'armed: migration-card\n'
}

cmd_disarm() {
  rm -f -- "$SHIM" "$STATE/migration-card.check-trust"
  printf 'disarmed: migration-card\n'
}

case "${1-}" in
  live)
    shift
    cmd_live "${1-}" ;;
  arm) cmd_arm ;;
  disarm) cmd_disarm ;;
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
  *) die "usage: jg-migration-card.sh merge <pr-url> | milestone <kind> [blockers] | live [--quiet] | arm | disarm" ;;
esac

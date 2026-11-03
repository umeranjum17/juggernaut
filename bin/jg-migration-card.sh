#!/usr/bin/env bash
# jg-migration-card.sh - keep the migration card current from the merge path.
#
# Usage: jg-migration-card.sh merge <pr-url> | milestone <kind> [text]
#        jg-migration-card.sh live [--quiet] | arm | disarm
#
# Opt-in through config/migration-card (key=value lines): branch (the release
# branch watched), target (lines to delete), baseline-ref (the git ref the line
# count is taken from), push-hours (hours of quiet before the daily line, default 24), board (sign-off board.json, else
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
# milestone  A switch live (with `critical=` set in config/migration-card, only a live
#        row counts, see bin/jg-critical-path.sh; its Live line leads the outcome and the
#        Done text reads "merged, not a live measure"), a Go port done, each 5,000 deleted lines and the
#        release pull request ready record a captain outcome of three lines
#        (done / left / release blockers) plus the card link. `merge` finds the
#        first three by the PR title and the line count; the release pull
#        request is `milestone release-ready "<blockers>"`.
# live   Probe every part of the stack on this machine with
#        bin/jg-migration-live.sh and post the card again, so the page answers
#        "what is live now and what is pending" from measurement: runs here,
#        pending, or not installed, with the pid, port, real message or traffic
#        count behind it, or the open pull request that finishes a pending
#        part (`bin/jg-migration-live.sh --link` prints the link). Every card
#        post probes first, so a merge card is current too. `live --quiet` is the cadence form: it refreshes the
#        posted card's page in place, posts a fresh card only when a part
#        changed, and prints nothing, so the watcher spends no wake and no model
#        turn on it. It also pushes: when the states of the rows differ from the
#        newest line of data/migration-card/push.tsv (epoch, sha1 of part and
#        state, kind) it posts the card and publishes the live table as a captain
#        digest (`jg-bus.sh publish digest migration-live-<n>`): the critical rows
#        first (config `critical=`, read by jg-critical-path.sh), then a count of
#        the rest. When nothing changed for `push-hours` (default 24) it posts one
#        card and one digest saying so, so a quiet day is a line, not silence. When
#        the bus mode or the captain row is not live the card is the only delivery
#        and its text ends "Phone push is off". Seams: JG_MIGRATION_LIVE_BIN,
#        JG_BUS_CMD, JG_MIGRATION_CARD_NOW. `arm` writes state/migration-card.check.sh, binds it with
#        jg-check-register.sh and runs one pass; `disarm` removes them.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$SCRIPT_DIR/..}}"
CFG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}/migration-card"
DIR="${JG_DATA_OVERRIDE:-$JG_HOME/data}/migration-card"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
SHIM="$STATE/migration-card.check.sh"
LEDGER=$DIR/ledger.tsv
PUSHES=$DIR/push.tsv
LIVE_BIN=${JG_MIGRATION_LIVE_BIN:-$SCRIPT_DIR/jg-migration-live.sh}
BUS_BIN=${JG_BUS_CMD:-$SCRIPT_DIR/jg-bus.sh}
PUSH=''
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

# live_rows: the probed parts as table rows, in the words a reader needs. The last
# column is the open pull request that finishes a pending part, as a link.
live_rows() {
  local part state detail pr word cell url
  [ -r "$DIR/live.tsv" ] || { printf '<tr><td colspan=4>No part is probed yet. Run bin/jg-migration-card.sh live.</td></tr>\n'; return 0; }
  while IFS=$'\t' read -r part state detail pr; do
    case $state in live) word='runs here' ;; pending) word='pending' ;; *) word='not installed' ;; esac
    cell=''
    for url in $pr; do
      case $url in https://*) cell="$cell<a href=\"$url\">#${url##*/}</a> " ;; esac
    done
    [ -n "$cell" ] || cell=$([ "$pr" = - ] && printf '' || printf '%s' "$pr")
    printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$part" "$word" "$detail" "$cell"
  done < "$DIR/live.tsv"
}

# live_summary: the one-line answer to "what is live now".
live_summary() {
  [ -r "$DIR/live.tsv" ] || return 0
  awk -F'\t' '{ n++; if ($2 == "live") l++; else if ($2 == "pending") p++; else a++ }
    END { printf "%d of %d parts run on this machine, %d are pending, %d are not installed.", l, n, p, a }' "$DIR/live.tsv"
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
table{border-collapse:collapse;width:100%}td,th{text-align:left;padding:2px 10px 2px 0;vertical-align:top;border-bottom:1px solid GrayText}td:nth-child(2){white-space:nowrap}td:nth-child(3){overflow-wrap:anywhere}
@media (max-width:560px){body{padding:16px}table,tbody,tr,td{display:block}tr:first-child{display:none}tr{padding:8px 0;border-bottom:1px solid GrayText}td{border:0;padding:0;overflow-wrap:anywhere}td:first-child{font-weight:600}}
@media (prefers-color-scheme:dark){:root{color-scheme:dark light}body{background:Canvas;color:CanvasText}}</style>
<h1>Migration: $(fmt "$del") of $(fmt "$TARGET") lines deleted</h1>
<p>$(fmt "$left") lines are left to delete. $(fmt "$5") merges are recorded on this card since the baseline.</p>
$(cat "$dir/preview.svg")
<h2>What runs on this machine</h2>
<p>$(live_summary)</p>
<p class=sub>Each line is a probe of this machine, last run $(probed_at). A part that is not running names the open pull request that finishes it.</p>
<table><tr><th>Part</th><th>State</th><th>Measured</th><th>Pull request</th></tr>
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

# crit <args>: bin/jg-critical-path.sh against this home; prints nothing without `critical=`.
crit() { JG_HOME="$JG_HOME" JG_CONFIG_OVERRIDE="${CFG%/migration-card}" "$SCRIPT_DIR/jg-critical-path.sh" "$@" 2>/dev/null; }

# switch_kind <title>: a merged switch is a milestone only when its row is live now.
switch_kind() {
  local slug
  if [ -z "$(crit list)" ]; then echo 'a switch is live'; return 0; fi
  slug=$(crit title-row "$1")
  if [ -z "$slug" ]; then echo 'merged; not on the critical path'
  elif [ "$(crit row "$slug" | cut -f2)" = live ]; then echo 'a switch is live'
  else echo "merged; $slug still pending"; fi
}

milestone() {  # <kind> <done> <left> <blockers> <card-key>
  local link summary live done=Done
  link=$(jg_board_link reports "$5" 2>/dev/null) || link="card $5"
  live=$(crit summary)
  [ -z "$live" ] || done='Merged, not a live measure'
  summary=$(printf '%s%s (%s): %s\nLeft: %s\nRelease blockers: %s. Card: %s' "${live:+$live
}" "$done" "$1" "$2" "$3" "$4" "$link")
  "$SCRIPT_DIR/jg-branch-outcome.sh" append --task migration-card --verdict captain --summary "$summary" >/dev/null \
    || echo "jg-migration-card: captain outcome not recorded" >&2
}

post_card() {  # <step> <pr-url> <kind>; posts the next card and records the milestone
  local n del add rows key prev rev title link=()
  [ -z "${2-}" ] || link=(--link "$2")
  "$LIVE_BIN" --quiet >/dev/null 2>&1 \
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
    --about "Latest: $(printf '%s' "$1" | cut -c1-120). Total deleted $(fmt "$del"), added $(fmt "$add").${PUSH:+ $PUSH}" \
    --view "reports/$key/index.html" --preview "reports/$key/preview.svg" ${link[@]+"${link[@]}"} \
    --filer "${FILER:-migration-card}" >/dev/null || die "card post refused for $key"
  sign-off-axi dismiss "$prev" "$BOARD" --reason replaced >/dev/null 2>&1 || echo "jg-migration-card: could not dismiss $prev" >&2
  CARD=$key; printf 'card=%s\n' "$key" > "$DIR/current"
  sed -i '/^card=/d' "$CFG"; printf 'card=%s\n' "$key" >> "$CFG"
  [ -z "${3-}" ] || milestone "$3" "$(fmt "$del") of $(fmt "$TARGET") lines deleted; last change: $1" \
    "$(fmt "$((TARGET - del))") lines" "${4:-none recorded}" "$key"
  printf '%s\n' "$key"
}

# count_live <rows>: "<rows> <live>" over table lines.
count_live() { awk -F'\t' '{ n++; if ($2 == "live") l++ } END { print n + 0, l + 0 }' <<<"$1"; }

# push_text <change|daily>: the digest. The critical rows come first (else every row).
push_text() {
  local crit slug rows since an al cn cl first
  crit=$("$SCRIPT_DIR/jg-critical-path.sh" list 2>/dev/null)
  if [ -n "$crit" ]; then
    rows=$(while IFS= read -r slug; do "$LIVE_BIN" "$slug" 2>/dev/null | head -n 1; done <<<"$crit")
  else rows=$(cat "$DIR/live.tsv"); fi
  read -r cn cl <<<"$(count_live "$rows")"
  if [ "$1" = daily ]; then
    since=$(awk -F'\t' '$3 == "change" { e = $1 } END { print e + 0 }' "$PUSHES")
    first=$(awk -F'\t' '$2 != "live" { print $1 " - " $3; exit }' <<<"$rows")
    printf 'No migration row changed since %s. Live: %s of %s %srows.%s' "$(date -u -d "@$since" '+%Y-%m-%d %H:%M UTC')" \
      "$cl" "$cn" "${crit:+critical }" "${first:+ First pending: $first.}"
    return 0
  fi
  read -r an al <<<"$(count_live "$(cat "$DIR/live.tsv")")"
  [ -z "$crit" ] || awk -F'\t' '{ if ($2 == "live") print $1 ": live"; else print $1 ": " $2 " - " $3 ($4 ~ /^https/ ? " " $4 : "") }' <<<"$rows"
  if [ -n "$crit" ]; then printf 'Other rows: %s of %s live.' "$((al - cl))" "$((an - cn))"
  else printf 'Rows: %s of %s live.' "$al" "$an"; fi
}

# push_kind: change when the rows' states differ from the newest push, daily when none
# changed for push-hours, nothing otherwise. Reads HASH, the sha1 of part and state.
push_kind() {
  local hours last_at last_hash
  hours=$(cfg push-hours); case $hours in '' | *[!0-9]*) hours=24 ;; esac
  [ "$hours" -gt 0 ] || hours=24
  read -r last_at last_hash _ <<<"$(tail -n 1 "$PUSHES" 2>/dev/null)"
  if [ "${last_hash:-}" != "$HASH" ]; then echo change
  elif [ $((NOW - ${last_at:-0})) -ge $((hours * 3600)) ]; then echo daily; fi
}

# cmd_live [--quiet]: measure every part again, then put the result in front of
# the captain. On demand it posts a fresh card and says which key it posted. The
# cadence form (--quiet) refreshes the posted card's own page in place, posts a
# card when a part changed, and pushes the table (see the header).
cmd_live() {
  local quiet=${1-} before after changed=0 key del add n kind='' step
  before=$(cat "$DIR/live.tsv" 2>/dev/null)
  "$LIVE_BIN" --quiet >/dev/null 2>&1 \
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
  NOW=${JG_MIGRATION_CARD_NOW:-$(date +%s)}
  HASH=$(cut -f1,2 "$DIR/live.tsv" 2>/dev/null | sha1sum | cut -d' ' -f1)
  kind=$(push_kind) || kind=''
  step="a part of the stack changed state"
  if [ -n "$kind" ]; then
    PUSH=$(push_text "$kind")
    [ "$kind" != daily ] || step="no part changed since the last push"
    if [ "$("$BUS_BIN" config mode 2>/dev/null)" = live ] && [ "$("$LIVE_BIN" captain 2>/dev/null | cut -f2)" = live ]; then
      "$BUS_BIN" publish digest "migration-live-$(($(grep -c . "$PUSHES" 2>/dev/null) + 1))" "$PUSH" >/dev/null \
        || echo "jg-migration-card: the captain channel refused the push" >&2
    else PUSH="$PUSH Phone push is off: the captain channel is not live."; fi
  fi
  if [ "$changed" -eq 1 ] || [ -n "$kind" ]; then post_card "$step" "" "" >/dev/null; fi
  [ -z "$kind" ] || printf '%s\t%s\t%s\n' "$NOW" "$HASH" "$kind" >> "$PUSHES"
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
    if grep -qiE 'switch.*(live|on)|live.*switch' <<<"$title"; then kind=$(switch_kind "$title")
    elif grep -qiE 'go port.*(done|complete|landed)' <<<"$title"; then kind='a Go port is done'
    elif [ $((after / 5000)) -gt $((before / 5000)) ]; then kind="$((after / 5000 * 5000)) lines deleted"; fi
    post_card "$title" "$URL" "$kind" ;;
  milestone)
    [ -n "${2-}" ] || die "milestone needs a kind"
    read -r del _ n <<<"$(totals)"
    milestone "$2" "$(fmt "$del") of $(fmt "$TARGET") lines deleted" "$(fmt "$((TARGET - del))") lines" "${3:-none recorded}" "${CARD:-}" ;;
  *) die "usage: jg-migration-card.sh merge <pr-url> | milestone <kind> [blockers] | live [--quiet] | arm | disarm" ;;
esac

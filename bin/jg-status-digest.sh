#!/usr/bin/env bash
# jg-status-digest.sh - the batch-class captain outcome, pushed at every milestone
# and at most every N hours, so a big effort answers "done?" and "what is live?"
# by itself.
#
# WHY. The captain asked "migration done?" and, minutes later, "what is live on
# our system?". Both answers sat in durable records and neither reached him on
# its own: a big effort changes every hour and nothing he could read followed it.
# So the effort records one batch-class captain outcome of four lines - done,
# left, release blockers, what is live now - and this script pushes it.
#
# CONTRACT (this header is the one owner).
#   record   $DATA/status-digest/records.jsonl, append-only, one JSON object per
#            recorded outcome: {"at","since","milestone","left","blockers"}. The
#            newest record is the effort's standing words, and the earliest
#            `since` is when the effort began, so a batch that started before it
#            was first recorded passes --since and Done counts from the truth.
#            Done and Live now are never recorded as prose, because they are
#            counted (see `lines`).
#   pushes   $DATA/status-digest/pushes.jsonl, append-only, one JSON object per
#            delivered digest: {"at","via","key","hash","digest"}. It is both the
#            delivery record and the cadence and no-repeat state.
#   cadence  config/status-digest `every-hours=<N>`, default 4, in whole hours.
#            `tick` pushes only when the newest push is N hours old, so a home
#            gets at most one cadence push per window. `record` is a milestone
#            and pushes at once.
#   no-repeat The digest text is hashed and compared with the newest push, so an
#            unchanged digest is recorded as unchanged and never pushed twice.
#   channel  bin/jg-bus.sh `config mode` = live means the captain channel is live,
#            and the digest is published to it (`publish digest <key> <text>`).
#            Otherwise it is posted as a report card on the board named by
#            config/fleet-board, replacing the previous digest card, so the
#            captain still receives it before the channel ships.
#   lines    Done   the newest milestone, plus the merged rows of
#                   data/metrics/task-outcomes.tsv that ended since the effort
#                   began, because that record is what says work landed.
#            Left   and Release blockers are the recorded words, since only the
#                   lead knows them.
#            Live now the newest released ref in data/releases, or the plain
#                   statement that no release is recorded yet, never a guess.
#
# Usage:
#   jg-status-digest.sh <home> record <milestone> [--left <text>] [--blockers <text>] [--since <epoch>]
#   jg-status-digest.sh <home> tick [--now <epoch>]
#   jg-status-digest.sh <home> show [--now <epoch>]
#
# A scheduled home check calls `tick` every poll; every milestone path calls
# `record`. Env: JG_DATA_OVERRIDE, JG_CONFIG_OVERRIDE, JG_STATUS_DIGEST_POST (the
# board poster, default sign-off-axi), JG_STATUS_DIGEST_PROJECT and
# JG_STATUS_DIGEST_FILER (the card's project and filer).
set -u

die() { printf 'jg-status-digest: %s\n' "$*" >&2; exit 2; }

[ "$#" -ge 2 ] || die "usage: jg-status-digest.sh <home> record <milestone> | tick | show"
home=$(cd "$1" 2>/dev/null && pwd -P) || die "no home at $1"
shift
verb=$1
shift

DATA=${JG_DATA_OVERRIDE:-$home/data}
CFG=${JG_CONFIG_OVERRIDE:-$home/config}
DIR=$DATA/status-digest
REC=$DIR/records.jsonl
PUSHES=$DIR/pushes.jsonl
now=$(date +%s)
milestone='' left='' blockers='' since=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --now) now=${2:?}; shift 2 ;;
    --left) left=${2-}; shift 2 || die "--left needs text" ;;
    --blockers) blockers=${2-}; shift 2 || die "--blockers needs text" ;;
    --since) since=${2:?}; shift 2 || die "--since needs epoch seconds" ;;
    --*) die "unknown flag $1" ;;
    *) [ -n "$milestone" ] && die "record takes one milestone"; milestone=$1; shift ;;
  esac
done
case $now in ''|*[!0-9]*) die "--now needs epoch seconds" ;; esac
[ -z "$since" ] || case $since in ''|*[!0-9]*) die "--since needs epoch seconds" ;; esac

# The cadence in whole hours; a missing, malformed or zero value falls back to 4.
hours() {
  local n
  n=$(sed -n 's/^every-hours=//p' "$CFG/status-digest" 2>/dev/null | tail -n 1)
  case $n in ''|*[!0-9]*) n=4 ;; 0) n=4 ;; esac
  printf '%s\n' "$n"
}

# The newest release the record names, or nothing: one release per line, `#` comments.
released() { [ -r "$DATA/releases" ] || return 0; awk '!/^[[:space:]]*#/ && NF {r=$1} END {print r}' "$DATA/releases"; }

# Count the merged task outcomes that ended since <epoch>, from the recorded rows.
merged_since() {  # <epoch>
  local f=$DATA/metrics/task-outcomes.tsv
  [ -r "$f" ] || { echo 0; return 0; }
  awk -F'\t' -v s="$1" 'FNR > 1 && $7 ~ /^[0-9]+$/ && $7 >= s && $8 == "merged"' "$f" | wc -l | tr -d ' '
}

# Trim a trailing period, so a line does not end with two.
clean() { printf '%s' "${1-}" | sed -e 's/[[:space:]]*$//' -e 's/\.$//'; }

# Build the four lines into DONE, LEFT, BLOCKERS and LIVE, or die with no record.
render() {
  local rec start live merged leftw blockw unit=task
  [ -s "$REC" ] || die "no batch outcome is recorded yet: run record first"
  rec=$(tail -n 1 "$REC")
  start=$(jq -s 'map(.since // .at) | min' "$REC")
  merged=$(merged_since "$start")
  live=$(released)
  leftw=$(clean "$(printf '%s' "$rec" | jq -r '.left // ""')")
  blockw=$(clean "$(printf '%s' "$rec" | jq -r '.blockers // ""')")
  [ -n "$leftw" ] || leftw='not recorded'
  [ -n "$blockw" ] || blockw='none recorded'
  [ "$merged" = 1 ] || unit=tasks
  DONE="Done: $(clean "$(printf '%s' "$rec" | jq -r '.milestone')"); $merged $unit merged since $(date -u -d "@$start" +%Y-%m-%d)"
  LEFT="Left: $leftw"
  BLOCKERS="Release blockers: $blockw"
  if [ -n "$live" ]; then LIVE="Live now: $live"; else LIVE='Live now: no release is recorded yet'; fi
}

digest_text() { printf '%s\n%s\n%s\n%s' "$DONE" "$LEFT" "$BLOCKERS" "$LIVE"; }

# 'live' when the captain channel is live in this home, or nothing.
channel_mode() {
  [ -x "$home/bin/jg-bus.sh" ] || return 0
  "$home/bin/jg-bus.sh" config mode 2>/dev/null || true
}

xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# The card's picture, also embedded in its page: the three lines a card can hold.
preview_svg() {  # <done> <left> <live>
  printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 96" width="400" height="96">'
  printf '<rect width="400" height="96" fill="none" stroke="GrayText"/>'
  printf '<text x="12" y="28" font-family="system-ui" font-size="14" fill="GrayText">%s</text>' "$(xml "$(cut -c1-52 <<<"$1")")"
  printf '<text x="12" y="56" font-family="system-ui" font-size="14" fill="GrayText">%s</text>' "$(xml "$(cut -c1-52 <<<"$2")")"
  printf '<text x="12" y="84" font-family="system-ui" font-size="14" fill="GrayText">%s</text>' "$(xml "$(cut -c1-52 <<<"$3")")"
  printf '</svg>\n'
}

# One self-contained page on the board's own forms: the answer, one picture, one
# tap-through of the recorded milestones, and the detail folded.
write_card() {  # <dir> <done> <left> <blockers> <live> <milestones-json>
  local dir=$1 steps
  steps=$(printf '%s' "$6" | jq -c 'if length == 0 then ["none recorded"] else . end')
  mkdir -p "$dir"
  {
    cat <<'HTML'
<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width, initial-scale=1"><title>Batch digest</title>
<style>:root{color-scheme:light dark}body{background:Canvas;color:CanvasText;font:16px/1.5 system-ui,sans-serif;margin:0 auto;padding:24px;max-width:700px}
.sub,summary{color:GrayText}button{background:Canvas;color:CanvasText;border:1px solid GrayText;padding:8px 16px}svg{max-width:100%;height:auto}
@media (prefers-color-scheme:dark){:root{color-scheme:dark light}body{background:Canvas;color:CanvasText}}</style>
HTML
    printf '<h1>%s</h1>\n' "$(xml "$2")"
    printf '<p>%s</p>\n<p>%s</p>\n<p>%s</p>\n' "$(xml "$3")" "$(xml "$4")" "$(xml "$5")"
    preview_svg "$2" "$3" "$5"
    printf '<p class=sub>Tap through the milestones this batch recorded.</p>\n<p id=t></p><button id=b>Next milestone</button>\n'
    printf '<details><summary>Details</summary><p>Done counts the merged tasks in the task outcome record since this batch began. Live now names the newest release in the release record, so no line here is a guess.</p></details>\n'
    printf '<script>var R=%s,i=0,t=document.getElementById("t");function d(){t.textContent=(i+1)+" of "+R.length+": "+R[i]}\ndocument.getElementById("b").onclick=function(){i=(i+1)%%R.length;d()};d()</script>\n' "$steps"
  } > "$dir/index.html"
  preview_svg "$2" "$3" "$5" > "$dir/preview.svg"
}

# Post the digest as the fleet board report card and replace the previous one.
post_card() {  # <key> <done> <left> <blockers> <live>
  local key=$1 board dir prev
  board=$(tr -d '\n' < "$CFG/fleet-board" 2>/dev/null || true)
  [ -n "$board" ] || die "no fleet board is named: config/fleet-board is missing or empty"
  dir=$(dirname "$board")/reports/$key
  write_card "$dir" "$2" "$3" "$4" "$5" "$(jq -sc '[.[].milestone]' "$REC")"
  "${JG_STATUS_DIGEST_POST:-sign-off-axi}" post "$board" --type report --purpose status \
    --project "${JG_STATUS_DIGEST_PROJECT:-Batch}" --filer "${JG_STATUS_DIGEST_FILER:-status-digest}" \
    --key "$key" --title "$2" --about "$3 $4 $5" \
    --view "reports/$key/index.html" --preview "reports/$key/preview.svg" >/dev/null \
    || die "the fleet board refused the digest card $key"
  prev=$(tail -n 1 "$PUSHES" 2>/dev/null | jq -r 'select(.via == "card") | .key // empty' 2>/dev/null || true)
  if [ -n "$prev" ]; then
    "${JG_STATUS_DIGEST_POST:-sign-off-axi}" dismiss "$prev" "$board" --reason replaced >/dev/null 2>&1 || true
  fi
}

# Push the digest when the cadence allows it and it differs from the newest push.
push() {  # <milestone|cadence>
  local why=$1 text hash last lastat gap every via key
  render
  text=$(digest_text)
  hash=$(printf '%s' "$text" | cksum | tr -d ' ')
  last=$(tail -n 1 "$PUSHES" 2>/dev/null || true)
  if [ "$why" = cadence ] && [ -n "$last" ]; then
    lastat=$(printf '%s' "$last" | jq -r '.at')
    every=$(hours)
    gap=$((now - lastat))
    if [ "$gap" -lt $((every * 3600)) ]; then
      printf 'not due: the last digest was %s minutes ago, and the cadence is %s h\n' "$((gap / 60))" "$every"
      return 0
    fi
  fi
  if [ -n "$last" ] && [ "$(printf '%s' "$last" | jq -r '.hash')" = "$hash" ]; then
    printf 'unchanged: the digest is the same as the last one, so it is not pushed again\n'
    return 0
  fi
  key=status-digest-$(date -u -d "@$now" +%Y%m%d%H%M)
  if [ "$(channel_mode)" = live ]; then
    via=channel
    "$home/bin/jg-bus.sh" publish digest "$key" "$text" >/dev/null || die "the captain channel refused the digest"
  else
    via=card
    post_card "$key" "$DONE" "$LEFT" "$BLOCKERS" "$LIVE"
  fi
  mkdir -p "$DIR"
  jq -cn --argjson at "$now" --arg via "$via" --arg key "$key" --arg hash "$hash" --arg digest "$text" \
    '{at: $at, via: $via, key: $key, hash: $hash, digest: $digest}' >> "$PUSHES" \
    || die "could not record the push in $PUSHES"
  printf 'pushed: %s %s\n%s\n' "$via" "$key" "$text"
}

case $verb in
  record)
    [ -n "$milestone" ] || die "record needs a milestone"
    mkdir -p "$DIR" || die "cannot create $DIR"
    jq -cn --argjson at "$now" --argjson since "${since:-$now}" --arg milestone "$milestone" --arg left "$left" --arg blockers "$blockers" \
      '{at: $at, since: $since, milestone: $milestone, left: $left, blockers: $blockers}' >> "$REC" \
      || die "could not record the milestone in $REC"
    push milestone ;;
  tick)
    [ -s "$REC" ] || exit 0
    push cadence ;;
  show)
    render
    digest_text
    printf '\n' ;;
  *) die "unknown verb $verb: use record, tick or show" ;;
esac

#!/usr/bin/env bash
# critical-stall watcher check: a critical migration row that sits pending with no commit raises the central
# `stranded` alert (bin/jg-alert.sh raise, then deliver; subject = the row's slug) and one board card. No model
# turn, and nothing is printed.
# Usage: critical-stall.sh check <jg-home>
#
# For each row of `bin/jg-critical-path.sh rows` that is not live, this records the epoch the row was first
# seen pending in <home>/data/critical-stall/seen.tsv (`slug<TAB>epoch`; a row that turns live is dropped). A
# row is stalled when it has been pending for 24 h or more (config/critical-stall-hours changes the 24) and
# either it has no pull request, or the newest commit on its pull requests is that old. A stall raises, once
# per (slug, pull request, newest commit) in alerts.jsonl: one alert (a new commit replaces the old record), and one card through
# `bin/jg-question-card.sh` on the board config/fleet-board names. A new commit changes the key, so a row
# that moves and stalls again alerts again; a forge failure is silent and retried next sweep.
# The card is skipped when stale-pr-alarm already alerted on the same pull request after its newest commit,
# so the captain gets one card for one pull request; the alert is still raised.
# Seams for tests: JG_MIGRATION_LIVE_BIN (the probe, read by jg-critical-path.sh and here for the part's name),
# JG_STALL_GH (gh-axi), JG_STALL_ALERT (jg-alert.sh), JG_STALL_CARD, JG_STALL_NOW (epoch).
set -u
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: critical-stall.sh check <jg-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
export JG_HOME=$FMH
GH=${JG_STALL_GH:-gh-axi}
ALERT=${JG_STALL_ALERT:-$FMH/bin/jg-alert.sh}
CARD=${JG_STALL_CARD:-$FMH/bin/jg-question-card.sh}
PROBE=${JG_MIGRATION_LIVE_BIN:-$FMH/bin/jg-migration-live.sh}
DIR=$FMH/data/critical-stall SEEN=$DIR/seen.tsv ALERTS=$DIR/alerts.jsonl
ALARM=$FMH/data/jg-merge-on-green/stale-pr-alarm
NOW=${JG_STALL_NOW:-$(date +%s)}
BUDGET=$(( ${JG_CHECK_TIMEOUT:-30} / 4 )); [ "$BUDGET" -ge 5 ] || BUDGET=5
HOURS=$(tr -dc 0-9 2>/dev/null < "$FMH/config/critical-stall-hours"); [ "${HOURS:-0}" -gt 0 ] || HOURS=24
TAB=$'\t'
umask 077

rows=$("$FMH/bin/jg-critical-path.sh" rows 2>/dev/null) || exit 0
[ -n "$rows" ] || exit 0
mkdir -p "$DIR" 2>/dev/null || exit 0

# 1. First-seen times: keep a pending row's time, start one the first pass that sees it, drop a live row.
next=$(while IFS="$TAB" read -r slug state _; do
  [ "$state" != live ] || continue
  printf '%s\t%s\n' "$slug" "$(awk -F'\t' -v s="$slug" '$1 == s { print $2; exit }' "$SEEN" 2>/dev/null | grep . || echo "$NOW")"
done <<< "$rows")
if [ "$next" != "$(cat "$SEEN" 2>/dev/null)" ]; then
  printf '%s\n' "$next" | sed '/^$/d' > "$SEEN.new" && mv -f "$SEEN.new" "$SEEN"
fi

recorded() { grep -qF -- "\"key\":\"$1\"" "$ALERTS" 2>/dev/null; }  # <key>
record() { printf '{"key":"%s","at":%s}\n' "$1" "$NOW" >> "$ALERTS"; }

# 2. A stalled row alerts once per (slug, pull request, newest commit).
while IFS="$TAB" read -r slug first; do
  [ -n "$slug" ] && [ "$(( NOW - first ))" -ge $(( HOURS * 3600 )) ] || continue
  pending_h=$(( (NOW - first) / 3600 ))
  urls=$(printf '%s\n' "$rows" | awk -F'\t' -v s="$slug" '$1 == s { print $3 }' \
    | grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+')
  newest=0 sha=none url=- failed=0
  for u in $urls; do
    path=${u#https://github.com/}; repo=${path%/pull/*}; num=${path##*/}
    got=$(timeout "$BUDGET" "$GH" api "repos/$repo/pulls/$num/commits?per_page=100" \
      --jq 'max_by(.commit.committer.date) | [.sha, .commit.committer.date] | @tsv' 2>/dev/null) || { failed=1; break; }
    ts=$(date -u -d "${got##*"$TAB"}" +%s 2>/dev/null) || { failed=1; break; }
    [ "$ts" -gt "$newest" ] && newest=$ts sha=${got%%"$TAB"*} url=$u
  done
  [ "$failed" = 0 ] || continue
  commit_h=$(( (NOW - newest) / 3600 ))
  [ -z "$urls" ] || [ "$(( NOW - newest ))" -ge $(( HOURS * 3600 )) ] || continue
  key=$slug.$url.$sha

  recorded "alert.$key" || {
    "$ALERT" resolve "stranded--$slug" >/dev/null 2>&1
    "$ALERT" raise stranded "$slug" | "$ALERT" deliver >/dev/null 2>&1 && record "alert.$key"
  }

  board=$(tr -d "\n" 2>/dev/null < "$FMH/config/fleet-board")
  [ -n "$board" ] && ! recorded "card.$key" || continue
  alarm=$ALARM/$(printf '%s' "${url#https://github.com/}" | sed 's#/pull/#.#; s#/#__#')
  if [ "$url" != - ] && [ -f "$alarm" ] && [ "$(stat -c %Y "$alarm" 2>/dev/null || echo 0)" -gt "$newest" ]; then
    record "card.$key"; continue
  fi
  name=$("$PROBE" "$slug" 2>/dev/null | head -n 1 | cut -f1); name=${name:-$slug}
  cardrc=0
  out=$(timeout "$BUDGET" "$CARD" post --board "$board" --must design-pick --route main --filer critical-stall \
    --ask-ref "critical-stall-$slug-${sha:0:8}" --key "critical-stall-$slug-${sha:0:8}" \
    --title "$name is stalled for $pending_h hours. Restart the work now?" \
    --why "It is on the critical path, so later migration work waits for it. $( [ -n "$urls" ] && echo "Its newest commit is $commit_h hours old." || echo "It has no open pull request.")" \
    --detail "Pull request link: $url" \
    --outcome yes="Work on it restarts now." --outcome no="The plan is reordered." \
    --recommend yes --recommend-reason "Nothing else on the path can go live before it." --default no 2>&1) || cardrc=1
  # The board refuses a near-identical open question with CONFLICT: that card already stands, so it is not repeated.
  if [ "$cardrc" = 0 ] || printf '%s' "$out" | grep -q CONFLICT; then record "card.$key"; fi
done <<< "$next"
exit 0

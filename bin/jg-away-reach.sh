#!/usr/bin/env bash
# jg-away-reach.sh - away mode reaches the captain on Telegram by itself.
#
# Usage: jg-away-reach.sh arm | disarm | tick | digest | status | episodes
#
# WHAT IT DOES. While an away record exists (bin/jg-afk-contract.sh, mode away) this sends the
# captain's private chat (`jg-bus.sh gateway push`):
#   - one update every JG_AWAY_REACH_INTERVAL seconds (default 1800, thirty minutes): the worker
#     counts, then bin/jg-owner-asks.sh (Needs you / Not done / Done). An update whose body equals
#     the last one sent is not sent: an unchanged fleet is not news, the clock still advances.
#   - an urgent message as the event arises, never waiting for the next slot: a worker's new
#     `needs-decision`, `blocked` or `failed` status line, or a line that asks for a sign-in or a
#     credential. Each status line is sent once (a per-file byte cursor).
#   - an episode page (core/sentinel/episodes.sh, slice H17): an alert held open at the owner's rung 4 is one message when it
#     opens and one when it closes, several that change together are one message, and `episodes` runs on its own so the sentinel
#     can call it with no away record. The urgent lines, the updates and the episode pages share one budget of
#     JG_AWAY_REACH_BUDGET (4) sends an hour (state/away-reach.budget); a page over it waits for the next tick and is joined to it.
#     An urgent line is never held back by the budget, but it counts.
# With no token file the push sends nothing and says nothing (docs/captain-chat.md "Pushes").
#
# ARMED BY THE MODE. bin/jg-afk-contract.sh `enter` calls `arm` and `archive` calls `disarm`, so
# going afk and returning need no further command. `arm` writes state/away-reach.check.sh and
# binds it with bin/jg-check-register.sh; the watcher runs it every check interval
# (JG_CHECK_INTERVAL, default 300 seconds), so an urgent message is at most one interval late.
# Everything is on disk (the check shim, its trust record, state/away-reach.d/), so a restart of the
# home changes nothing. `tick` also disarms itself when no away record exists.
#
# DETERMINISTIC. The clock, the arming and the send are shell: no model is asked to wake, to
# decide, or to write a word. The text is a fixed template over the records.
#
# Environment: JG_HOME, JG_STATE_OVERRIDE, JG_DATA_OVERRIDE, JG_BUS_CMD (the sender, default
# bin/jg-bus.sh), JG_OWNER_ASKS_BIN, JG_AWAY_REACH_INTERVAL, JG_AWAY_REACH_NOW (epoch, for tests).
# Exit: 0 always for arm/tick (a failed push is logged on stderr and retried next tick), 2 usage.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
ID=away-reach
SHIM="$STATE/$ID.check.sh"
DIR="$STATE/$ID.d"
EPISODES=${JG_EPISODES_BIN:-$JG_ROOT/core/sentinel/episodes.sh}
BUDGET_FILE="$STATE/$ID.budget"
BUDGET=${JG_AWAY_REACH_BUDGET:-4}
case "$BUDGET" in ''|*[!0-9]*|0) BUDGET=4 ;; esac
BUS_BIN=${JG_BUS_CMD:-$SCRIPT_DIR/jg-bus.sh}
ASKS_BIN=${JG_OWNER_ASKS_BIN:-$SCRIPT_DIR/jg-owner-asks.sh}
INTERVAL=${JG_AWAY_REACH_INTERVAL:-1800}
case "$INTERVAL" in ''|*[!0-9]*|0) INTERVAL=1800 ;; esac
RECORD="$STATE/.afk-contract"

now() { printf '%s' "${JG_AWAY_REACH_NOW:-$(date +%s)}"; }
log() { printf 'jg-away-reach: %s\n' "$*" >&2; }

# The record's mode: away, quiet, or nothing. Read the file directly so a tick never takes the
# record lock or sources the contract: a plain `mode: quiet` line is quiet, any other record is away.
record_mode() {
  [ -f "$RECORD" ] || return 1
  if grep -qx 'mode: quiet' "$RECORD" 2>/dev/null; then printf quiet; else printf away; fi
}
record_epoch() { sed -n 's/^entered_epoch: *//p' "$RECORD" 2>/dev/null | head -n 1; }

scrub() {  # strip secrets and the raw status prefix from a line, cap its length
  sed -E -e 's/^[a-z-]+ *(\[[^]]*\])*: *//' \
    -e 's/[0-9]{6,}:[A-Za-z0-9_-]{30,}/[removed]/g' \
    -e 's/(sk|ghp|gho|ghs|github_pat|xox[abp]|AKIA)[-_A-Za-z0-9]{16,}/[removed]/g' \
    -e 's/([Bb]earer) +[A-Za-z0-9._~+\/=-]{16,}/\1 [removed]/g' \
    -e 's/((token|secret|password|passwd|api[_-]?key) *[=:] *)[^ ]{8,}/\1[removed]/gI' | cut -c1-300
}

push() {  # <text> -> 0 when the sender accepted it
  printf '%s\n' "$1" | "$BUS_BIN" gateway push >/dev/null 2>&1 \
    || { log "the captain chat refused the push; it is retried on the next tick"; return 1; }
  printf '%s\n' "$(now)" >> "$BUDGET_FILE" 2>/dev/null || true
}

# Sends in the last hour, every kind: the one budget.
budget_used() {
  local t; t=$(now)
  awk -v t="$t" '$1 ~ /^[0-9]+$/ && t - $1 < 3600 { n++ } END { print n + 0 }' "$BUDGET_FILE" 2>/dev/null
  [ ! -f "$BUDGET_FILE" ] || { tail -n 50 "$BUDGET_FILE" > "$BUDGET_FILE.tmp" && mv -f "$BUDGET_FILE.tmp" "$BUDGET_FILE"; } 2>/dev/null
}

# One message for the episodes that opened or closed since the last call, within the budget.
cmd_episodes() {
  [ -x "$EPISODES" ] && [ -d "$STATE" ] || return 0
  local ev kind key a b text="" n=0 t
  t=$(now)
  ev=$("$EPISODES" events "$STATE" "$t") || return 0
  [ -n "$ev" ] || return 0
  [ "$(budget_used)" -lt "$BUDGET" ] || return 0
  while IFS=$'\t' read -r kind key a b; do
    [ -n "$kind" ] || continue
    n=$((n + 1))
    if [ "$kind" = open ]; then
      text="$text"$'\n'"Blocked since $(date -u -d "@$a" '+%H:%M UTC' 2>/dev/null): $(printf '%s' "$b" | scrub)"
    else
      text="$text"$'\n'"Cleared after $((a / 60)) minutes: $key"
    fi
  done <<< "$ev"
  push "The fleet needs you ($n change$([ "$n" -eq 1 ] || echo s)).$text" || return 0
  while IFS=$'\t' read -r kind key a b; do
    [ -n "$kind" ] || continue
    "$EPISODES" "mark-$kind" "$STATE" "$key" "$t"
  done <<< "$ev"
}

cmd_arm() {
  local tmp entered
  [ "$(record_mode)" = away ] || { cmd_disarm >/dev/null; return 0; }
  [ -d "$STATE" ] || return 0
  mkdir -p "$DIR" || return 0
  tmp=$(umask 077; mktemp "$STATE/.$ID.XXXXXX") || { log "cannot write the check shim"; return 0; }
  { printf '#!/usr/bin/env bash\nexport JG_HOME=%q JG_STATE_OVERRIDE=%q\nexec %q tick\n' \
      "$JG_HOME" "$STATE" "$SCRIPT_DIR/jg-away-reach.sh" > "$tmp" \
    && chmod 0700 "$tmp" && mv -f -- "$tmp" "$SHIM"; } || { rm -f -- "$tmp"; log "cannot write the check shim"; return 0; }
  JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/jg-check-register.sh" "$ID" >/dev/null \
    || { log "cannot register the check"; return 0; }
  entered=$(record_epoch)
  # A new away session starts its own clock and its own cursors; a refresh of the same one keeps them.
  if [ "$(cat "$DIR/session" 2>/dev/null)" != "$entered" ]; then
    rm -f "$DIR"/cursor.* "$DIR/last-body"
    printf '%s\n' "$entered" > "$DIR/session"
    printf '%s\n' "$(now)" > "$DIR/last-slot"
    local f id
    for f in "$STATE"/*.status; do
      [ -f "$f" ] || continue
      id=$(basename "$f" .status)
      wc -c < "$f" | tr -d ' ' > "$DIR/cursor.$id"
    done
    push "Away mode is on. I will send an update every $((INTERVAL / 60)) minutes, and anything that needs you at once." || true
  fi
  printf 'armed: %s (a Telegram update every %s minutes while away)\n' "$ID" "$((INTERVAL / 60))"
}

cmd_disarm() {
  [ -d "$STATE" ] || return 0
  JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/jg-check-unregister.sh" "$ID" >/dev/null 2>&1 || true
  rm -rf -- "$DIR"
  printf 'disarmed: %s\n' "$ID"
}

# Urgent: new needs-decision / blocked / failed lines, and any new line asking for a sign-in.
scan_urgent() {
  local f id size cur chunk line kind text
  for f in "$STATE"/*.status; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .status)
    size=$(wc -c < "$f" | tr -d ' ')
    cur=$(cat "$DIR/cursor.$id" 2>/dev/null)
    case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
    [ "$cur" -le "$size" ] || cur=0
    [ "$size" -gt "$cur" ] || continue
    chunk=$(tail -c +"$((cur + 1))" "$f" | head -c "$((size - cur))")
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      kind=''
      case "$line" in
        needs-decision*) kind='A worker needs your decision' ;;
        blocked*) kind='A worker is blocked' ;;
        failed*) kind='A worker failed' ;;
        done*|resolved*) ;;
        *) if printf '%s' "$line" | grep -qiE 'sign[- ]?in|log[- ]?in needed|credential|re-?auth|token (expired|missing)'; then kind='A worker needs a sign-in'; fi ;;
      esac
      [ -n "$kind" ] || continue
      text=$(printf '%s' "$line" | scrub)
      push "Urgent: $kind. $text" || return 0
    done <<< "$chunk"
    printf '%s\n' "$size" > "$DIR/cursor.$id"
  done
}

worker_counts() {
  local f verb working=0 waiting=0 blocked=0 failed=0 done_=0
  for f in "$STATE"/*.status; do
    [ -f "$f" ] || continue
    verb=$(tail -n 1 "$f" | sed -E 's/^([a-z-]+).*/\1/')
    case "$verb" in
      working|paused) working=$((working + 1)) ;;
      needs-decision) waiting=$((waiting + 1)) ;;
      blocked) blocked=$((blocked + 1)) ;;
      failed) failed=$((failed + 1)) ;;
      done|resolved) done_=$((done_ + 1)) ;;
    esac
  done
  printf 'Workers: %s under way, %s waiting for you, %s blocked, %s failed, %s finished.' "$working" "$waiting" "$blocked" "$failed" "$done_"
}

# The body of an update, without its time line, so two bodies compare.
cmd_digest() {
  local asks
  worker_counts; printf '\n'
  asks=$("$ASKS_BIN" 2>/dev/null) || asks='The list of your asks could not be read just now.'
  printf '\n%s\n' "$asks"
  "$EPISODES" open "$STATE" 2>/dev/null | sed '1i\\nOpen blocked episodes:'
}

cmd_tick() {
  local mode last t body prev
  mode=$(record_mode) || mode=''
  if [ "$mode" != away ]; then cmd_disarm >/dev/null; return 0; fi
  mkdir -p "$DIR" || return 0
  scan_urgent
  cmd_episodes
  t=$(now)
  last=$(cat "$DIR/last-slot" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=$t; printf '%s\n' "$t" > "$DIR/last-slot" ;; esac
  [ $((t - last)) -ge "$INTERVAL" ] || return 0
  body=$(cmd_digest)
  prev=$(cat "$DIR/last-body" 2>/dev/null)
  if [ "$body" = "$prev" ]; then
    printf '%s\n' "$t" > "$DIR/last-slot"
    return 0
  fi
  if push "Away update, $(date -u -d "@$t" '+%H:%M UTC' 2>/dev/null)."$'\n\n'"$body"; then
    printf '%s' "$body" > "$DIR/last-body"
    printf '%s\n' "$t" > "$DIR/last-slot"
  fi
  return 0
}

cmd_status() {
  if [ -x "$SHIM" ] && [ -d "$DIR" ]; then
    printf 'armed: last update slot %s, interval %ss\n' "$(cat "$DIR/last-slot" 2>/dev/null)" "$INTERVAL"
  else
    printf 'not armed\n'
  fi
}

case "${1-}" in
  arm) cmd_arm ;;
  disarm) cmd_disarm ;;
  tick) cmd_tick ;;
  digest) cmd_digest ;;
  status) cmd_status ;;
  episodes) cmd_episodes ;;
  *) printf 'usage: jg-away-reach.sh arm | disarm | tick | digest | status | episodes\n' >&2; exit 2 ;;
esac

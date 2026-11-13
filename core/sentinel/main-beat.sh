#!/usr/bin/env bash
# main-beat.sh - the sentinel's rung for a silent Main (report section 6.10, machine 3 `supervision`): Main has the same rules as a worker.
#
# Usage: JG_HOME=<home> main-beat.sh run     one pass, run from outside the session (the timer of jg-sentinel-watch.sh runs it)
# Reads, never writes: state/beats/main (`<epoch> <event>` lines, the hooks of the beat slice write them), state/.lock (the session)
# and state/.wake-queue (a row is `<seq> <epoch in ms> <type> <key> <reason>`, tab-separated). A pass acts only while the session lives
# (a stopped session is the watch pass's escalation-stuck).
#   silent         the last beat is a working one (UserPromptSubmit, PostToolBatch) and is older than JG_MAIN_BEAT_SECS (600): the session
#                  was cut off or hangs inside a call. An idle Main (last beat Stop) is waiting for a wake and is healthy.
#   wake-unread    the oldest wake in the queue is older than JG_MAIN_WAKE_SECS (1200): Main does not handle what it was told.
# Either one restarts the session once per episode (bin/jg-control.sh primary relaunch; JG_MAIN_RELAUNCH replaces its command) and pages
# the owner once: supervision-down--main-silent through bin/jg-alert.sh, whose ladder carries it to the owner. An episode is the beat
# epoch or the oldest wake's sequence, kept in data/main-beat/episodes, so a rerun never restarts the session twice for it.
# A fresh beat and a queue with no old wake resolve the alert. Seams for tests: JG_MAIN_NOW, JG_MAIN_BEAT_FILE, JG_MAIN_ALERT.
# Exit 0 after a pass, 2 for usage or a missing JG_HOME.
set -u
export LC_ALL=C
case "${1:-}" in
  run) ;;
  -h|--help) sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: JG_HOME=<home> main-beat.sh run" >&2; exit 2 ;;
esac
[ -n "${JG_HOME:-}" ] || { echo "main-beat: JG_HOME must be set explicitly" >&2; exit 2; }
JG_HOME=$(cd "$JG_HOME" 2>/dev/null && pwd -P) || { echo "main-beat: JG_HOME is not a directory" >&2; exit 2; }
export JG_HOME
BIN=${JG_BIN:-$JG_HOME/bin}
STATE=$JG_HOME/state DIR=$JG_HOME/data/main-beat
BEAT_FILE=${JG_MAIN_BEAT_FILE:-$STATE/beats/main}
ALERT=${JG_MAIN_ALERT:-$BIN/jg-alert.sh}
NOW=${JG_MAIN_NOW:-$(date +%s)}
BEAT_SECS=${JG_MAIN_BEAT_SECS:-600}
WAKE_SECS=${JG_MAIN_WAKE_SECS:-1200}
EPISODES=$DIR/episodes
SUBJECT=main-silent
mkdir -p "$DIR" 2>/dev/null || exit 0

session_live() {
  local pid; pid=$(sed -n 1p "$STATE/.lock" 2>/dev/null)
  case $pid in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

# <seq> <age seconds> of the oldest wake in the queue, nothing when it is empty.
oldest_wake() {
  awk -F'\t' -v now="$NOW" 'NF >= 4 && $2 ~ /^[0-9]+$/ { t = ($2 > 100000000000) ? int($2 / 1000) : $2; if (min == "" || t < min) { min = t; seq = $1 } } END { if (min != "") print seq, now - min }' "$STATE/.wake-queue" 2>/dev/null
}

# restart <episode key> <why>: restart the session and page the owner, once for this episode.
restart() {
  grep -qxF "$1" "$EPISODES" 2>/dev/null && return 0
  printf '%s\n' "$1" >> "$EPISODES"
  if [ -n "${JG_MAIN_RELAUNCH:-}" ]; then "$JG_MAIN_RELAUNCH" >/dev/null 2>&1 || true
  else timeout 60 "$BIN/jg-control.sh" primary relaunch >/dev/null 2>&1 || true; fi
  JG_STATE_OVERRIDE="$STATE" "$ALERT" raise supervision-down "$SUBJECT" --home "$JG_HOME" --note "Main's session was restarted: $2." >/dev/null 2>&1 || true
}

session_live || exit 0
why='' key=''
read -r at ev rest < <(tail -n 1 "$BEAT_FILE" 2>/dev/null) || true
case ${at:-} in ''|*[!0-9]*) ;; *)
  case $ev in
    UserPromptSubmit|PostToolBatch) [ $(( NOW - at )) -lt "$BEAT_SECS" ] || { key=beat$at; why="no beat for $(( (NOW - at) / 60 )) minutes while a turn was running"; } ;;
  esac ;;
esac
if [ -z "$key" ]; then
  read -r seq age < <(oldest_wake) || true
  [ -z "${age:-}" ] || [ "$age" -lt "$WAKE_SECS" ] || { key=wake$seq; why="a wake waited $(( age / 60 )) minutes unacknowledged"; }
fi
if [ -n "$key" ]; then restart "$key" "$why"
else JG_STATE_OVERRIDE="$STATE" "$ALERT" resolve "supervision-down--$SUBJECT" >/dev/null 2>&1 || true; fi
exit 0

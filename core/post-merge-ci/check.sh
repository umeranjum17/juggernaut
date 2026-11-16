#!/usr/bin/env bash
# post-merge-ci watcher check: the alarm for the heavy behaviour suite on main runs by itself, so a red run is filed or matched
# within one tick of the run ending, with no hand step and no model turn.
# Usage: check.sh check <jg-home>
#
# Every JG_POST_MERGE_CI_MINUTES (config/post-merge-ci-minutes, default 10) it starts `bin/jg-post-merge-ci.sh --main` from the home,
# detached and one at a time (state/.post-merge-ci.lock), because the alarm downloads two runs' timing aggregates and a watcher check
# has seconds. The alarm owns the verdict (the verify's one rule, core/trunk-ci/run-rule.py), the filing and its alert; this check
# prints nothing, so a red run reaches the lead once, through the alarm's own line-red alert.
# config/post-merge-ci-restore holds one project directory: with it the alarm also pins the homes back when a run is red under the
# rule (see the alarm's header); without it nothing is ever restored. The alarm's lines go to data/jg-post-merge-ci/check.log.
set -u
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: check.sh check <jg-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
STATE=$FMH/state DATA=$FMH/data
ALARM=$FMH/bin/jg-post-merge-ci.sh
[ -x "$ALARM" ] || exit 0
MINUTES=$(cat "$FMH/config/post-merge-ci-minutes" 2>/dev/null | tr -dc 0-9); [ "${MINUTES:-0}" -gt 0 ] || MINUTES=${JG_POST_MERGE_CI_MINUTES:-10}
STAMP=$STATE/.post-merge-ci.last
if [ -f "$STAMP" ] && [ $(( $(date +%s) - $(stat -c %Y "$STAMP" 2>/dev/null || echo 0) )) -lt $(( MINUTES * 60 )) ]; then exit 0; fi
umask 077
mkdir -p "$DATA/jg-post-merge-ci" 2>/dev/null || exit 0
LOG=$DATA/jg-post-merge-ci/check.log
[ "$(cat "$LOG" 2>/dev/null | wc -l)" -le 2000 ] || { tail -n 500 "$LOG" > "$LOG.new" && mv "$LOG.new" "$LOG"; }
RESTORE=$(head -n 1 "$FMH/config/post-merge-ci-restore" 2>/dev/null | tr -d '\r')
touch "$STAMP"
cd "$FMH" || exit 0
# shellcheck disable=SC2086 # the optional restore flag is two words or none
JG_HOME="$FMH" JG_STATE_OVERRIDE="$STATE" JG_DATA_OVERRIDE="$DATA" setsid nohup flock -n "$STATE/.post-merge-ci.lock" \
  "$ALARM" --main ${RESTORE:+--restore "$RESTORE"} >> "$LOG" 2>&1 < /dev/null &
exit 0

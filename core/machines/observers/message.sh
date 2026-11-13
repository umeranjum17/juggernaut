#!/usr/bin/env bash
# message.sh - report-only observer of the message machine (core/machines/tables/message.tsv): one word per steer.
#
# Usage: message.sh <task>:<NNN>   print stored, rung, read, handled or failed; print nothing when the steer has no record
# The ladder markers (.ring-state, .busy-state, .escalated ...) are fields of the message, never states.
t=${1%%:*}; s=${1#*:}; case $s in ""|*[!0-9]*) exit 0;; esac
d=${JG_STATE_OVERRIDE:-${JG_HOME:?}/state}/$t.inbox
w=$(bash "${JG_HOME:?}/bin/jg-delivery.sh" show "$t" "$s" 2>/dev/null | head -1); [ -n "$w" ] || exit 0
h=${w##* handled=}; h=${h%% *}; f=${w##* failed=}; f=${f%% *}; r=${w##* rung=}; r=${r%% *}
if [ "$h" != no ] && { [ "$f" = no ] || [ "$h" -ge "$f" ]; }; then echo handled
elif [ "$f" != no ]; then echo failed
elif [ -e "$d/handled/$(printf %03d $((10#$s))).msg" ]; then echo read
elif [ "$r" != no ]; then echo rung
else echo stored; fi

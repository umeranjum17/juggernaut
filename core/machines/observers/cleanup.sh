#!/usr/bin/env bash
# cleanup.sh - report-only observer of the cleanup machine (core/machines/tables/cleanup.tsv): one word per lane cleanup, or per orphan temp entry.
#
# Usage: cleanup.sh <task>        print requested, checking, refused, removing or done; print nothing when no cleanup was asked for
#        cleanup.sh tmp:<name>    the same for one jg-* entry of the temp folder (JG_TMP_ROOT, else TMPDIR, else /tmp) that bin/jg-tmp-reaper.sh owns
# Records read, never written (the command only reads: it writes no record and runs no move):
#   state/<task>.backlog-close                  teardown passed its gates and its close is pending                       removing
#   state/.meta-<task>.lock/pid, a live pid     a teardown holds the task record                                           checking
#   data/jg-trunk-landing/<task>.<head>.state   the lander's line, which carries the outcome of the cleanup it asked for:
#                                               "landed cleanup refused, ..." refused; "landed cleaned up" done; any other "landed ..." requested
#   state/<task>.meta, the status log           no record and a status log, or "landed cleaned up", done
# The task record is checked after the pending close and the lock, so a refused lane that is checked again reads checking.
# A tmp entry is requested when it is older than JG_TMP_REAP_AGE_MIN minutes (default 120) and no task record names it, refused while a
# live process holds it (a working directory or an open file), and done when it is gone.
# Limits: a refusal of a teardown the lander did not ask for leaves no line, so the lane reads as it did before; the observer prints
# nothing for it rather than guess.
set -u
export LC_ALL=C
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); root=$(cd "$here/../../.." && pwd -P)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$root}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}; DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}; MEM=$DATA/jg-trunk-landing
id=${1:-}; [ -n "$id" ] || { echo "usage: cleanup.sh <task>|tmp:<name>" >&2; exit 2; }

if [[ $id == tmp:* ]]; then
  name=${id#tmp:}; tmp=${JG_TMP_ROOT:-${TMPDIR:-/tmp}}; tmp=${tmp%/}; p=$tmp/$name
  case $name in jg-*) ;; *) exit 0 ;; esac
  case $name in */*|*..*) exit 0 ;; esac
  if [ ! -e "$p" ] && [ ! -L "$p" ]; then echo "done"; exit 0; fi
  age=${JG_TMP_REAP_AGE_MIN:-120}; case $age in ''|*[!0-9]*) age=120 ;; esac
  [ -z "$(find "$p" -prune -mmin "-$age" 2>/dev/null)" ] || exit 0   # still young: nobody asked
  grep -qsF -- "$p" "$STATE"/*.meta && exit 0                         # a task record names it: not an orphan
  if [ -d /proc/self ] && { find /proc/[0-9]*/cwd /proc/[0-9]*/fd -maxdepth 1 -lname "$p*" 2>/dev/null | grep -q .; }; then echo refused; else echo requested; fi
  exit 0
fi

[[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || exit 0
[ ! -e "$STATE/$id.backlog-close" ] || { echo removing; exit 0; }
if [ -f "$STATE/$id.meta" ]; then
  pid=$(cat "$STATE/.meta-$id.lock/pid" 2>/dev/null || true)
  case $pid in ''|*[!0-9]*) ;; *) ! kill -0 "$pid" 2>/dev/null || { echo checking; exit 0; } ;; esac
fi
line=$(for f in "$MEM/$id".*.state; do [ -f "$f" ] && case ${f#"$MEM/$id".} in [0-9a-f]*.state) printf '%s\n' "$(sed -n 1p "$f")";; esac; done | grep '^landed' | sort | tail -n 1)
case $line in
  "landed cleanup refused"*) [ ! -f "$STATE/$id.meta" ] || { echo refused; exit 0; } ;;
esac
if [ ! -f "$STATE/$id.meta" ]; then
  { [ -s "$STATE/$id.status" ] || [ -n "$line" ]; } && echo "done"
  exit 0
fi
case $line in
  "landed cleaned up"*) echo "done" ;;
  landed*) echo requested ;;
esac
exit 0

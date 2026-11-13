#!/usr/bin/env bash
# jg-run-owned.sh - start a process that has an owner and a time limit, so core/tmp-reaper/proc.sh can end it.
# Usage: jg-run-owned.sh --owner <ticket-or-tick-name> --limit <seconds> [--owner-pid <pid>|none] -- <command> [args...]
#
# It writes one owner record, state/owned-procs/<pid>.rec, and then execs the command, so the recorded pid IS the
# command. The command runs in its own process group when it can (setsid), so the reaper ends its children with it.
# The owner is the process that called this wrapper (--owner-pid overrides). `--owner-pid none` is for a tick, which
# exits right after it starts the process: the limit alone ends such a process.
# The reaper ends the process when the limit has passed or the owner pid is gone, and never a process with no record.
# Exit 2 is a usage error. A record that cannot be written stops the start: an unowned process is never started.
set -u
usage() { echo "usage: jg-run-owned.sh --owner <name> --limit <seconds> [--owner-pid <pid>|none] -- <command> [args...]" >&2; exit 2; }
owner="" limit="" opid=$PPID
while [ "$#" -gt 0 ]; do
  case $1 in
    --owner) [ "$#" -ge 2 ] || usage; owner=$2; shift 2 ;;
    --limit) [ "$#" -ge 2 ] || usage; limit=$2; shift 2 ;;
    --owner-pid) [ "$#" -ge 2 ] || usage; opid=$2; shift 2 ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
[ "$#" -gt 0 ] || usage
[[ $owner =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] || { echo "jg-run-owned: --owner must be a ticket or tick name" >&2; exit 2; }
[[ $limit =~ ^[1-9][0-9]*$ ]] || { echo "jg-run-owned: --limit must be a whole number of seconds, above 0" >&2; exit 2; }
[[ $opid =~ ^([0-9]+|none)$ ]] || { echo "jg-run-owned: --owner-pid must be a pid or none" >&2; exit 2; }
_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
STATE=${JG_STATE_OVERRIDE:-${JG_HOME:-$_root}/state}
DIR=$STATE/owned-procs
# The start time of a pid (field 22 of /proc/<pid>/stat) tells a reused pid from the process the record names.
# shellcheck disable=SC2086
start_of() { local s; s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1; s=${s##*) }; set -- $s; printf '%s' "${20}"; }
mine=$(start_of $$) || { echo "jg-run-owned: /proc is not readable; no process is started without a record" >&2; exit 1; }
ostart=none
if [ "$opid" != none ]; then ostart=$(start_of "$opid") || { echo "jg-run-owned: owner pid $opid is not running" >&2; exit 1; }; fi
write_record() {
  mkdir -p "$DIR" || return 1
  printf 'pid=%s\nstart=%s\nowner=%s\nowner_pid=%s\nowner_start=%s\nlimit_sec=%s\nstarted=%s\n' \
    "$$" "$mine" "$owner" "$opid" "$ostart" "$limit" "$(date +%s)" > "$DIR/$$.rec.tmp" || return 1
  mv -f -- "$DIR/$$.rec.tmp" "$DIR/$$.rec"
}
write_record || { echo "jg-run-owned: cannot write the owner record in $DIR" >&2; exit 1; }
# setsid execs in place unless this process leads its group; then it would fork and the recorded pid would be wrong.
if [ "$(ps -o pgid= -p $$ | tr -d ' ')" != "$$" ] && command -v setsid >/dev/null 2>&1; then exec setsid "$@"; fi
exec "$@"

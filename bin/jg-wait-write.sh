#!/usr/bin/env bash
# jg-wait-write.sh - write a typed wait to a status log, or resolve one, through the one writer (bin/jg-wait-write-lib.sh).
#
# Usage:
#   jg-wait-write.sh open <status-file> pause --who <who> --reason <reason> [--key <key>] [--until <YYYY-MM-DDTHH:MMZ>] -- <text>
#   jg-wait-write.sh open <status-file> decision [--key <key>] -- <text>
#   jg-wait-write.sh open <status-file> owner-call --task <task> [--key <key>] -- <text>
#   jg-wait-write.sh resolve <status-file> [--key <key>] [--self-announced <state-dir>] -- <text>
#
# A wait opens once and closes once: opening a key that is open, or resolving one that is not, writes nothing and prints
# `already open: <key>` or `already resolved: <key>`. An owner call is closed only by its own resolve; a done, a failed
# or a restated key leaves it open (core/classify). Exit 0 written or already so, 1 refused (nothing written), 2 usage.
set -u
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/jg-classify-lib.sh
. "$SCRIPT_DIR/jg-classify-lib.sh"
# shellcheck source=bin/jg-wait-write-lib.sh
. "$SCRIPT_DIR/jg-wait-write-lib.sh"
usage() { sed -n '3,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ $# -ge 3 ] || usage
op=$1 file=$2; shift 2
kind='' who='' reason='' key=- until_at='' task='' state=- text=''
if [ "$op" = open ]; then kind=$1; shift; fi
while [ $# -gt 0 ]; do
  case $1 in
    --who) who=${2:-}; shift 2 ;; --reason) reason=${2:-}; shift 2 ;; --key) key=${2:-}; shift 2 ;;
    --until) until_at=${2:-}; shift 2 ;; --task) task=${2:-}; shift 2 ;; --self-announced) state=${2:-}; shift 2 ;;
    --) shift; text=$*; break ;;
    *) usage ;;
  esac
done
[ -n "$text" ] || usage
case $op in
  open)
    [ -z "$until_at" ] || text="$text until $until_at"
    case $kind in pause) jg_wait_open "$file" pause "$key" "$text" "$who" "$reason" ;; owner-call) jg_wait_open "$file" owner-call "$key" "$text" "$task" ;; *) jg_wait_open "$file" "$kind" "$key" "$text" ;; esac ;;
  resolve)
    if [ "$state" != - ]; then
      # shellcheck source=bin/jg-wake-lib.sh
      . "$SCRIPT_DIR/jg-wake-lib.sh"
    fi
    jg_wait_resolve "$state" "$file" "$key" "$text"; rc=$?
    [ "$rc" -le 1 ] || exit 1 ;;
  *) usage ;;
esac

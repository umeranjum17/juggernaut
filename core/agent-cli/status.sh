#!/usr/bin/env bash
# jg status: the ticket, its stage, the wait and the unread steers, then the next step.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
jg_cli_context
if [ "${1:-}" = write ]; then
  shift
  state=${1:-}; shift || true
  case "$state" in blocked|failed) ;; *) jg_cli_die "usage: jg status write <blocked|failed> [--key <key>] <text>" ;; esac
  key=''
  if [ "${1:-}" = --key ]; then
    key=${2:-}; [ -n "$key" ] || jg_cli_die "--key needs a key"
    case "$key" in *[!a-zA-Z0-9._-]*) jg_cli_die "invalid key: $key" ;; esac
    shift 2
  fi
  [ "$#" -gt 0 ] && [ -n "$*" ] || jg_cli_die "status text is required"
  case "$*" in *$'\n'*) jg_cli_die "status text must be one line" ;; esac
  if [ -n "$key" ]; then jg_cli_status_append "$state" "$*" "key=$key" || exit 1
  else jg_cli_status_append "$state" "$*" || exit 1; fi
  echo "$state recorded for $JG_CLI_TASK. Next: stop"
  exit 0
fi
statusf=$JG_CLI_STATE/$JG_CLI_TASK.status
last=''; [ -s "$statusf" ] && last=$(tail -n1 "$statusf")
stage=$(JG_CREW_STATE_NO_FORGE=1 timeout 30 "$JG_CLI_TOOLS/bin/jg-crew-state.sh" "$JG_CLI_TASK" 2>&1 | head -n1)
n=$(jg_cli_unread | grep -c .)
case "$last" in paused*|blocked*) wait=$last ;; *) wait=none ;; esac
printf 'ticket: %s · %s · %s · branch %s\n' "$JG_CLI_TASK" "$(jg_cli_meta_get kind)" "$(jg_cli_meta_get mode)" "$(jg_cli_meta_get branch)"
printf 'stage: %s\n' "${stage:-state: unknown}"
printf 'last: %s\n' "${last:-none}"
printf 'wait: %s\n' "$wait"
printf 'inbox: %s unread\n' "$n"
if [ "$n" -gt 0 ]; then echo "Next: jg inbox"
elif [ "$wait" != none ]; then echo "Next: jg progress <text> when the wait clears"
else echo "Next: keep working; jg done when ready"; fi

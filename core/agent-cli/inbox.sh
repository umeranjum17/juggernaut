#!/usr/bin/env bash
# jg inbox                                  print each unread steer in numeric order
# jg inbox ack <NNN> [--evidence <kind>:<pointer>]
#                                           move the steer to handled/ (the acknowledgement); with
#                                           --evidence also say it was acted on (bin/jg-delivery.sh)
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
jg_cli_context
dir=$JG_CLI_STATE/$JG_CLI_TASK.inbox
case "${1:-}" in
  '')
    unread=$(jg_cli_unread)
    if [ -z "$unread" ]; then echo "inbox: 0 unread. Next: continue the task"; exit 0; fi
    while IFS= read -r f; do printf '== %s ==\n' "$(basename "$f" .msg)"; cat "$f"; echo; done <<< "$unread"
    echo "Next: act on each, then jg inbox ack <NNN> --evidence <status|commit|reply|task|pr>:<pointer>"
    ;;
  ack)
    n=${2:-}; ev=''
    case "$n" in ''|*[!0-9]*) jg_cli_die "usage: jg inbox ack <NNN> [--evidence <kind>:<pointer>]" ;; esac
    if [ "${3:-}" = --evidence ]; then ev=${4:-}; [ -n "$ev" ] || jg_cli_die "--evidence needs <kind>:<pointer>"; fi
    f=$(printf '%s/%03d.msg' "$dir" "$((10#$n))")
    [ -f "$f" ] || jg_cli_die "no unread steer $n in $dir"
    mkdir -p "$dir/handled" && mv -- "$f" "$dir/handled/" || exit 1
    [ -z "$ev" ] || "$JG_CLI_TOOLS/bin/jg-delivery.sh" handled "$JG_CLI_TASK" "$((10#$n))" --evidence "$ev" || exit 1
    echo "steer $n acknowledged${ev:+ and recorded handled}. Next: jg inbox"
    ;;
  *) jg_cli_die "usage: jg inbox [ack <NNN> [--evidence <kind>:<pointer>]]" ;;
esac

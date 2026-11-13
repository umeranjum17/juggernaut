#!/usr/bin/env bash
# jg alert [list]                  the live alerts that name this ticket (a lead adds --home: every live alert of the home)
# jg alert ack <key> [--home]      acknowledge one: the alert machine's open -> acknowledged move
# The alert table, the records and the moves belong to bin/jg-alert.sh; this verb only finds the
# records that name the caller and calls it.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
jg_cli_context
ALERT=$JG_CLI_TOOLS/bin/jg-alert.sh
usage='usage: jg alert [list] [--home] | jg alert ack <key> [--home]'
verb=list; scope=ticket; key=''
while [ $# -gt 0 ]; do
  case $1 in
    list) verb=list ;;
    ack) verb=ack; key=${2:-}; [ -n "$key" ] || jg_cli_die "$usage"; shift ;;
    --home) scope=home ;;
    *) jg_cli_die "$usage" ;;
  esac
  shift
done

rec_field() { "$ALERT" show "$1" 2>/dev/null | sed -n "s/^$2=//p" | head -n1; }
names_me() {  # 0 when the alert's ticket or subject is this ticket, or the scope is the home
  [ "$scope" = home ] && return 0
  [ "$(rec_field "$1" ticket)" = "$JG_CLI_TASK" ] || [ "$(rec_field "$1" subject)" = "$JG_CLI_TASK" ]
}

case $verb in
  list)
    rows=''; n=0
    for k in $("$ALERT" list); do
      names_me "$k" || continue
      n=$((n + 1))
      rows="$rows$k	$(rec_field "$k" state)	$(rec_field "$k" precedence)	rung $(rec_field "$k" rung)	$(rec_field "$k" note)
"
    done
    echo "alerts: $n"
    [ -z "$rows" ] || printf '%s' "$rows"
    if [ "$n" -gt 0 ]; then echo "Next: jg alert ack <key> once you act on it"
    else echo "Next: continue the task"; fi
    ;;
  ack)
    names_me "$key" || jg_cli_die "alert $key does not name $JG_CLI_TASK. Next: jg alert list"
    "$ALERT" ack "$key" || exit 1
    echo "alert $key acknowledged. Next: jg alert"
    ;;
esac

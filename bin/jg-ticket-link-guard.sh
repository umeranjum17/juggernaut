#!/usr/bin/env bash
# jg-ticket-link-guard.sh - refuse a captain-facing reply that names no ticket,
# and name the one-line fix.
#
# Usage: jg-ticket-link-guard.sh [<text>...]
#
# Reads the proposed reply from its arguments, or from stdin when it has none,
# and exits 1 when it names no ticket link, with one refusal line on stderr:
#
#   owner-rules: captain reply without a ticket link refused; add #tickets/<id> (bin/jg-ticket.sh id <task-id> prints <id>)
#
# It accepts one form, the board deep link the captain can open:
#   #tickets/<id>     bare, or inside the full board URL bin/jg-board-link.sh
#                     builds from it before the message is sent.
# <id> is the ticket core/tickets-sync publishes for the work, and
# bin/jg-ticket.sh id <task-id> prints it. Everything else exits 0. A grep or
# read error keeps its own diagnostics and exit code, so a broken check never
# passes a reply as clean. This is a text guard: it reads the words, never the
# command.
#
# This file is the one core owner of the rule "every captain reply carries the
# ticket link" (data/owner-rules.md). bin/jg-squad-lead-report.sh runs it before
# a parent-channel append, and bin/jg-branch-report.sh runs it before a captain
# outcome is stored, so neither a mate's report nor a captain outcome reaches
# the captain with no ticket behind it.
set -u

pattern='#tickets/[A-Za-z0-9][A-Za-z0-9._-]*'

if [ "$#" -gt 0 ]; then
  text=$(printf '%s\n' "$*")
else
  text=$(cat)
fi
grep_rc=0
printf '%s\n' "$text" | grep -Eq -- "$pattern" || grep_rc=$?
case "$grep_rc" in
  0) ;;
  1)
    echo 'owner-rules: captain reply without a ticket link refused; add #tickets/<id> (bin/jg-ticket.sh id <task-id> prints <id>)' >&2
    exit 1
    ;;
  *) exit "$grep_rc" ;;
esac
exit 0

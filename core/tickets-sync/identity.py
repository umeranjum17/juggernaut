#!/usr/bin/env python3
"""Which board ticket a backlog row is: the one rule the poll, the stale check and the lifecycle writer share.

A row's ticket is `jg-` and the first 32 hex characters of sha256("<home>/<item>"), where <home> is the name the fleet
registry gives the home that holds the row. The Beads cut kept the board's ticket ids: a migrated row's store id is the
ticket it was published as (`jg-<hex>`, or `fm-<hex>` from before the poll re-keyed its ids), so a row whose id is a
ticket id is that ticket, whichever home holds it now. Hashing such a row again named a ticket the board never had,
so the board's real ticket was never written ("ticket says no state").

A lead home (`.jg-squad-lead-home` names it) is not `main`: its rows are published as <lead>/<item> by its parent's
poll, which reads every registered home, so the lead runs no poll of its own on the shared board.

Usage: identity.py <task> [home] prints the ticket id of <task> in the home the registry calls [home], by default the
one JG_HOME is.
"""
import hashlib
import os
from pathlib import Path
import re
import sys

TICKET = re.compile(r'(?:jg|fm)-([0-9a-f]{32})')
LEAD_MARKER = '.jg-squad-lead-home'


def home_name(home):
    """The registry's name for this home: the lead id its marker names, else main."""
    marker = Path(home) / LEAD_MARKER
    name = marker.read_text().strip() if marker.is_file() else ''
    return name or 'main'


def is_lead(home):
    return home_name(home) != 'main'


def ticket_id(home, item, row_id=''):
    """The ticket of row `item` (store id `row_id`) in the home the registry calls `home`."""
    kept = TICKET.fullmatch(row_id or item)
    if kept: return 'jg-' + kept[1]
    return 'jg-' + hashlib.sha256(f'{home}/{item}'.encode()).hexdigest()[:32]


if __name__ == '__main__':
    if not 2 <= len(sys.argv) <= 3: sys.exit('usage: identity.py <task> [home]')
    print(ticket_id(sys.argv[2] if len(sys.argv) == 3 else home_name(os.environ.get('JG_HOME') or '.'), sys.argv[1]))

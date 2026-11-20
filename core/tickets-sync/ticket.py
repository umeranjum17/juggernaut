#!/usr/bin/env python3
"""Record one task's ticket truth on the fleet board now, from a lifecycle step.

Usage: ticket.py <task> [--state WORD] [--pr URL] [--release TEXT] [--hold-reason TEXT]

JG_HOME names the home whose config/fleet-board owns this task, and the task is
its backlog item id, published as the ticket identity.py names for it in this
home: main/<task> in main, <lead>/<task> in a lead home, and the ticket itself
for a migrated row whose id is one (bin/jg-watch.sh's check environment included).

Nothing is written: the board reads every row from the tickets tables, which the
lifecycle step has already written, so the call checks its arguments and exits 0.
"""
import argparse
import sys
import os
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves here
for _jg_old, _jg_val in list(os.environ.items()):
    if _jg_old.startswith("FM_") and "JG_" + _jg_old[3:] not in os.environ:
        os.environ["JG_" + _jg_old[3:]] = _jg_val

STATES = ('queued', 'in progress', 'on hold', 'done')


def die(message):
    print('ticket: ' + message, file=sys.stderr)
    return 1


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('task')
    parser.add_argument('--state', choices=STATES)
    parser.add_argument('--pr', default=None, help='the delivered PR URL, or "" to clear it')
    parser.add_argument('--release', default=None, help='the target release, up to 40 characters')
    parser.add_argument('--hold-reason', default=None, help='why an `on hold` state waits')
    options = parser.parse_args(argv)
    if not options.task or '/' in options.task:
        return die('task must be one backlog item id')
    if (options.state, options.pr, options.release, options.hold_reason) == (None, None, None, None, None):
        return die('nothing to record: pass --state, --pr, --hold-reason or --release')
    # The board reads every row from the tickets tables, and lifecycle callers have already written that row.
    # Never send removed feed fields back through the adapter or create a duplicate store row.
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

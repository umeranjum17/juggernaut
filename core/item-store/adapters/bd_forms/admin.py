"""bd_forms/admin.py: the `admin` family of bd calls, answered from the ticket tables (fleet.db) in mode `tables`.

  run(argv, stdin_text) -> (stdout_text, exit_status)

Forms (bd-forms.tsv, family admin): heartbeat, which bin/jg-beads-lease.py sends. Nothing here changes a table: the call
prints what bd printed for the recorded call. Any other form raises NotSupported. Python stdlib only."""
import os, sys

ADAPTERS = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
sys.path.insert(0, ADAPTERS)
import tickets  # noqa: E402
import itemdb  # noqa: E402  (tickets.py put the store folder on the path)


class NotSupported(Exception):
    """A form this module does not answer."""


def heartbeat(args):
    if len(args) != 1 or args[0].startswith("-"):
        raise NotSupported("heartbeat")
    h = tickets.home()
    row = itemdb.open_db(h, tickets.BY).con.execute(
        "SELECT title FROM ticket WHERE home = ? AND id = ?", (itemdb.home_id(h), args[0])).fetchone()
    if not row:
        raise NotSupported("heartbeat: no such ticket")
    return "✓ Heartbeat %s — %s (lease refreshed)\n" % (args[0], row[0]), 0


def run(argv, stdin_text):
    verb, args = (argv[0] if argv else ""), argv[1:]
    if verb != "heartbeat":
        raise NotSupported(verb)
    return heartbeat(args)

"""bd_forms/admin.py: the `admin` family of bd calls, answered from the ticket tables (fleet.db) in mode `tables`.

  run(argv, stdin_text) -> (stdout_text, exit_status)

Forms (bd-forms.tsv, family admin): init, backup init, backup restore --force, backup sync, heartbeat, serve, dolt.
Also check (tickets.py check) and config set, which the dispatcher routes here. Nothing here changes a table: the calls
print what bd printed for the recorded call. `init` prints bd's nothing on stdout and one line naming the tables on stderr.
`dolt` exits 2 with `Beads is retired: no dolt`. A form bd_forms does not know (import and remember are the create
family's, a flag or argument count never recorded) raises NotSupported. Python stdlib only."""
import os, sys

ADAPTERS = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
sys.path.insert(0, ADAPTERS)
import tickets  # noqa: E402
import itemdb  # noqa: E402  (tickets.py put the store folder on the path)

INIT_USAGE = "jg-beads: usage: jg-beads.sh init --prefix <prefix>\n"


class NotSupported(Exception):
    """A form this module does not answer."""


def init(args):
    if len(args) == 2 and args[0] == "--prefix" and not args[1].startswith("-"):
        sys.stderr.write("bd init: the tickets tables in fleet.db are the store; nothing to create\n")
        return "", 0
    if "--prefix" in args:                      # --force, --server and the rest: bin/jg-beads.sh refused them
        sys.stderr.write(INIT_USAGE)
        return "", 2
    raise NotSupported("init")


def check(args):
    if args:
        raise NotSupported("check")
    h = tickets.home()
    fault, n = tickets.check_fault(itemdb.open_db(h, tickets.BY).con, itemdb.home_id(h))
    return ("tickets: %s\n" % fault, 2) if fault else ("tickets: ok (%d rows)\n" % n, 0)


def config_set(args):
    if len(args) != 2 or any(a.startswith("-") for a in args):
        raise NotSupported("config set")
    return "Set %s = %s (in config.yaml)\n" % (args[0], args[1]), 0


def backup(args):
    if len(args) == 2 and args[0] == "init" and not args[1].startswith("-"):
        return "Backup destination configured: file://%s\nRun 'bd backup sync' to push your data.\n" % args[1], 0
    if len(args) == 3 and args[0] == "restore" and args[2] == "--force" and not args[1].startswith("-"):
        return "\n✓ Restore complete\n", 0
    if args == ["sync"]:
        return "\nBackup synced in 83ms\n", 0
    raise NotSupported("backup")


def heartbeat(args):
    if len(args) != 1 or args[0].startswith("-"):
        raise NotSupported("heartbeat")
    h = tickets.home()
    row = itemdb.open_db(h, tickets.BY).con.execute(
        "SELECT title FROM ticket WHERE home = ? AND id = ?", (itemdb.home_id(h), args[0])).fetchone()
    if not row:
        raise NotSupported("heartbeat: no such ticket")
    return "✓ Heartbeat %s — %s (lease refreshed)\n" % (args[0], row[0]), 0


def serve(args):
    if args:
        raise NotSupported("serve")
    return "", 2


def dolt(args):
    sys.stderr.write("Beads is retired: no dolt\n")
    return "", 2


def run(argv, stdin_text):
    verb, args = (argv[0] if argv else ""), argv[1:]
    if verb == "config" and args[:1] == ["set"]:
        return config_set(args[1:])
    handler = {"init": init, "check": check, "backup": backup, "heartbeat": heartbeat, "serve": serve, "dolt": dolt}.get(verb)
    if not handler:
        raise NotSupported(verb)
    return handler(args)

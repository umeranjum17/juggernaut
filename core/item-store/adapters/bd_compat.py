#!/usr/bin/env python3
"""bd_compat.py <bd verb> [args...]: answer a `bd` call from the tickets tables in fleet.db, the one mode (`tables`).
Load bd_forms/<family>.py by its path and call run(argv, stdin_text) -> (stdout_text, exit_status); it may raise NotSupported.
`--mode` prints the mode. Exit 2: form not supported; exit 1: any other error. Python stdlib only."""
import importlib.util, os, sys

HERE = os.path.dirname(os.path.realpath(__file__))
STORE = os.path.dirname(HERE)
sys.path.insert(0, STORE)
import itemdb  # noqa: E402

TWO_WORD = {"dep", "gate", "label", "config", "backup", "comments", "swarm"}
FAMILIES = {
    "read": "show list ready blocked export history comments events provenance q types statuses schema memories epic swarm-validate gate-list".split(),
    "create": "create comment comments-add import remember gate-create".split(),
    "update": ["update", "gate-resolve"],
    "link": "close delete defer undefer dep-add dep-remove label-add label-remove".split(),
    "admin": "init check serve heartbeat config-set backup-init backup-restore backup-sync".split(),
}
FAMILY_OF = {verb: fam for fam, verbs in FAMILIES.items() for verb in verbs}


class NotSupported(Exception):
    """A family module raises this for a form it does not answer (a module may define its own of the same name)."""


def verb_of(argv):
    """The verb: the first word, or the first two when the first is one of TWO_WORD (`comments <id>` and `swarm <word>` are
    two words only when the pair is a verb of its own: comments add, swarm validate)."""
    if argv and argv[0] in TWO_WORD and len(argv) > 1 and (argv[0] not in ("comments", "swarm") or argv[0] + "-" + argv[1] in FAMILY_OF):
        return argv[0] + "-" + argv[1]
    return argv[0] if argv else ""


def flags_of(argv):
    return " ".join(sorted({a.split("=", 1)[0] for a in argv if a.startswith("-") and a != "-"}))


def unsupported(argv):
    sys.stderr.write("bd_compat: form not supported: %s\n" % " ".join(w for w in (verb_of(argv).replace("-", " "), flags_of(argv)) if w))
    return 2


def run_tables(argv):
    if argv[:1] == ["--readonly"]:      # bd's global flag in front of the verb: the call is the rest
        argv = argv[1:]
    verb = verb_of(argv)
    family = FAMILY_OF.get(verb)
    path = os.path.join(HERE, "bd_forms", "%s.py" % family) if family else ""
    if not family or not os.path.isfile(path):
        return unsupported(argv)
    sys.modules.setdefault("bd_compat", sys.modules[__name__])
    spec = importlib.util.spec_from_file_location("bd_forms_" + family, path)
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
        out, status = module.run(argv, sys.stdin.read() if takes_stdin(argv) else "")
    except Exception as e:  # noqa: BLE001 - NotSupported may come from the module's own class
        if type(e).__name__ == "NotSupported":
            return unsupported(argv)
        sys.stderr.write("bd_compat: %s\n" % (str(e).splitlines() or [type(e).__name__])[0])
        return 1
    sys.stdout.write(out)
    sys.stdout.flush()
    return status


def takes_stdin(argv):
    """Only a form that names stdin (`-` as a file or body, or `--stdin`) reads it: a read on an open pipe or socket would wait for a writer that never ends."""
    return "-" in argv or "--stdin" in argv


def main(argv):
    if argv == ["--mode"]:
        print("tables")
        return 0
    return run_tables(argv)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, itemdb.Unbound) as e:
        sys.stderr.write("bd_compat: %s\n" % (str(e).splitlines() or [type(e).__name__])[0])
        sys.exit(1)

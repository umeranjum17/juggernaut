"""Reads the wake routing rule table to say which class a past notification row had.

The table is `defaults/wake-routing` (a home's `config/wake-routing` or `JG_WAKE_ROUTING`
replaces it): one rule per line, `<class> <kind> <key-glob> <payload-glob>`, first match
wins, no match means `now`. The router in core/wake decides live; this reads the same text
over history. A rule with an `@condition` reads live state, so it is skipped here: the class
of a row is the table's reading, not the router's decision at that minute.
"""
import fnmatch
import os


def routing_file(home, repo, override=None):
    """The rule table in force: the explicit file, else JG_WAKE_ROUTING, else the home's, else the repo's."""
    if override:
        return override
    env = os.environ.get('JG_WAKE_ROUTING')
    if env:
        return env
    local = os.path.join(home, 'config', 'wake-routing')
    return local if os.path.isfile(local) else os.path.join(repo, 'defaults', 'wake-routing')


def load_rules(path):
    """[(class, kind, key glob, payload glob)] without the conditional rules; None when the file is absent."""
    if not os.path.isfile(path):
        return None
    rules = []
    with open(path, errors='replace') as table:
        for line in table:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            fields = line.split(None, 3)
            if fields[0] != 'set' and len(fields) == 4 and '@' not in fields[0]:
                rules.append(tuple(fields))
    return rules


def route(rules, kind, key, payload):
    for klass, rule_kind, key_glob, payload_glob in rules:
        if rule_kind in ('*', kind) and fnmatch.fnmatchcase(key, key_glob) \
                and fnmatch.fnmatchcase(payload, payload_glob):
            return klass
    return 'now'

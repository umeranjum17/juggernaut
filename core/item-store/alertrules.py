#!/usr/bin/env python3
"""The alert ladder's rules, read from the store's views (core/item-store/schema.sql: alert_kind, alert_text, alert_ladder, alert_limit,
alert_rule, alert_authority, alert_security_source). They replaced the alert table. The rules are the ones shipped in schema.sql, read from
a fresh in-memory store, so no host file and no config is needed.

  alertrules.py dump      every rule, one tab-separated line each, in the shape bin/jg-alert.sh reads:
    alert  name, fires on, fires at, precedence, first rung, quiet when
    rule   id, covers, scope, quieted, why
    ladder precedence, step s, repeat s, top, lift fact, repeats at the top
    limit  kind, seconds, (why is not kept)
    authority class, ceiling       security-source source
As a module: rows(kind), names(), chain(alert) (who is told first, next, and whether a board card reaches the owner)."""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [HERE]
from store import Store

HOLDERS = ["the tick", "the worker", "the lead", "Main", "the owner"]
_QUERIES = (
    ("alert", "SELECT k.alert, t.fires_on, k.fires_at, k.precedence, k.first_rung, t.quiet_when FROM alert_kind k JOIN alert_text t USING (alert)"),
    ("rule", "SELECT id, covers, scope, quieted, why FROM alert_rule"),
    ("ladder", "SELECT precedence, step_s, repeat_s, top, lift, repeats_at_top FROM alert_ladder"),
    ("limit", "SELECT kind, limit_s FROM alert_limit"),
    ("authority", "SELECT class, ceiling FROM alert_authority"),
    ("security-source", "SELECT source FROM alert_security_source"),
)
_cache = []


def _all():
    if not _cache:
        con = Store(":memory:").con
        _cache.append([(kind, [str(v) for v in r]) for kind, sql in _QUERIES for r in con.execute(sql)])
    return _cache[0]


def rows(kind):
    """The rows of one kind, each as a list of fields."""
    return [r for k, r in _all() if k == kind]


def names():
    return [r[0] for r in rows("alert")]


def chain(alert):
    """(first, then, board card) of one alert: the holder of its first rung, the holder one rung up (or -), and whether the owner's card is reached."""
    prec, first = next((r[3], r[4]) for r in rows("alert") if r[0] == alert)
    top = next(r[3] for r in rows("ladder") if r[0] == prec)
    cls = "security-awareness" if alert == "security" else "team-action"
    ceiling = int(next(r[1] for r in rows("authority") if r[0] == cls))
    card = "yes" if ceiling == 4 else "when a matching owner gate is open"
    if first == "wait":
        return "the one the wait names", "one rung up", card
    start = int(first)
    top = min(start + 2, 3) if top == "start+2" else int(top)
    top = min(top, ceiling)
    return HOLDERS[start], HOLDERS[start + 1] if top > start else "-", card


if __name__ == "__main__":
    if sys.argv[1:] != ["dump"]:
        sys.exit("usage: alertrules.py dump")
    for kind, r in _all():
        print("\t".join([kind] + r))

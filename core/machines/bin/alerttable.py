"""The alert table (core/machines/styles/alert-table.tsv, read by bin/jg-alert.sh) as the table engine needs it: which alerts exist, and who is
told first, who next, and whether a board card reaches the owner when a waiting state's timeout passes (section 6.7 of the state-machine plan).
"""
import os

HOLDERS = ["the tick", "the worker", "the lead", "Main", "the owner"]
HERE = os.path.dirname(os.path.abspath(__file__))


def rows(kind):
    path = os.environ.get("JG_ALERT_TABLE") or os.path.join(HERE, "..", "styles", "alert-table.tsv")
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError as e:
        raise SystemExit(f"jg-machine: no alert table at {path}: {e.strerror}")
    return [ln.split("\t") for ln in lines if ln.startswith(kind + "\t")]


def names():
    return [r[1] for r in rows("alert")]


def chain(alert):
    """(first, then, board card) of one alert: the holder of its first rung, the holder one rung up (or -), and whether the owner's card is reached."""
    row = next(r for r in rows("alert") if r[1] == alert)
    prec, first = row[4], row[5]
    top, lift = next((r[4], r[5]) for r in rows("ladder") if r[1] == prec)
    card = "yes" if top == "4" else ("when " + lift if lift != "-" else "never")
    if first == "wait":
        return "the one the wait names", "one rung up", card
    start = int(first)
    top = min(start + 2, 3) if top == "start+2" else int(top)
    return HOLDERS[start], HOLDERS[start + 1] if top > start else "-", card


def of(s):
    """The alert a state's timeout names: the one in its alert column, else the one its limit says; empty for none."""
    limit = s.get("limit", "")
    return s.get("alert", "") if s.get("alert", "") not in ("", "-") else (limit.split(" -> alert ", 1)[1] if " -> alert " in limit else "")

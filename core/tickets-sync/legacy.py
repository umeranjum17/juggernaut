"""One-off migration of the legacy `fm-` rows that hold with no reason.

Before the poll re-keyed its ids, it published every ticket as `fm-<hash>`; it now publishes `jg-<hash>`. A legacy row
the board still shows as held, with no reason, is one the poll no longer moves, and the board refuses a hold with no
reason, so nothing else will ever clear it. Each such row is released, never closed: a close would count as work shipped
today, and a captain ask is never closed on the board's own word. Only the hold and the "on hold" state it implies move,
so the board derives the row's state from its progress as for any unheld row; the title, where a captain's quote lives,
the description, the stage and the progress stay as they are. Closing the duplicates that remain is the fleet-wide
clean-up's call.
"""


def stuck(record):
    """True for a legacy row (a feed record) that is still open, held and has no reason."""
    return (record['id'].startswith('fm-') and record.get('hold') and not record.get('hold_reason')
            and (record.get('state') or '') != 'done')


def released(record):
    """The fields that release a stuck row: no hold, and no explicit "on hold" state (an empty value takes a field off)."""
    return dict(hold='no', **({'state': ''} if record.get('state') == 'on hold' else {}))


def migrate(records, unhold, write=True):
    """Release every stuck row through `unhold(record)`; return the summary line. With write off, only name them."""
    rows = [r for r in records if stuck(r)]
    for record in rows:
        if write: unhold(record)
        print(f"{record['id']}: {' '.join(str(record.get('title')).split())[:70]}")
    return f"tickets-sync: {'released' if write else 'would release'} {len(rows)} legacy rows held with no reason"

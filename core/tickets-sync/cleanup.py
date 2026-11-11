"""The daily ticket clean-up: close what is settled, flag the rest and keep every captain quote.

The rule, in one place: a ticket that is closed-unmerged work (every pull request it delivers through was closed
without a merge), a duplicate (same title as an earlier ticket in its home) or superseded is closed with that
reason recorded in its note, unless it still holds an owner decision (owner_decision below). The clean-up never
closes such a ticket; it stays flagged for the captain.
"""
import datetime as dt
import json
import os
import re
import subprocess as sp
from pathlib import Path
from hierarchy import field, title as request_title
from lane import delivery_urls
import reconcile

STALE_DAYS = 14
CLOSES = ('closed-unmerged', 'duplicate', 'superseded')


def report_message(found, kinds, key, today, closed=()):
    """The clean-up's board card: a report, never an ask.

    A flagged ticket is not one of the captain's six must categories, so the pass
    reports what it found and Main keeps or removes each ticket. A report takes no
    answer, which is what keeps the card off the ask gate: an ask with no must
    category is routed to Overwatch and re-alerted on, forever. Schema 3 is the
    guided report the board draws itself, so no page is written here.
    """
    count = len(found)
    summary = ', '.join(f'{n} {k}' for k, n in sorted(kinds.items())) or 'none'
    shut = {}
    for kind, *_ in closed: shut[kind] = shut.get(kind, 0) + 1
    rows = [dict(label=f'closed {k}', value=n, note='closed', tone='ok') for k, n in sorted(shut.items())]
    rows += [dict(label=k, value=n, note='flagged', tone='warn') for k, n in sorted(kinds.items(), key=lambda kv: (-kv[1], kv[0]))]
    rows = rows[:8]
    while len(rows) < 2: rows.append(dict(label='none', value=0, note='none', tone='ok'))
    return {
        'contract': 1, 'kind': 'report', 'schema': 3, 'filer': 'tickets-cleanup',
        'key': key, 'purpose': 'status', 'project': 'Fleet', 'group': 'Ticket clean-up',
        'filed': dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'title': f'The daily clean-up closed {len(closed)} and flagged {count} tickets' if closed else f'The daily clean-up flagged {count} tickets',
        'about': (f'{len(closed)} settled tickets are closed with their reason recorded. ' if closed else '')
                 + f'{count} tickets are flagged: {summary}. A ticket that holds your decision is never closed. Every captain quote stays.',
        'understood': [
            {'label': 'You asked', 'text': 'The daily clean-up closes settled tickets, reports the rest and asks you nothing.'},
            {'label': 'Done when', 'text': 'Main settles each flagged ticket, and every quoted word stays.'}],
        'visual': {
            'type': 'bars', 'heading': 'Flagged tickets by kind', 'unit': 'tickets',
            'text': f'Each bar counts the tickets the {today.isoformat()} pass closed or flagged under that kind.',
            'rows': rows,
            'details': [{'label': 'Closed', 'value': str(len(closed))}, {'label': 'Flagged', 'value': str(count)},
                        {'label': 'Full list', 'value': 'printed by the clean-up run beside its summary line'}]},
        'sections': [{
            'id': 'found', 'stage': 'found', 'heading': 'What the clean-up found',
            'body': f'{len(closed)} closed. {count} tickets flagged: {summary}.'[:300],
            'items': ([dict(title=f'closed {k}: {l}'[:80], text=d[:160]) for k, l, d in closed]
                      + [dict(title=f'{k}: {l}'[:80], text=d[:160]) for k, l, d in found])[:8]}],
        'next': {'heading': 'Main settles each flagged ticket',
                 'lines': ['A closed ticket keeps its reason in its note and can be reopened.',
                           'A flagged ticket stays as it is until Main or you settle it.',
                           'The run prints where the full finding list is.']},
    }


def captain_origin(row):
    return '[captain-ask]' in row['title'] or bool(re.search(r'type:\s*captain-ask', row.get('body', ''), re.I))


def quote(row):
    """(words, date, source) a captain ticket carries; any part may be ''."""
    return request_title(row, True) if captain_origin(row) and re.search(r'["“]', row.get('body', '')) else '', field(row, 'quoted-at'), field(row, 'source')


def owner_decision(row):
    """A ticket that still holds the captain's call: his ask or quoted words, a captain hold, or a design pick."""
    return captain_origin(row) or row.get('hold_kind') == 'captain' or '[design-ux]' in row['title'] \
        or request_title(row, True) != request_title(row)


def find_source(words, home):
    """(date, path) of the steer record that holds the captain's words, else None."""
    for msg in sorted(Path(home, 'state').glob('*.inbox/**/*.msg')):
        text = msg.read_text(errors='replace')
        if words in text:
            at = re.search(r'^at=(\d{4}-\d{2}-\d{2})', text, re.M)
            return (at[1] if at else ''), str(msg)
    return None


def findings(items, today, unmerged=lambda row: []):
    """items: dicts of name, row, event (epoch or None), parked; unmerged(row) lists the PRs a ticket delivers through when
    every one was closed without a merge. Returns (kind, label, detail) tuples."""
    out, seen, listed = [], {}, set()
    parked = {}
    for it in items:
        row, label = it['row'], f"{it['name']}/{it['row']['id']}"
        if row['state'] == 'done' or label in listed: continue
        listed.add(label)
        body = row.get('body', '')
        if it['parked']: parked[it['name']] = parked.get(it['name'], 0) + 1
        if re.search(r'^\s*(status:\s*superseded|superseded-by:)', body, re.M | re.I):
            out.append(('superseded', label, 'marked superseded in its own text'))
        key = (it['name'], re.sub(r'\W+', ' ', request_title(row).lower()).strip())
        if key in seen:
            out.append(('duplicate', label, f'same title as {seen[key]}, which stays'))
        dead = unmerged(row) if row['state'] != 'in_flight' else []
        if dead: out.append(('closed-unmerged', label, 'closed without a merge: ' + ', '.join(dead)))
        seen.setdefault(key, label)
        if row.get('held') == 'yes' and not re.search(r'^\s*(until|trigger|resume):\s*\S', body, re.M | re.I):
            out.append(('undated-hold', label, 'held with no date or trigger'))
        age = it['event'] and (today - dt.datetime.fromtimestamp(it['event'], dt.timezone.utc).date()).days
        if str(row.get('priority')) in ('0', '1') and age and age > STALE_DAYS:
            out.append(('stale', label, f'P{row["priority"]}, quiet for {age} days'))
    out += [('parked', name, f'{n} open tickets in a parked project') for name, n in parked.items()]
    return out


def dead_prs(row, run, cache):
    """The PRs a ticket delivers through when every one is closed unmerged; [] when it names none, one is open or merged, or GitHub cannot say."""
    urls = delivery_urls(row)
    try: return urls if urls and {reconcile.pr_state(u, run, cache) for u in urls} == {'closed'} else []
    except RuntimeError: return []


def settle(found, items, home, run):
    """Act on the findings that close: returns (closed, flagged). An owner decision stays flagged; a close that fails stays flagged with its cause."""
    by_label = {f"{it['name']}/{it['row']['id']}": it for it in items}
    closed, flagged, shut = [], [], set()
    for kind, label, detail in found:
        it = by_label.get(label)
        if kind not in CLOSES or not it: flagged.append((kind, label, detail)); continue
        if label in shut: continue
        if owner_decision(it['row']): flagged.append((kind, label, detail + '; kept: it holds an owner decision')); continue
        if kind == 'duplicate' and re.match('same title as (\\S+)', detail)[1].rstrip(',') in shut:
            flagged.append((kind, label, detail + '; kept: the ticket it duplicates was closed in this pass')); continue
        note = f'closed by the daily clean-up ({kind}: {detail})'
        # This pass holds the sync lock, so the close must not start the nested poll a done transition normally runs
        # (JG_TICKETS_SYNC points at no file); the next poll shows the closed row on the board.
        env = {**os.environ, 'JG_HOME': str(it['source']), 'JG_TICKETS_SYNC': '/nonexistent/sync.py'}
        try: run(['bash', str(home / 'bin/jg-backlog.sh'), 'done', it['row']['id'], '--note', note], env)
        except (RuntimeError, sp.SubprocessError) as error: flagged.append((kind, label, f'{detail}; close failed: {str(error)[:80]}')); continue
        shut.add(label); closed.append((kind, label, detail))
    return closed, [f for f in flagged if f[1] not in shut]


def daily(items, today, state, board, home, run, carded, cards=None):
    """Once a UTC day (carded: ids of tickets an ask card names): back-fill missing quote parts, close what is settled, raise one report card, return the one board line."""
    day = state / 'cleanup.day'
    if day.exists() and day.read_text() == today.isoformat(): return None
    found, filled = [], 0
    for it in items:
        row = it['row']
        if row['state'] == 'done' or not captain_origin(row): continue
        label, (words, at, src) = f"{it['name']}/{row['id']}", quote(row)
        if it['tid'] not in carded: found.append(('no-ask-card', label, 'no ask card names this ticket, so the board open view shows none of his words'))
        if not words: found.append(('no-quote', label, 'captain ticket carries no quoted words')); continue
        if at and src: continue
        hit = find_source(words, it['source'])
        if not hit: found.append(('no-source', label, 'quote has no dated source link and no steer record holds it')); continue
        add = ('' if at else f'\nquoted-at: {hit[0]}') + ('' if src else f'\nsource: {hit[1]}')
        run(['bash', str(home / 'bin/jg-backlog.sh'), 'update', row['id'], '--body', row.get('body', '') + add], {**os.environ, 'JG_HOME': str(it['source'])})
        filled += 1
    cache = {}
    found += findings(items, today, lambda row: dead_prs(row, run, cache))
    closed, found = settle(found, items, home, run)
    kinds = {}
    for kind, *_ in found: kinds[kind] = kinds.get(kind, 0) + 1
    summary = ', '.join(f'{n} {k}' for k, n in sorted(kinds.items())) or 'none'
    shut = {}
    for kind, *_ in closed: shut[kind] = shut.get(kind, 0) + 1
    card, listed = '', ''
    if found or closed:
        lines = [f'closed {k}: {l} - {d}' for k, l, d in closed] + [f'{k}: {l} - {d}' for k, l, d in found]
        report = state / f'cleanup-{today.isoformat()}.txt'
        report.write_text(f'{len(closed)} closed and {len(found)} flagged tickets, {today.isoformat()}\n' + '\n'.join(lines) + '\n')
        listed = f'; full list {report}'
        card = f'ticket-cleanup-{today.isoformat()}'
        message = state / f'cleanup-{today.isoformat()}.report.json'
        def write_report():
            message.write_text(json.dumps(report_message(found, kinds, card, today, closed), indent=1) + '\n')
        write_report()
        try:
            run(['sign-off-axi', 'post', str(board), '--kind', 'report', '--from', str(message), '--filer', 'tickets-cleanup'])
        except RuntimeError:
            # A day's key can already be taken by an ask card a home posted before
            # this report existed (the old keep/remove card), and a key takes only
            # the same message again. The report is still owed, so it goes on
            # beside that card under its own key.
            card = f'{card}-report'
            write_report()
            run(['sign-off-axi', 'post', str(board), '--kind', 'report', '--from', str(message), '--filer', 'tickets-cleanup'])
    day.write_text(today.isoformat())
    return 'tickets-cleanup: ' + (f"closed {', '.join(f'{n} {k}' for k, n in sorted(shut.items()))}; " if closed else '') + f'flagged {summary}; {filled} quotes back-filled' + (f'; card {card}' if card else '') + listed + (cards() if cards else '')

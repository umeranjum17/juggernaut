"""The daily ticket clean-up: flag what needs a keep/remove call and keep every captain quote."""
import datetime as dt
import json
import os
import re
from pathlib import Path
from hierarchy import field, title as request_title

STALE_DAYS = 14


def report_message(found, kinds, key, today):
    """The clean-up's board card: a report, never an ask.

    A flagged ticket is not one of the captain's six must categories, so the pass
    reports what it found and Main keeps or removes each ticket. A report takes no
    answer, which is what keeps the card off the ask gate: an ask with no must
    category is routed to Overwatch and re-alerted on, forever. Schema 3 is the
    guided report the board draws itself, so no page is written here.
    """
    count = len(found)
    summary = ', '.join(f'{n} {k}' for k, n in sorted(kinds.items())) or 'none'
    rows = [dict(label=k, value=n, note='flagged', tone='warn')
            for k, n in sorted(kinds.items(), key=lambda kv: (-kv[1], kv[0]))][:8]
    while len(rows) < 2: rows.append(dict(label='none', value=0, note='none', tone='ok'))
    return {
        'contract': 1, 'kind': 'report', 'schema': 3, 'filer': 'tickets-cleanup',
        'key': key, 'purpose': 'status', 'project': 'Fleet', 'group': 'Ticket clean-up',
        'filed': dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'title': f'The daily clean-up flagged {count} tickets',
        'about': f'{count} tickets are flagged for a keep or remove call: {summary}. Every captain quote stays on the survivor.',
        'understood': [
            {'label': 'You asked', 'text': 'The daily clean-up reports what it found and asks you nothing.'},
            {'label': 'Done when', 'text': 'Main keeps or removes each flagged ticket, and every quoted word stays.'}],
        'visual': {
            'type': 'bars', 'heading': 'Flagged tickets by kind', 'unit': 'tickets',
            'text': f'Each bar counts the tickets the {today.isoformat()} pass flagged under that kind.',
            'rows': rows,
            'details': [{'label': 'Flagged', 'value': str(count)},
                        {'label': 'Full list', 'value': 'printed by the clean-up run beside its summary line'}]},
        'sections': [{
            'id': 'found', 'stage': 'found', 'heading': 'What the clean-up found',
            'body': f'{count} tickets flagged: {summary}.'[:300],
            'items': [dict(title=f'{k}: {l}'[:80], text=d[:160]) for k, l, d in found[:8]]}],
        'next': {'heading': 'Main keeps or removes each flagged ticket',
                 'lines': ['A ticket kept stays as it is.',
                           'A ticket removed loses its board row and never its quotes.',
                           'The run prints where the full finding list is.']},
    }


def captain_origin(row):
    return '[captain-ask]' in row['title'] or bool(re.search(r'type:\s*captain-ask', row.get('body', ''), re.I))


def quote(row):
    """(words, date, source) a captain ticket carries; any part may be ''."""
    return request_title(row, True) if captain_origin(row) and re.search(r'["“]', row.get('body', '')) else '', field(row, 'quoted-at'), field(row, 'source')


def find_source(words, home):
    """(date, path) of the steer record that holds the captain's words, else None."""
    for msg in sorted(Path(home, 'state').glob('*.inbox/**/*.msg')):
        text = msg.read_text(errors='replace')
        if words in text:
            at = re.search(r'^at=(\d{4}-\d{2}-\d{2})', text, re.M)
            return (at[1] if at else ''), str(msg)
    return None


def findings(items, today):
    """items: dicts of name, row, event (epoch or None), parked. Returns (kind, label, detail) tuples, one per ticket."""
    out, seen, listed = [], {}, set()
    parked = {}
    for it in items:
        row, label = it['row'], f"{it['name']}/{it['row']['id']}"
        if row['state'] == 'done' or label in listed: continue
        listed.add(label)
        body = row.get('body', '')
        if it['parked']: parked[it['name']] = parked.get(it['name'], 0) + 1
        if re.search(r'^\s*(status:\s*superseded|superseded-by:)', body, re.M | re.I):
            out.append(('superseded', label, 'still open'))
        key = (it['name'], re.sub(r'\W+', ' ', request_title(row).lower()).strip())
        if key in seen:
            out.append(('duplicate', label, f'same title as {seen[key]}; the kept ticket must carry both quotes'))
        seen.setdefault(key, label)
        if row.get('held') == 'yes' and not re.search(r'^\s*(until|trigger|resume):\s*\S', body, re.M | re.I):
            out.append(('undated-hold', label, 'held with no date or trigger'))
        age = it['event'] and (today - dt.datetime.fromtimestamp(it['event'], dt.timezone.utc).date()).days
        if str(row.get('priority')) in ('0', '1') and age and age > STALE_DAYS:
            out.append(('stale', label, f'P{row["priority"]}, quiet for {age} days'))
    out += [('parked', name, f'{n} open tickets in a parked project') for name, n in parked.items()]
    return out


def daily(items, today, state, board, home, run, carded, cards=None):
    """Once a UTC day (carded: ids of tickets an ask card names): back-fill missing quote parts, raise one keep/remove card, return the one board line."""
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
    found += findings(items, today)
    kinds = {}
    for kind, *_ in found: kinds[kind] = kinds.get(kind, 0) + 1
    summary = ', '.join(f'{n} {k}' for k, n in sorted(kinds.items())) or 'none'
    card, listed = '', ''
    if found:
        lines = [f'{k}: {l} - {d}' for k, l, d in found]
        report = state / f'cleanup-{today.isoformat()}.txt'
        report.write_text(f'{len(found)} flagged tickets, {today.isoformat()}\n' + '\n'.join(lines) + '\n')
        listed = f'; full list {report}'
        card = f'ticket-cleanup-{today.isoformat()}'
        message = state / f'cleanup-{today.isoformat()}.report.json'
        def write_report():
            message.write_text(json.dumps(report_message(found, kinds, card, today), indent=1) + '\n')
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
    return f'tickets-cleanup: flagged {summary}; {filled} quotes back-filled' + (f'; card {card}' if card else '') + listed + (cards() if cards else '')

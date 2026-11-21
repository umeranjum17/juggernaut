"""Ticket checks on the board's Beads read model; no second ticket store or publisher."""
from collections import defaultdict
import datetime as dt
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path

import cleanup
import identity
import reconcile
from lane import delivery_urls


def load(path):
    spec = importlib.util.spec_from_file_location(path.stem.replace('-', '_'), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def context(snapshot, adapter, view, parked):
    """Keep board ids and derived fields intact; adapt source rows only for the existing cleanup rules."""
    grouped, tickets, aliases = defaultdict(dict), {}, defaultdict(set)
    for name, home, raw in snapshot:
        row = dict(raw, dependencies=[dict(d, depends_on_id=d['id'], type=d['dependency_type']) for d in raw['dependencies']])
        grouped[name][row['id']] = row
        for dep in row['dependencies']:
            grouped[name].setdefault(dep['id'], dict(id=dep['id'], status=dep.get('status'), issue_type=dep.get('issue_type')))
        tid = adapter.scoped(name, raw['id'])
        links = ','.join(filter(None, [raw.get('external_ref'), *view.split((raw.get('metadata') or {}).get('prs'))]))
        tickets[tid] = dict(title=raw['title'], state='done' if raw['status'] == 'closed' else 'open',
                            prs=delivery_urls(dict(title=raw['title'], body=raw.get('description') or '', links=links)))
        for old in [raw['id'], *view.legacy(raw)]:
            aliases[old].add(tid)
            aliases[identity.ticket_id(name, old, raw['id'])].add(tid)
    items = []
    for name, home, raw in sorted(snapshot, key=lambda r: (r[0], r[2].get('created_at') or '', r[2]['id'])):
        row = view.task(grouped[name][raw['id']], grouped[name])
        # An active lane or an open gate must never be closed as an idle duplicate or supersession.
        if adapter.column(raw, home) == 'Being built': row['state'] = 'in_flight'
        if any(d.get('issue_type') == 'gate' and d.get('status') != 'closed' and d['dependency_type'] == 'blocks'
               for d in raw['dependencies']): row['hold_kind'] = 'captain'
        items.append(dict(name=name, source=Path(home), row=row, tid=adapter.scoped(name, raw['id']),
                          event=dt.datetime.fromisoformat(raw['updated_at'].replace('Z', '+00:00')).timestamp(), parked=name in parked))
    # Old cards may name the earlier feed id. An ambiguous alias never chooses a home for the card.
    tickets.update({old: tickets[next(iter(ids))] for old, ids in aliases.items() if len(ids) == 1 and old not in tickets})
    names = defaultdict(list)
    for it in items:
        for key in {it['row']['id'], it['row']['item'], *it['row']['names']}:
            names[key].append(it['row'])
    return items, dict(tickets=tickets, items={key: rows[0] for key, rows in names.items() if len(rows) == 1})


def poll(home, board, options, run):
    """Read each named store once through the adapter's fast board query, not once per CLI ticket/page."""
    adapter = load(Path(os.environ.get('SIGN_OFF_TICKETS_ADAPTER') or home / 'bin/jg-ticket-adapter.py'))
    view = load(home / 'bin/jg-beads-view.py')
    state = home / 'state/tickets-sync'
    state.mkdir(parents=True, exist_ok=True)
    with (state / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try: snapshot = adapter.fleet_snapshot(all_closed=options.cleanup)
        except adapter.Refusal as error: raise RuntimeError(f"{error.body['code']}: {error}") from error
        tickets = []
        for name, source, row in snapshot:
            if not adapter.column(row, source): continue
            adapter.BOARD_HOME = (name, source)
            tickets.append(adapter.to_ticket(row))
        if options.audit:
            print(json.dumps(dict(tickets=tickets)))
            return
        if not options.cleanup:
            # The board derives its fields from these very rows. A poll records observation, never republishes them.
            digest = hashlib.sha256(json.dumps(tickets, sort_keys=True).encode()).hexdigest()
            record = state / 'beads-snapshot.sha256'
            if not options.check and (not record.exists() or record.read_text() != digest):
                record.write_text(digest)
                with (state / 'progress.log').open('a') as log:
                    log.write(f'tickets-sync: {len(adapter.fleet_homes())} homes read; {len(tickets)} Beads tickets observed\n')
            return
        day = dt.datetime.now(dt.timezone.utc).date()
        if (state / 'cleanup.day').exists() and (state / 'cleanup.day').read_text() == day.isoformat(): return
        parked_file = home / 'config/parked-homes'
        parked = {line.split('#')[0].strip() for line in parked_file.read_text().splitlines()} if parked_file.exists() else set()
        items, ctx = context(snapshot, adapter, view, parked)
        decisions = json.loads(run(['sign-off-axi', 'list', str(board), '--json'])).get('decisions', [])
        def cards():
            try: fresh = adapter.fleet_snapshot(all_closed=True)
            except adapter.Refusal as error: raise RuntimeError(str(error)) from error
            _, updated = context(fresh, adapter, view, parked)
            updated.update(prs={}, run=run)
            def log(message):
                with (state / 'card-reconcile.log').open('a') as out: out.write(f'{day} {message}\n')
            dismissed, kept, unclear = reconcile.reconcile(decisions, updated, dt.datetime.now(dt.timezone.utc), board, run, log)
            (state / 'cards-unclear.txt').write_text(''.join(f'{key} - {title} - {why}\n' for key, title, why in unclear))
            return f'\ncards: {dismissed} archived, {kept} kept (source open), {len(unclear)} for Main'
        # A gate is protection even when its ticket's old prose never carried hold_kind.
        carded = {d['ticket'] for d in decisions if d.get('ticket')}
        carded.update(it['tid'] for it in items if any(ctx['tickets'].get(old) is ctx['tickets'][it['tid']] for old in carded))
        line = cleanup.daily(items, day, state, board, home, run, carded, cards)
        if line: print(line)

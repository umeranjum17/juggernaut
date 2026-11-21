"""The fleet backlog tidy: the clean-up rules the captain approved on 9 Nov ("Yes, these rules"), applied to every home's open tickets.

A row closes only with a reason the record can name: its change landed on the local trunk or its PR merged (done), another
open row of the same home carries the same title (duplicate), or the row names the one that replaces it (superseded).
A row idle for 14 days that no parent, link, lane or P0/P1 priority gives a clear owner or value is deferred: held with
the reason stated, never closed and never deleted. A captain ask is never closed, moved or edited; it is only listed
with a tip. Every other row is left alone.

The tickets tables answer when each open row was last touched (stale_rows), and a duplicate closes with a `duplicates`
link to the row that stays open. A gate row (an owner question) is never a candidate: it is no work row, so the plan reads
only the home's backlog rows and a gate is dropped from the tables' answer.

plan() reads and decides; apply() writes through the home's own bin/jg-backlog.sh (done, hold), after the duplicate's link,
so each close and hold reaches the board in the same step as any other backlog transition.
"""
import datetime as dt
import json
import os
import re
from pathlib import Path
from cleanup import captain_origin
from hierarchy import field
from lane import landed_commit

IDLE_DAYS = 14
# The machine words that say a lane's change is on the trunk (lane.word asks the delivery machine once it has landed).
LANDED = {'landed', 'cleaned', 'in-homes', 'in-homes-off', 'in-use'}
KINDS = ('done', 'duplicate', 'superseded', 'deferred', 'captain-ask', 'untouched')


def bd(home, source, *args):
    """One bd call answered from <source>'s tickets tables, through the adapter beside the home's bin/."""
    return ['python3', '-I', str((home / 'bin').resolve().parent / 'core/item-store/adapters/bd_compat.py'), *args], {**os.environ, 'JG_HOME': str(source)}


def stale_rows(homes, home, run):
    """{(home name, row id): when it was last touched} for each home's open rows; decide() counts the idle days. A gate row is no work row and is left out."""
    found = {}
    for name, source in homes.items():
        for row in json.loads(run(*bd(home, source, 'list', '--all', '--json', '--limit', '0')) or '[]'):
            touched = row.get('updated_at') or row.get('created_at')   # a row never edited since it was made has no updated_at
            if row.get('status') == 'closed' or row.get('issue_type') == 'gate' or not touched: continue
            found[(name, row['id'])] = dt.datetime.fromisoformat(touched.replace('Z', '+00:00'))
    return found


def decide(it, today, twin, rows, idle):
    """(kind, evidence) for one open row; `twin` names an earlier open row of the same title, `rows` is the home's {item: row}, `idle` is when bd says it was last touched, or None."""
    row = it['row']
    if captain_origin(row): return 'captain-ask', 'keep: an owner ask is his to close'
    if it['link'] and it['merged']: return 'done', f"its PR merged: {it['link']}"
    if it['said'] in LANDED and landed_commit(it['source'], row['id']):
        return 'done', f"landed on the local trunk as {landed_commit(it['source'], row['id'])[:9]}"
    named = field(row, 'superseded-by')
    if named and named != row['id'] and named in rows: return 'superseded', f'replaced by {named}'
    if twin: return 'duplicate', f'same title as {twin}, which stays open'
    quiet = idle and (today - idle.date()).days
    clear = row.get('held') == 'yes' or it['said'] != 'queued' or it['link'] or str(row.get('priority')) in ('0', '1') \
        or row.get('links') not in (None, '', '-', 'none') or field(row, 'parent') not in ('', 'upkeep')
    if not clear and quiet and quiet >= IDLE_DAYS: return 'deferred', f'idle {quiet} days with no owner, parent, link or lane'
    return 'untouched', ''


def plan(items, today, stale):
    """One decision per open row, in the order the homes were read: (kind, home, item, evidence). Done rows are never read; `stale` is stale_rows' answer."""
    by_home, firsts, out = {}, {}, []
    for it in items:
        by_home.setdefault(it['name'], {})[it['row']['id']] = it['row']
    for it in sorted(items, key=lambda i: (i['name'], i['row'].get('created') or '', i['row']['id'])):
        row = it['row']
        if row['state'] == 'done': continue
        title = ' '.join(row['title'].lower().split())  # the exact title: a [blocker] or [feature] tag makes a different row
        # An earlier open twin is the survivor; a row with a lane or a PR of its own is a row with work behind it, so it never closes as one.
        twin = firsts.get((it['name'], title)) if title and it['said'] == 'queued' and not it['link'] else None
        kind, evidence = decide(it, today, twin, by_home[it['name']], stale.get((it['name'], row['id'])))
        if kind in ('untouched', 'deferred', 'captain-ask'): firsts.setdefault((it['name'], title), row['id'])  # only a row that stays open can be the survivor
        out.append((kind, it['name'], row['id'], evidence))
    return out


def counts(decisions):
    return {k: sum(1 for d in decisions if d[0] == k) for k in KINDS}


def commands(decision, today):
    """The jg-backlog.sh call that carries one decision out, or None when the row is only listed or left alone."""
    kind, _home, item, evidence = decision
    if kind in ('done', 'duplicate', 'superseded'):
        pr = re.search(r'https://\S+', evidence)
        return ['done', item, *(['--pr', pr[0]] if kind == 'done' and pr else []), '--note', f'closed by the fleet tidy {today.isoformat()}: {evidence}']
    if kind == 'deferred':
        return ['hold', item, '--kind', 'parked', '--reason', f'{evidence}; deferred by the fleet tidy {today.isoformat()}, unhold to resume']
    return None


def apply(decisions, today, homes, home, run):
    """Carry out every close and deferral through its own home's backlog; return (applied, failed [(label, why)])."""
    applied, failed = 0, []
    for decision in decisions:
        args = commands(decision, today)
        if not args: continue
        try:
            if decision[0] == 'duplicate':
                run(*bd(home, homes[decision[1]], 'dep', 'add', decision[2], re.search(r'same title as (\S+?),', decision[3])[1], '--type', 'duplicates'))
            run(['bash', str(home / 'bin/jg-backlog.sh'), *args], {**os.environ, 'JG_HOME': str(homes[decision[1]])})
            applied += 1
        except RuntimeError as error:
            failed.append((f'{decision[1]}/{decision[2]}', str(error)[:160]))
    return applied, failed

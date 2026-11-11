"""Drop the tickets that came before Beads: the captain's order of 11 Nov, "All pre-7-Nov open".

Beads is the one work store. A row of any home that is still open and was filed before the cut date is closed with the note
"dropped by captain 11 Nov" (closed, never deleted, so `jg-backlog.sh reopen` brings it back). An open board ticket that no
home's row answers to is a pre-Beads leftover of the old sign-off board and is closed on the board the same way.

Kept, and listed for the captain instead: an owner decision (his ask or quoted words, a captain hold, a design pick), a row or
board ticket a waiting sign-off card names, a row whose worker is live, and a row with no filing date (its age is unproven).

plan() reads and decides; apply() writes through each home's own bin/jg-backlog.sh, so the board follows the row in the same
step, and closes the board-only leftovers through sign-off-axi.
"""
import os
import subprocess
from cleanup import owner_decision
from lane import assignee

NOTE = 'dropped by captain 11 Nov'
KEPT = ('kept-owner', 'kept-card', 'kept-live', 'kept-undated')
KINDS = ('drop', 'drop-board', *KEPT, 'later')


def waiting_cards(decisions):
    """Tickets a sign-off card that nobody has answered or dismissed names."""
    return {d['ticket'] for d in decisions if d.get('ticket') and not d.get('decided') and not d.get('dismissed')}


def decide(it, before, carded):
    row = it['row']
    created = row.get('created') or ''
    if not created[:1].isdigit(): return 'kept-undated', 'no filing date, so its age is unproven'
    if created >= before: return 'later', f'filed {created}, not before {before}'
    if owner_decision(row): return 'kept-owner', 'an owner decision is his to close'
    if it['tid'] in carded: return 'kept-card', 'a waiting board card names it'
    if assignee(it['source'], row['item'], it['name'])['live']: return 'kept-live', 'its worker is running'
    return 'drop', f'filed {created}'


def plan(items, before, carded, board_open, answered):
    """(kind, home, item, evidence) per open row, then per leftover board ticket as (kind, 'board', ticket id, evidence).
    board_open is the board's open tickets, answered the ticket ids some home's row answers to."""
    out = []
    for it in items:
        if it['row']['state'] == 'done': continue
        kind, evidence = decide(it, before, carded)
        out.append((kind, it['name'], it['row']['id'], evidence))
    for t in board_open:
        if t['id'] in answered: continue
        if t.get('asked'): out.append(('kept-owner', 'board', t['id'], 'a captain ask is his to close'))
        elif t['id'] in carded: out.append(('kept-card', 'board', t['id'], 'a waiting board card names it'))
        else: out.append(('drop-board', 'board', t['id'], 'no home has a row for it'))
    return out


def counts(decisions, failed=None):
    """({kind: n}, {home: (open before, open after)}). Rows of one home, and the board's leftovers as `board`, count as open
    until dropped; with `failed` (the apply's (label, why) pairs) a row that would not close still counts as open."""
    refused = {label for label, _why in failed or ()}
    kinds = {k: sum(1 for d in decisions if d[0] == k) for k in KINDS}
    homes = {}
    for kind, home, item, _ev in decisions:
        before, after = homes.get(home, (0, 0))
        dropped = kind in ('drop', 'drop-board') and failed is not None and f'{home}/{item}' not in refused
        homes[home] = (before + 1, after + (not dropped and (failed is not None or kind not in ('drop', 'drop-board'))))
    return kinds, homes


def apply(decisions, homes, home, board, run):
    """Close every dropped row through its own home's backlog and every leftover on the board; return (applied, failed)."""
    applied, failed = 0, []
    for kind, name, item, _ev in decisions:
        try:
            if kind == 'drop':
                run(['bash', str(home / 'bin/jg-backlog.sh'), 'done', item, '--note', NOTE], {**os.environ, 'JG_HOME': str(homes[name])})
            elif kind == 'drop-board':
                run(['sign-off-axi', 'ticket', str(board), '--id', item, '--state', 'done', '--progress', '100', '--hold', 'no'])
            else: continue
            applied += 1
        except (RuntimeError, subprocess.TimeoutExpired) as error:  # a slow close is a failure to list, never the end of the pass
            failed.append((f'{name}/{item}', str(error)[:160]))
    return applied, failed

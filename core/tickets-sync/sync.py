#!/usr/bin/env python3
"""Backlog backfill and incremental publication via sign-off-axi ticket.

--check corrects provable ticket state drift and reports unaccounted tickets.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess as sp
import sys
import time
import shutil
import xml.etree.ElementTree as xml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from task_rows import toon_rows
from lane import stage as lane_stage, assignee as lane_assignee
import cleanup
import identity
import legacy
import reconcile
import release
import drop
import tidy
from hierarchy import UPKEEP, INTERNAL, OWN, parents as request_parents, title as request_title
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves here
for _jg_old, _jg_val in list(os.environ.items()):
    if _jg_old.startswith("FM_") and "JG_" + _jg_old[3:] not in os.environ:
        os.environ["JG_" + _jg_old[3:]] = _jg_val

def run(args, env=None, cwd=None, missing=False):
    r = sp.run(args, env=env, cwd=cwd, text=True, capture_output=True, timeout=60)
    if r.returncode and not (missing and '\ncode: NOT_FOUND\n' in '\n' + r.stdout + r.stderr + '\n'):
        # An axi tool prints its refusal on stdout and only warnings on stderr (sign-off names every answer whose card
        # left the board), so the refusal is the cause; a tool with no refusal line has it on stderr.
        refusal = re.search(r'^error: .*$', r.stdout, re.M)
        raise RuntimeError(f'{args[0]}: {refusal[0] if refusal else r.stderr.strip() or r.stdout.strip()}')
    return '{}' if r.returncode else r.stdout

# What one ticket's publish can fail with; a bad record is skipped, never fatal to the pass.
TICKET_ERRORS = (OSError, ValueError, KeyError, RuntimeError, sp.TimeoutExpired)

def rows(args, env, cwd=None, extra=''):
    # A Beads home's list answers whole titles and bodies on --full, so it needs no read of each truncated row.
    text = run(args + ['--limit', '100000', '--fields', 'held,hold_kind,hold_reason,closed,created,priority,body,links' + extra] + (['--full'] if extra else []), env, cwd)
    result = toon_rows(text)
    if result is None or re.search(r'count: \d+ of (?!0\b)\d+ total', text) and len(result) >= 100000:
        raise RuntimeError('the backlog returned an unreadable or capped task list')
    return result

ICONS = Path(__file__).resolve().parent / 'icons'
ALIAS = {'juggernaut-fork': 'juggernaut', 'main': 'juggernaut', 'muxr': 'pockit'}

def icon_problem(image):
    if image.suffix == '.svg':
        try: root = xml.parse(image).getroot()
        except xml.ParseError as error: return f'not valid XML ({error})'
        return None if root.tag in ('svg', '{http://www.w3.org/2000/svg}svg') else 'not an svg root'
    try: r = sp.run(['identify', '-format', '%m %w %h', str(image) + '[0]'], text=True, capture_output=True, timeout=60)
    except FileNotFoundError: return 'ImageMagick identify is not installed'
    kind, _, size = r.stdout.partition(' ')
    return None if r.returncode == 0 and kind in ('PNG', 'JPEG', 'WEBP') and all(int(n) > 0 for n in size.split()) else 'not a readable ' + image.suffix[1:] + ' image'

def register_icon(board, project, registry):
    """Register a local project image; return a skip reason or None."""
    name = ALIAS.get(project.lower(), project.lower())
    found = sorted(ICONS.glob(name + '.*'))
    if not found: return 'no local image'
    image = found[0]
    problem = icon_problem(image)
    if problem: return problem
    digest = hashlib.sha256(image.read_bytes()).hexdigest()
    if registry.get(project.lower()) == digest: return None
    target = board.parent / 'icons' / (project.lower() + image.suffix)
    target.parent.mkdir(exist_ok=True)
    shutil.copyfile(image, target)
    try: run(['sign-off-axi', 'project', str(board), '--name', project, '--icon', 'icons/' + target.name])
    except RuntimeError as error: return str(error)[:120]
    registry[project.lower()] = digest
    return None

def feed_path(board):
    # sign-off keeps its ticket feed beside the board: decisions.json -> decisions.tickets.jsonl.
    return Path(re.sub(r'\.json$', '', str(board)) + '.tickets.jsonl')

def feed_records(text):
    """The newest feed line per ticket, as written; a torn or empty line is skipped."""
    records = {}
    for line in text.splitlines():
        try: record = json.loads(line) if line.strip() else None
        except ValueError: continue
        if record and record.get('id'): records[record['id']] = record
    return records

def write_assignee(path, tid, record, desired, ends_with_newline, reason='', assignee_only=False):
    """Append the ticket's own record again, its fields as this pass sets them, carrying the assignee the board shows (the
    record's own when `desired` names none).
    sign-off's writer takes no assignee field and its format lets another program append lines in the same shape, one
    JSON object and a newline per write, so the newest line is the whole record and every other field reads as before.
    assignee_only writes that one field onto a record this pass does not otherwise publish, so nothing else moves."""
    line = dict(record)
    for key, value in desired.items():
        if assignee_only or key == 'assignee': continue
        if key == 'pr':
            if value: line['prs'] = [value]
            else: line.pop('prs', None)
        elif key in ('hold', 'asked'): line[key] = value == 'yes'
        elif key == 'last-event-at': line['last_event_at'] = int(value)
        elif value == '': line.pop(key, None)
        else: line[key] = value
    # The newest line is the whole record, so a hold's reason travels with it and a release drops it.
    if not assignee_only:
        if desired.get('hold') == 'yes' and reason: line['hold_reason'] = reason
        else: line.pop('hold_reason', None)
    line.update(id=tid, at=dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
    if 'assignee' in desired: line['assignee'] = desired['assignee']
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, 'w') as feed:
        feed.write(('' if ends_with_newline else '\n') + json.dumps(line) + '\n')
    return line

def store_named(home):
    # The rule is bin/jg-backlog-lib.sh's jg_backlog_beads_store: a home has a store when config/beads-dir names one, and a blank file names none.
    named = home / 'config/beads-dir'
    return named.is_file() and bool(named.read_text().strip())

def tidy_report(items, homes, home, state, apply, run):
    """Plan the fleet tidy over every home's open rows, write the full list beside the sync state, return the summary line."""
    today = dt.date.fromisoformat(os.environ['JG_TIDY_TODAY']) if os.environ.get('JG_TIDY_TODAY') else dt.datetime.now(dt.timezone.utc).date()
    decisions = tidy.plan(items, today)
    count, opened = tidy.counts(decisions), len(decisions)
    closed = count['done'] + count['duplicate'] + count['superseded']
    applied, failed = tidy.apply(decisions, today, homes, home, run) if apply else (0, [])
    listing = state / f'tidy-{today.isoformat()}.txt'
    listing.write_text(f'{opened} open rows, {today.isoformat()}, {"applied" if apply else "plan only"}\n' + ''.join(f'{k}: {n}/{i} - {e}\n' for k, n, i, e in decisions if k != 'untouched') + ''.join(f'failed: {l} - {w}\n' for l, w in failed))
    verb = 'closed' if apply else 'would close'
    after = opened - (closed - len(failed) if apply else closed)
    return (f"tickets-tidy: {opened} open before, {after} after; {verb} {count['done']} done, {count['duplicate']} duplicate, {count['superseded']} superseded; "
            f"{'deferred' if apply else 'would defer'} {count['deferred']} idle; {count['captain-ask']} captain asks listed, none touched; {count['untouched']} left alone"
            + (f'; {len(failed)} failed' if failed else '') + f'; full list {listing}')

def drop_report(homes, existing, home, board, state, before, apply, run):
    """Plan the drop of every pre-Beads open ticket, write the full list beside the sync state, return the summary line.
    It reads each store's own rows, not the publish walk's, because that walk keys a row by its item name and one name can
    belong to an open row and a done twin."""
    items = []
    for name, source in homes.items():
        if not store_named(source): continue
        env = {k: v for k, v in os.environ.items() if k not in ('JG_DATA_OVERRIDE', 'JG_ROOT_OVERRIDE')} | {'JG_HOME': str(source)}
        for r in rows(['bash', str(home / 'bin/jg-backlog.sh'), 'list', '--all'], env, extra=',item'):
            items.append(dict(name=name, source=source, row=r, tid=identity.ticket_id(name, r['item'], r['id'])))
    carded = drop.waiting_cards(json.loads(run(['sign-off-axi', 'list', str(board), '--json'])).get('decisions', []))
    # A lead home sees only its own rows, so it cannot tell another home's board tickets from leftovers: it leaves them to the parent.
    board_open = [] if identity.is_lead(home) else [t for t in existing.values() if t.get('state') != 'done' and t.get('stage') != 'done']
    decisions = drop.plan(items, before, carded, board_open, {i['tid'] for i in items})
    applied, failed = drop.apply(decisions, homes, home, board, run) if apply else (0, [])
    count, per_home = drop.counts(decisions, failed if apply else None)
    day = dt.datetime.now(dt.timezone.utc).date().isoformat()
    listing = state / f'drop-pre-beads-{day}.txt'
    listing.write_text(f'{len(decisions)} open tickets, filed before {before}, {day}, {"applied" if apply else "plan only"}\n'
                       + ''.join(f'{h}: {b} open before, {a} open after\n' for h, (b, a) in per_home.items())
                       + ''.join(f'{k}: {n}/{i} - {e}\n' for k, n, i, e in decisions if k in drop.KEPT)
                       + ''.join(f'failed: {l} - {w}\n' for l, w in failed))
    after = sum(a for _b, a in per_home.values())
    return (f"tickets-drop: {len(decisions)} open before, {after} after; {'dropped' if apply else 'would drop'} {count['drop']} rows and {count['drop-board']} board-only tickets; "
            f"kept {count['kept-owner']} owner decisions, {count['kept-card']} with a waiting card, {count['kept-live']} with a live worker, {count['kept-undated']} undated; "
            f"{count['later']} filed on or after {before}" + (f'; {len(failed)} failed' if failed else '') + f'; full list {listing}')

def sync():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit', action='store_true')
    parser.add_argument('--check', action='store_true', help='correct proven state drift and print tickets that cannot be accounted for')
    parser.add_argument('--cleanup', action='store_true', help='once a day, flag tickets that need a keep/remove call and back-fill captain quotes')
    parser.add_argument('--migrate-legacy', action='store_true', help='one-off: release the legacy fm- rows that hold with no reason; with --check, print the plan and write nothing')
    parser.add_argument('--reconcile', action='store_true', help='read every home without the watcher time budget')
    parser.add_argument('--tidy', action='store_true', help="apply the captain's clean-up rules to every home's open tickets: print the plan and counts, change no row")
    parser.add_argument('--apply', action='store_true', help='with --tidy or --drop-pre-beads, carry the plan out')
    parser.add_argument('--drop-pre-beads', metavar='DATE', help="the captain's 11 Nov order: print the plan to close every open ticket filed before DATE (the Beads cut) and every board-only leftover, change none")
    parser.add_argument('--close', metavar='HOME/ITEM', help='record an authorized cancellation or supersession on the board only')
    parser.add_argument('--reason', choices=['superseded', 'cancelled'])
    options = parser.parse_args()
    if bool(options.close) != bool(options.reason): parser.error('--close and --reason are required together')
    if options.apply and not (options.tidy or options.drop_pre_beads): parser.error('--apply needs --tidy or --drop-pre-beads')
    if options.cleanup or options.tidy or options.drop_pre_beads: options.check = options.reconcile = True  # reads like --check, without the watcher budget
    started = time.monotonic()
    budget = float(os.environ.get('JG_TICKETS_SYNC_BUDGET_SECS', '20'))
    home = Path(os.environ['JG_HOME']).resolve()
    # The parent's poll reads this lead home with every other registered one; a second writer here published its rows
    # as main/<item> twins and judged the whole shared board from one home.
    if identity.is_lead(home) and not options.drop_pre_beads: return  # the drop closes this home's own rows only; the parent's poll owns the shared board
    board = Path((home / 'config/fleet-board').read_text().strip())
    if not board.is_absolute(): board = home / board
    if options.audit: print(run(['sign-off-axi', 'ticket', str(board), '--json'])); return
    state = home / 'state/tickets-sync'
    state.mkdir(parents=True, exist_ok=True)
    def note(message):
        # Mid-pass progress is not Main-actionable; check stdout is a wake.
        with (state / 'progress.log').open('a') as log: log.write(message + '\n')
    with (state / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        ledger_file = state / ('published-' + hashlib.sha256(str(board).encode()).hexdigest()[:12] + '.json')
        ledger = json.loads(ledger_file.read_text()) if ledger_file.exists() else {}
        pr_file = state / 'prs.json'
        prs = json.loads(pr_file.read_text()) if pr_file.exists() else {}
        closures_file = state / 'closures.json'
        closures = json.loads(closures_file.read_text()) if closures_file.exists() else {}
        homes = {identity.home_name(home) if options.drop_pre_beads else 'main': home}
        registry = home / 'data/squad_leads.md'
        for line in registry.read_text().splitlines() if registry.exists() else []:
            m = re.match(r'- (\S+) - .*\(home: ([^;]+);', line)
            if m: homes[m[1]] = Path(m[2])
            elif re.match(r'- \S+ - .*\(host:', line): raise RuntimeError('remote home requires a backlog reader: ' + line.split(' - ')[1])
        parked_file = home / 'config/parked-homes'
        parked = {l.split('#')[0].strip() for l in parked_file.read_text().splitlines()} if parked_file.exists() else set()
        cutoff = (dt.date.today() - dt.timedelta(days=7)).isoformat()
        # Each budgeted walker owns its own cursor. The read-only check once shared the poll's, so every window the check
        # walked was skipped by the poll that ran after it and its rows never reached the board ("ticket says no state").
        cursor = state / ('check-cursor.json' if options.check else 'cursor.json')
        resume = json.loads(cursor.read_text()) if cursor.exists() and not options.reconcile else {}
        ordered = list(homes.items())
        if resume.get('home') in homes: ordered = ordered[list(homes).index(resume['home']):]
        existing = {t['id']: t for t in json.loads(run(['sign-off-axi', 'ticket', str(board), '--json']))['tickets']}
        feed_file = feed_path(board)
        feed_text = feed_file.read_text() if feed_file.exists() else ''
        feed, feed_ends = feed_records(feed_text), not feed_text or feed_text.endswith('\n')
        # The board's own read drops the assignee, so the feed's newest line per ticket is what the pass compares against.
        for tid, record in feed.items():
            if tid in existing and record.get('assignee') is not None: existing[tid]['assignee'] = record['assignee']
        # One open ticket per piece of work is the board's own rule, so the sync must not fight it: a source item whose
        # work the board already tracks under another id is left alone instead of failing the whole pass as a twin.
        def work_key(t):
            return ((t.get('project') or '').lower(), t.get('parent') or '', ' '.join((t.get('title') or '').split()).lower())
        tracked = {}
        for t in existing.values():
            if t.get('state') != 'done' and t.get('stage') != 'done':
                tracked.setdefault(work_key(t), []).append(t['id'])
        changed = 0
        items = []
        registry = {p['name'].lower(): p.get('icon', {}).get('sha256') for p in json.loads(run(['sign-off-axi', 'project', str(board), '--json'])).get('projects', [])}
        skip_file = state / 'icons-skipped.json'
        skipped = json.loads(skip_file.read_text()) if skip_file.exists() else {}
        tried = set()
        def save(path, value):
            temp = path.with_suffix('.tmp'); temp.write_text(json.dumps(value)); temp.replace(path)
        no_store_file = state / 'no-store-homes.json'
        no_store = set(json.loads(no_store_file.read_text())) if no_store_file.exists() else set()
        # The check names a ticket no home's work accounts for only after one walk has read every home, so the rows its
        # earlier passes of that walk saw travel in its cursor.
        seen = set(resume.get('seen', []))
        # One row publishes a ticket per walk. A store can hold two rows of one piece of work (a row filed again under a
        # new name, a home whose store took a copy of main's rows at the Beads cut), and both would write its ticket in
        # turn; the first row of the walk, main first and then registry order, owns it, so its cursor carries the claims.
        claims = dict(resume.get('claims', {}))
        skipped_ids = set()
        def publish(tid, desired, derived=(), where='', reason='', description=''):
            # One bad record never stops the pass: name it and the home and item behind it once, then go on.
            try: _publish(tid, desired, derived, reason, description)
            except TICKET_ERRORS as error:
                if tid in skipped_ids: return
                skipped_ids.add(tid)
                print(f"tickets-sync: skipped {tid}: {where + ': ' if where else ''}{error}")
        def owner_line(tid, desired):
            """Write just the owner onto a row this pass does not otherwise publish, leaving every other field as the board
            has it. Two rows need it: one whose work another ticket already covers, and the row the board still shows for
            that work from before the poll re-keyed its ids. The ids are a hash of the home and item, so the legacy row is
            this one with its old prefix: the same work, the same home answering for it."""
            nonlocal feed_ends
            if 'assignee' not in desired or tid not in existing or existing[tid].get('assignee') == desired['assignee']:
                return
            feed[tid] = write_assignee(feed_file, tid, feed.get(tid, {}), {'assignee': desired['assignee']}, feed_ends, assignee_only=True)
            feed_ends = True
            existing[tid]['assignee'] = desired['assignee']
        def legacy_owner(tid, desired):
            if tid.startswith('jg-'): owner_line('fm-' + tid[3:], desired)
        def _publish(tid, desired, derived=(), reason='', description=''):
            nonlocal changed, feed_ends
            seen.add(tid)
            if options.check:
                if options.cleanup or options.tidy or options.drop_pre_beads: return
                # A row whose work another ticket already covers is left alone on purpose (the board keeps one open
                # ticket per piece of work), so its missing state is not a disagreement to report.
                if any(o != tid for o in tracked.get(work_key(desired), [])): return
                # A leaf's state is derived from its work. Reuse the poll's publisher to correct it;
                # grouping rows and already-settled leaves need no write on this check.
                if 'stage' not in desired or (existing.get(tid, {}).get('state') or '') == desired['state']:
                    return
            digest = hashlib.sha256(json.dumps(desired, sort_keys=True).encode()).hexdigest()
            old = existing.get(tid, {})
            def settled(key, value):
                stored = old.get({'pr': 'prs', 'last-event-at': 'last_event_at'}.get(key, key))
                if key == 'assignee': return stored == value
                # The board stores an absent field as null, and derives a grouping row's roll-up.
                if stored is None: stored = [] if key == 'pr' else ''
                if key == 'pr': value = [value] if value else []
                elif key in ('hold', 'asked'): value = value == 'yes'
                return key in derived or stored == value
            # Board wins over ledger: a prior digest can drift after a partial write.
            # Until the board takes the machines' own stage words, a word it cannot show is the description's first line
            # ("Stage: <word>"), so a new word with the same board stage rewrites the description, and so does going back to
            # a word the board shows.
            def exact(text): return text.partition('\n')[0] if text.startswith('Stage: ') else ''
            restage = bool(old) and exact(description) != exact(old.get('description') or '')
            matched = all(settled(k, v) for k, v in desired.items()) and not restage
            if not matched and any(o != tid for o in tracked.get(work_key(desired), [])):
                ledger[tid] = digest; save(ledger_file, ledger)
                # Another ticket already covers this work, so no field of it is published: it still names its owner.
                owner_line(tid, desired); legacy_owner(tid, desired)
                return
            legacy_owner(tid, desired)
            if matched:
                if ledger.get(tid) != digest: ledger[tid] = digest; save(ledger_file, ledger)
                return
            args = ['sign-off-axi', 'ticket', str(board), '--id', tid]
            for key, value in desired.items():
                if key != 'assignee': args += ['--' + key, str(value)]
            if desired.get('hold') == 'yes': args += ['--hold-reason', reason]
            # The board refuses a new ticket without a description and wants its "# Ask", "# Why" and "# Done when"
            # headings each at the start of a line, so the task body goes whole, line breaks kept. Only a new row sends it,
            # so words written on the board afterwards stay.
            summary = '' if old and not restage else description or desired.get('title') or tid
            if summary: args += ['--description', summary]
            run(args); changed += 1
            if 'assignee' in desired:
                # The owner line is the whole record, so a new row's description rides along or the line would drop it.
                feed[tid] = write_assignee(feed_file, tid, {**feed.get(tid, {}), **({'description': summary} if summary else {})}, desired, feed_ends, reason)
                feed_ends = True
            updated = dict(old)
            for key, value in desired.items():
                if key == 'pr': updated['prs'] = [value] if value else []
                elif key == 'last-event-at': updated['last_event_at'] = int(value)
                elif key in ('hold', 'asked'): updated[key] = value == 'yes'
                else: updated[key] = value
            if summary: updated['description'] = summary
            existing[tid] = updated
            ledger[tid] = digest; save(ledger_file, ledger)
        if options.migrate_legacy:
            # The feed is what the board is built from, so it names every held row (the board's own list hides a row that
            # twins another open one), and one line per row is the poll's own way to write a whole record.
            def unhold(record):
                nonlocal feed_ends
                write_assignee(feed_file, record['id'], record, legacy.released(record), feed_ends)
                feed_ends = True
            print(legacy.migrate(list(feed.values()), unhold, write=not options.check))
            return
        if options.close:
            name, sep, item = options.close.partition('/')
            if name not in homes or not sep or not item: raise RuntimeError('--close requires a registered HOME/ITEM')

        if options.drop_pre_beads:
            print(drop_report(homes, existing, home, board, state, options.drop_pre_beads, options.apply, run)); return
        upkeep_id = identity.ticket_id('fleet', ':upkeep')
        # A fleet-wide row owns nothing in the registry, so it names the home that publishes it rather than going blank,
        # and it is no lane's work: no worker words on a grouping row.
        fleet_assignee = lane_assignee(home, ':upkeep', 'main', ran=True)
        publish(upkeep_id, dict(title=UPKEEP, progress=0, project=OWN, parent='', hold='no', asked='no', state='queued', assignee=fleet_assignee), ('progress',), 'fleet/:upkeep')
        for tid, old in existing.items():
            if tid.startswith('jg-') and old['title'].startswith(('Needs a parent', 'Upkeep ·', 'Earlier task grouping')):
                publish(tid, dict(title='Earlier task grouping', progress=0, project=OWN, parent=upkeep_id, hold='no', asked='no', state='done', assignee=fleet_assignee), ('progress',), f'board/{tid}')
            elif tid.startswith('jg-') and tid != upkeep_id and (old.get('project', '').lower() in INTERNAL or not old.get('asked') and not old.get('parent')):
                publish(tid, dict(project=OWN if old.get('project', '').lower() in INTERNAL or not old.get('project') else old.get('project', ''), parent=old.get('parent') or ('' if old.get('asked') else upkeep_id)), where=f'board/{tid}')
        walked = False
        # New lead rows must not wait behind a multi-pass walk through older main rows. Migrated ticket ids may
        # belong to more than one home, so the ordinary main-first walk retains ownership of those rows.
        priority_homes = [(name, source, True) for name, source in homes.items() if name != 'main'] if not options.check and not options.reconcile else []
        for name, source, priority in priority_homes + [(name, source, False) for name, source in ordered]:
            # A home with no Beads store has no backlog to publish: the sync notes that once in its progress log (never a
            # wake) and every pass, check and clean-up skips it without a word.
            if not store_named(source):
                if not options.check and name not in no_store:
                    no_store.add(name); save(no_store_file, sorted(no_store))
                    note(f'{name}: no Beads store named in {source}/config/beads-dir, skipped')
                continue
            if name in no_store and not options.check: no_store.discard(name); save(no_store_file, sorted(no_store))
            env = {k: v for k, v in os.environ.items() if k not in ('JG_DATA_OVERRIDE', 'JG_ROOT_OVERRIDE')}
            env['JG_HOME'] = str(source)
            reader = ['bash', str(home / 'bin/jg-backlog.sh')]
            # A Beads home answers every row, done ones and whole bodies included, from one provider read.
            tasks = rows(reader + ['list', '--all'], env, extra=',parent,item')
            # The rest of the pass keys a row by the item name its state files and parent lines use.
            by_id = {r['id']: r for r in tasks}
            for r in tasks:
                parent = r['parent'] if r['parent'] == 'upkeep' else by_id[r['parent']]['item'] if r['parent'] in by_id else ''
                if parent: r['body'] += f"\nparent: {parent}"
            tasks = {r['item']: dict(r, id=r['item'], store_id=r['id']) for r in tasks}
            def ticket(item): return identity.ticket_id(name, item, tasks[item]['store_id'])
            if options.close and name == options.close.partition('/')[0]:
                if options.close.partition('/')[2] not in tasks: raise RuntimeError('--close item not found: ' + options.close)
                closures[options.close] = options.reason
                save(closures_file, closures)
            ids = list(tasks)
            cut_names = release.cut(source / 'data')
            projects = {}
            for r in tasks.values():
                repo = r.get('repo') if r.get('repo') not in ('-', 'none', '') else name
                if repo not in projects:
                    clone = source / 'projects' / repo
                    origin = run(['git', '-C', str(clone), 'remote', 'get-url', 'origin']).strip() if (clone / '.git').exists() else repo
                    projects[repo] = origin.rstrip('/').split('/')[-1].removesuffix('.git')
                r['_project'] = '' if projects[repo].lower() in INTERNAL else projects[repo]
            ancestry, asks = request_parents(tasks)
            parents = set(ancestry.values())
            if priority: ids = [item for item in ids if ticket(item) not in existing and tasks[item]['state'] != 'done'
                                and not identity.TICKET.fullmatch(tasks[item]['store_id'])]
            elif resume.get('home') == name and resume.get('task') in tasks: ids = ids[ids.index(resume['task']):]
            required = set(resume.get('required', [])) if resume.get('home') == name else set()
            for item in ids:
                r = tasks[item]
                # A pass always handles the row it resumed on: when the reads before the walk outlast the budget under
                # load, a pass that stops first would save the same cursor again and the walk would never move.
                if not priority and not options.reconcile and walked and time.monotonic() - started > budget:
                    save(cursor, dict(home=name, task=item, required=list(required), claims=claims, **({'seen': sorted(seen)} if options.check else {})))
                    note(f'tickets-sync: backfill continuing on next watcher check; {changed} changed')
                    return
                if not priority: walked = True
                tid = ticket(item)
                if r['state'] == 'done' and r.get('closed', '-') < cutoff and tid not in ledger and tid not in existing and item not in required: continue
                body = r.get('body', '')
                def field(key):
                    m = re.search(r'^\s*' + key + r':\s*(.+)$', body, re.M | re.I)
                    return m[1].strip() if m else ''
                held = name in parked or r.get('held') == 'yes' or r.get('hold_kind') == 'parked'
                # A hold always carries its reason: the source item's own words, or the parking that holds a whole home.
                # The board caps a reason as it caps a title, so a long note is shortened and the source record keeps it whole.
                stored_reason = r.get('hold_reason') or ''
                hold_reason = '' if stored_reason in ('-', 'none') else ' '.join(stored_reason.split())
                if len(hold_reason) > 160: hold_reason = hold_reason[:159].rstrip() + '…'
                if held and not hold_reason: hold_reason = f'{name} home is parked' if name in parked else ''
                if held and not hold_reason:
                    held = False
                    print(f'tickets-sync: {name}/{item} is held with no reason; publishing it unheld')
                # A release names what the local trunk cut. A PR-era version, a body word about timing or "none" is no release:
                # send none, so the board keeps no milestone the trunk never cut and no placeholder is stored on a ticket.
                release_value = release.name(field('release'), cut_names)
                said, stage, done, pr, event = lane_stage(home, source, item, r, prs, run)
                save(pr_file, prs)
                done = done or f'{name}/{item}' in closures or existing.get(tid, {}).get('state') == 'done'
                if done: said = stage = 'done'
                parent = ancestry[item]
                root_ask = item in asks
                title = request_title(r, root_ask)
                if len(title) > 100: title = title[:99].rstrip() + '…'  # a board row shows about 60 characters
                project = r['_project'] or OWN  # hierarchy keeps the blank: an internal row never joins a project's ask
                if project and project not in tried and not options.check:  # --check writes no board project
                    tried.add(project); reason = register_icon(board, project, registry)
                    if reason != skipped.get(project):
                        skipped.pop(project, None) if reason is None else skipped.__setitem__(project, reason)
                        save(skip_file, skipped)
                        # Skips stay in icons-skipped.json only: check stdout is a Main wake.
                        if reason is None: print(f'tickets-sync: {project} icon registered')
                if parent in tasks and ticket(parent) not in ledger:
                    required.add(parent); ids.append(parent)
                parent_id = ticket(parent) if parent in tasks else '' if root_ask else upkeep_id
                desired = dict(title=title, progress=100 if done and item not in parents else 0, state='' if item in parents else 'done' if done else 'on hold' if held else 'queued' if said == 'queued' else 'in progress', pr=pr, release=release_value[:40], parent=parent_id, priority=f"P{r['priority']}" if str(r.get('priority')) in ('0', '1', '2', '3') else '', project=project, hold='yes' if held and not done else 'no', asked='yes' if root_ask else 'no', assignee=lane_assignee(source, item, name, ran=done or said != 'queued'))
                if item not in parents:
                    desired['stage'] = stage
                    if event is not None: desired['last-event-at'] = event
                if all(i['name'] != name or i['row']['id'] != item for i in items): items.append(dict(tid=tid, name=name, row=r, event=event, parked=name in parked, source=source, said=said, link=pr, merged=bool(prs.get(pr, {}).get('merged'))))
                if claims.setdefault(tid, f'{name}/{item}') != f'{name}/{item}': continue
                publish(tid, desired, ('progress',) if item in parents else (), f'{name}/{item}', hold_reason, f'Stage: {said}\n\n{body.strip()}'.strip() if said != stage else body.strip())
        if options.tidy:
            print(tidy_report(items, homes, home, state, options.apply, run)); return
        if options.cleanup:
            carded = {d['ticket'] for d in json.loads(run(['sign-off-axi', 'list', str(board), '--json'])).get('decisions', []) if d.get('ticket')}
            def cards():
                # Waiting sign-off cards whose source is closed are archived; the rest go to Main in one short list.
                now = dt.datetime.now(dt.timezone.utc)
                by_id = {}
                for it in items: by_id.setdefault(it['row']['id'], []).append(it['row'])
                ctx = dict(tickets=existing, items={i: r[0] for i, r in by_id.items() if len(r) == 1}, prs={}, run=run)
                def log(message):
                    with (state / 'card-reconcile.log').open('a') as out: out.write(f'{now:%Y-%m-%d} {message}\n')
                dismissed, kept, unclear = reconcile.reconcile(json.loads(run(['sign-off-axi', 'list', str(board), '--json'])).get('decisions', []), ctx, now, board, run, log)
                (state / 'cards-unclear.txt').write_text(''.join(f'{k} - {t} - {w}\n' for k, t, w in unclear))
                return f'\ncards: {dismissed} archived, {kept} kept (source open), {len(unclear)} for Main' + ''.join(f'\n  {k} - {t[:70]} - {w}' for k, t, w in unclear[:8]) + (f'\n  +{len(unclear) - 8} more in state/tickets-sync/cards-unclear.txt' if len(unclear) > 8 else '')
            line = cleanup.daily(items, dt.datetime.now(dt.timezone.utc).date(), state, board, home, run, carded, cards)
            if line: print(line)
            return
        # The walk has read every home: the next pass starts a new one.
        save(cursor, {})
        if options.check:
            for tid, old in existing.items():
                if tid.startswith('jg-') and tid not in seen and (old.get('state') or '') != 'done':
                    print(f"tickets-check: {str(old.get('title'))[:70]} ticket says {old.get('state') or 'no state'}, but no home's work accounts for it")
            return
        if changed or skipped_ids:
            # A count is a routine result: it goes to the log. A skipped record is a finding with an act for this home
            # (fix that record), so the skip line printed above and the count with it wake the check's reader.
            summary = f'tickets-sync: {len(homes)} homes read; {changed} tickets changed'
            if skipped_ids: print(summary)
            else: note(summary)

if __name__ == '__main__':
    try: sync()
    except TICKET_ERRORS as error:
        print(f'tickets-sync: {error}', file=sys.stderr)
        sys.exit(1)

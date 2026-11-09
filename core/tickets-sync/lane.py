"""A ticket leaf's stage from the task and delivery machines, plus its lane/PR evidence; backlog prose references are not completion evidence."""
import datetime as dt
import functools
import os
import re
import subprocess as sp
import time

PR = re.compile(r'https://github\.com/([\w.-]+/[\w.-]+)/pull/([1-9]\d*)\b')


def evidence(source, item, row):
    """Whether the lane or the item says the work was dropped, and the delivery PR the records link; never the stage."""
    state = source / 'state'
    meta = state / (item + '.meta')
    status = state / (item + '.status')
    props = dict(line.split('=', 1) for line in meta.read_text().splitlines() if '=' in line) if meta.exists() else {}
    lines = status.read_text().splitlines() if status.exists() else []
    terminal, link = False, ''
    for line in lines:
        verb = re.match(r'^(?:\d+\s+)?([a-z-]+)\b', line)
        verb = verb[1] if verb else ''
        if verb == 'done':
            match = PR.search(line)
            if match: link = match[0]
        if verb in ('superseded', 'cancelled', 'canceled'): terminal = True
        if verb in ('working', 'reopened'): terminal = False
    body = row.get('body', '')
    explicit = re.search(r'^\s*(?:status|resolution):\s*(superseded|cancelled|canceled)\b', body, re.M | re.I)
    own = re.search(r'^\s*pr:\s*(' + PR.pattern + ')', body, re.M | re.I)
    # Title/links are task delivery links; arbitrary URLs inside notes may be prerequisites.
    match = PR.search(row.get('links', '') + '\n' + row['title'])
    link = props.get('pr') or (own[1] if own else '') or (match[0] if match else '') or link
    return terminal or bool(explicit), link


# The board's stage words until it accepts the machines' own (slice C2): each machine word's nearest board stage. The
# exact word travels in the ticket's description, so the board shows both. A word not listed here is the worker's own.
BOARD_STAGE = {'queued': 'queued', 'done': 'merging', 'ready-to-land': 'merging', 'cleaned': 'merging', 'landed': 'merging', 'in-homes': 'merging',
               'in-homes-off': 'merging', 'in-use': 'merging', 'reverted': 'merging'}


def machine(home, source, script, *args):
    """One read-only machine observer (core/machines/observers) run on `source`'s records; empty when it cannot answer."""
    path = home / 'core/machines/observers' / script
    if not path.is_file(): return ''
    env = {k: v for k, v in os.environ.items() if k not in ('JG_DATA_OVERRIDE', 'JG_STATE_OVERRIDE', 'JG_ROOT_OVERRIDE')}
    env['JG_HOME'] = str(source)
    try: out = sp.run(['bash', str(path), *args], env=env, text=True, capture_output=True, timeout=30).stdout
    except (OSError, sp.TimeoutExpired): return ''
    return out.strip()


def landed_commit(source, item):
    """The trunk commit the lander recorded for this lane (data/trunk-landings.tsv: id, project, commit, epoch, kind)."""
    file = source / 'data/trunk-landings.tsv'
    rows = [line.split('\t') for line in file.read_text().splitlines()] if file.exists() else []
    return next((r[2] for r in reversed(rows) if len(r) > 2 and r[0] == item), '')


@functools.lru_cache(maxsize=None)
def deliveries(home, source):
    """{trunk commit: delivery word} for each registered change that has landed, read once per pass."""
    found = {}
    for change in machine(home, source, 'delivery.sh', 'ids').split():
        detail = dict(line.split('\t', 1) for line in machine(home, source, 'delivery.sh', 'detail', change).splitlines() if '\t' in line)
        if detail.get('commit') and detail.get('state') != 'unlanded': found[detail['commit']] = detail['state']
    return found


def word(home, source, item, row):
    """What the task machine says this lane is; a delivered lane says where its change stands (in-homes, in-use, ...).

    An item that no worker or lander has a record of has not started, so only a lane with a record is asked. The delivery
    machine answers for a registered change, so a landed lane reads its word only when its commit is one."""
    state, landing = source / 'state', source / 'data/jg-trunk-landing'
    if not ((state / (item + '.meta')).exists() or (state / (item + '.status')).exists() or any(landing.glob(item + '.*.state'))):
        return 'queued'
    task = machine(home, source, 'task.sh', item) or 'working'
    if task in ('landed', 'cleaned'): return deliveries(home, source).get(landed_commit(source, item), task)
    return task


NO_WORKER = 'no worker yet'


def assignee(source, item, owner, ran=False):
    """Who owns a ticket and what runs it, from this home's own records and never typed by hand.

    The owner is never blank: the lead the record names when it names one, else the home that owns the item, so a
    fleet-wide item with no owning lead still says who answers for it. The tool fields come from the lane meta whether
    a worker is live or the last one has gone - its harness (the board draws this as the tool), its model, its effort
    and the account it runs under - because a queued ticket still needs to show what ran it. An item no worker has ever
    run says so in words instead of leaving the fields empty; ran says the caller already knows one did."""
    state = source / 'state'
    meta = state / (item + '.meta')
    props = dict(line.split('=', 1) for line in meta.read_text().splitlines() if '=' in line) if meta.exists() else {}
    status = state / (item + '.status')
    last = next((line for line in reversed(status.read_text().splitlines()) if line.strip()), '') if status.exists() else ''
    verb = re.match(r'^(?:\d+\s+)?([a-z-]+)\b', last)
    live = bool(props.get('window') or props.get('endpoint')) and not (state / (item + '.exit')).exists() \
        and (verb[1] if verb else '') not in ('done', 'failed')
    who = {'lead': props.get('lead') or props.get('owner') or owner, 'live': live}
    # A status file is the record that a worker ran; the meta that names it is removed at cleanup, so a gone record
    # means "not recorded", never "no worker yet".
    ran = ran or status.exists()
    for field, key in (('model', 'model'), ('harness', 'tool'), ('effort', 'effort')):
        if props.get(field): who[key] = props[field]; ran = True
    # A record may name the account by its folder; the board shows the name, never a path on this machine.
    account = props.get('account', '').rstrip('/').rsplit('/', 1)[-1]
    if account:
        who['account'] = who['worker'] = account
        who['worker_id'] = props.get('endpoint_task_id') or item
        ran = True
    if not ran:
        for key in ('worker', 'model', 'tool', 'effort'): who[key] = NO_WORKER
    return who


def newest_event(source, item, row):
    """Newest status [at=] stamp; else the start of the backlog closed/created day (UTC); None when unknown.

    A backlog record carries a date and no time, so the day's first hour is the only stamp it can honestly claim: any
    later hour would put the update in the future and hold off the board's six-hour stall line by that much, which is
    how a queued item with no worker showed nothing but 0% for fifteen hours."""
    status = source / 'state' / (item + '.status')
    if status.exists():
        stamps = [int(m) for m in re.findall(r'\[at=(\d+)\]', status.read_text())]
        if stamps: return max(stamps)
    stamps = []
    for key in ('closed', 'created'):
        raw = row.get(key) or ''
        if raw in ('', '-'): continue
        try:
            day = dt.date.fromisoformat(raw[:10])
        except ValueError:
            continue
        stamps.append(int(dt.datetime(day.year, day.month, day.day, tzinfo=dt.timezone.utc).timestamp()))
    return max(stamps) if stamps else None


def stage(home, source, item, row, cache, run):
    """(machine word, board stage, done, PR link, newest event) for one ticket leaf."""
    terminal, link = evidence(source, item, row)
    done = row['state'] == 'done' or terminal
    match = PR.fullmatch(link)
    old = {}
    if match and not done:
        old = cache.get(link, {})
        # A merged or closed PR never reopens, so a read that proved one is kept and the sync stops re-asking GitHub for
        # a row it can no longer learn anything about; only an open PR is re-read on the five-minute refresh.
        settled = old.get('merged') or old.get('state') == 'closed'
        if not settled and time.time() - old.get('at', 0) >= 300:
            result = run(['gh-axi', 'api', f'repos/{match[1]}/pulls/{match[2]}', '--jq', '{merged,state,draft}'])
            values = dict(re.findall(r'^(merged|state|draft): (\S+)$', result, re.M))
            if set(values) != {'merged', 'state', 'draft'}:
                raise RuntimeError('unreadable GitHub PR state for ' + link + ': ' + result)
            old = dict(merged=values['merged'] == 'true', state=values['state'], draft=values['draft'] == 'true', at=time.time())
            cache[link] = old
        done = old['merged']
    said = 'done' if done else word(home, source, item, row)
    # A worker's own PR in review is the one thing the board's stage knows that the task machine does not.
    review = said == 'working' and old.get('state') == 'open' and not old.get('draft')
    return said, 'review' if review else BOARD_STAGE.get(said, 'done' if done else 'building'), done, link, newest_event(source, item, row)

#!/usr/bin/env python3
"""Turn a copy of every home's tickets into Beads import files, then move one home at a time and back.

  jg-beads-migrate.py copy --main <home> --to <dir>   copy feed and backlogs; the only read of a real home
  jg-beads-migrate.py plan --copy <dir> --out <dir>   write <home>.jsonl, <home>.prefixes, manifest.json and settle.json
  jg-beads-migrate.py verify --copy <dir> --out <dir> --runs <dir> [--home <home>]   judge a dry run; exit 1 on a mismatch
  jg-beads-migrate.py cut --home <name> --dir <home folder> --copy <dir> --out <dir> --store <BEADS_DIR> --order <text>
  jg-beads-migrate.py back --dir <home folder> [--drop-new-writes]

One row per piece of work: fm-/jg- twins collapse to jg-<hash>. The home's source row wins on status, title and
hold, on single rows too, because the board feed only mirrors it; with no source row the newest `at` twin wins.
A hold the winner drops stays visible as metadata.past_hold plus a hold-dropped-by-* label, for a person to settle.
The upkeep bucket is not imported: its children carry the `upkeep` label. A held row with no reason gets the
hold-reason-missing label. Inline blocked-by becomes a `blocks` dependency, and a hold with hold-until is a deferred
row with that date as defer_until, so bd returns it by itself.
A linked-to: or parent: line becomes an edge (bin/jg-beads-links.py); a name no row answers to is metadata.linked_to with the link-unresolved label.
manifest.json records every row and the disposition of every held row, so a dry run has something to match.

Settling: a row with no home parks under main with the `unplaced` label. A row of a home in data/parked, or of a lead
the registry no longer names, parks under main with a `parked-home:<name>` label. A remote home keeps its own import
file and `cut` refuses it, so it stays on the old path until proved. settle.json lists each group a person should read.

`cut` moves one home and only `--order`, the text of the order to do so, lets it start. It takes data/backlog.md.lock,
a non-empty lock every backlog writer refuses on and no reclaim touches, so writes stop for the whole cut and the old
files can never move again. It refuses if those files differ from the copy, then imports through bin/jg-beads.sh into a
fresh store, checks the export and counts against the manifest, runs `jg-beads.sh check`, writes config/beads-dir,
reads every row back through bin/jg-tasks-axi.sh, and makes the old files read-only.
data/beads-cut.json records each phase and what the home held. A failed step undoes the cut; a killed one leaves the
record, and `back` finishes the undo. Running `cut` again on a finished home changes nothing.

`back` restores both config files exactly, the old files' modes and the lock, and moves the store aside, never deleting
it. It compares the store with its export at the cut: rows written since are saved to data/beads-after-cut.<at>.jsonl
and named, and it refuses unless --drop-new-writes says those rows stay out of the old files.
"""
import argparse, base64, collections, csv, glob, hashlib, json, os, re, shutil, subprocess, sys, time

NO_REASON = 'no reason recorded before migration'
STATUSES = ('open', 'in_progress', 'on_hold', 'deferred', 'closed')
HELD = ('on_hold', 'deferred')
FILES = ('backlog.md', 'done-archive.md')
HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
links = __import__('jg-beads-links')
TAG = r'\s*\((?:repo|kind|priority|since|done|merged|hold|until|hold-kind|hold-until)[: ][^)]*\)'

def registry(main):
    homes, remote, parked = {'main': main}, [], {}
    path = os.path.join(main, 'data/squad_leads.md')
    for line in open(path) if os.path.exists(path) else []:
        m = re.match(r'- (\S+) - .*\(home: ([^;]+);', line)
        if m: homes[m[1]] = m[2]
        elif re.match(r'- \S+ - .*\(host:', line): remote.append(line.split()[1])
    for meta in sorted(glob.glob(os.path.join(main, 'data/parked/*.meta'))):
        name = os.path.basename(meta)[:-5]
        m = re.search(r'^home=(.+)$', open(meta, errors='replace').read(), re.M)
        if m and name not in homes and name not in remote: parked[name] = m[1].strip()
    return homes, remote, parked

def copy(a):
    homes, remote, parked = registry(a.main)
    board = open(os.path.join(a.main, 'config/fleet-board')).read().strip()
    os.makedirs(a.to, exist_ok=True)
    shutil.copy(os.path.join(os.path.dirname(board), 'board.tickets.jsonl'), a.to)
    for name, path in {**homes, **parked}.items():
        os.makedirs(f'{a.to}/homes/{name}', exist_ok=True)
        for f in FILES:
            if os.path.exists(f'{path}/data/{f}'): shutil.copy(f'{path}/data/{f}', f'{a.to}/homes/{name}/')
    json.dump({'homes': sorted(homes), 'remote': remote, 'parked': parked}, open(f'{a.to}/registry.json', 'w'))

def suffix(i): return i[3:] if i[:3] in ('jg-', 'fm-') else i
def digest(home, item): return hashlib.sha256(f'{home}/{item}'.encode()).hexdigest()[:32]
def slug(s): return re.sub(r'[^\w.-]', '-', s)
def is_held(r): return r.get('state') == 'on hold' or r.get('hold') is True

def decode(text):
    m = re.match(r'(?:fm|jg)-hold-v1:([A-Za-z0-9+/=_-]+)', text.strip())
    return base64.b64decode(m[1] + '==').decode('utf8', 'replace') if m else text.strip()

def sources(reg): return reg['homes'] + list(reg.get('parked', {}))

def read_feed(copy_dir):
    rows = {}
    for line in open(f'{copy_dir}/board.tickets.jsonl'):
        r = json.loads(line)
        if 'id' in r: rows[r['id']] = r
    return rows

def read_sources(copy_dir, homes):
    src = {}
    for home in homes:
        for f in FILES:
            path, sec, cur = f'{copy_dir}/homes/{home}/{f}', None, None
            for line in open(path, errors='replace') if os.path.exists(path) else []:
                line = line.rstrip('\n')
                m = re.match(r'- \[(.)\] (\S+)(?: - )?(.*)', line)
                if line.startswith('## '): sec, cur = line[3:].strip(), None
                elif m:
                    cur = src[digest(home, m[2])] = parse_item(home, f, sec, m)
                elif cur and line.startswith(' '):
                    p = re.match(r'\s+parent: (\S+)', line)
                    if p: cur['parent'] = p[1]
                    else: cur['body'].append(line.strip())
    return src

def parse_item(home, f, sec, m):
    rest = m[3]
    tag = lambda k: (re.search(rf'\({k}:? ([^)]*)\)', rest) or [None, None])[1]
    closed = m[1] == 'x' or f == 'done-archive.md' or sec == 'Done'
    hold = tag('hold')
    hold = decode(hold) if hold is not None else None
    status = ('closed' if closed else ('deferred' if tag('hold-until') else 'on_hold') if hold is not None
              else 'in_progress' if sec == 'In flight' else 'open')
    title = re.sub(r'\s*blocked-by: \S+', '', re.sub(TAG, '', rest)).strip()
    return dict(home=home, item=m[2], title=title or m[2], status=status, hold=hold, file=f, body=[], parent=None,
                blocked=re.findall(r'blocked-by: ([^\s)]+)', rest), repo=tag('repo'), priority=tag('priority'), kind=tag('kind'),
                when=tag('done') or tag('merged') or tag('since'), hold_kind=tag('hold-kind'),
                hold_until=tag('hold-until'), prs=re.findall(r'https://\S+/pull/\d+', rest))

def feed_status(r):
    if is_held(r): return 'on_hold'
    return {'done': 'closed', 'in progress': 'in_progress'}.get(r.get('state'), 'open')

def stamp(text, fallback='2026-01-01'):
    m = re.search(r'\d{4}-\d\d-\d\d', text or '')
    return (m[0] if m else fallback) + 'T00:00:00Z' if m or fallback else None

def break_cycles(rows, linked=()):
    """bd skips an edge that closes a cycle or blocks a row on its own ancestor; record those instead, keeping parents.
    An edge a body line asked for stays as related, which closes no cycle, so the link survives."""
    edges, up = collections.defaultdict(set), collections.defaultdict(set)
    def reaches(graph, start, goal):
        seen, todo = set(), [start]
        while todo:
            n = todo.pop()
            if n == goal: return True
            if n not in seen: seen.add(n); todo += graph[n]
        return False
    pairs = [(r, d) for r in rows for d in r.get('dependencies', []) if d['type'] != 'related']
    for r, d in sorted(pairs, key=lambda p: p[1]['type'] != 'parent-child'):
        i, j = r['id'], d['depends_on_id']
        if (reaches(edges, j, i) or reaches(up, i, j)) and (i, j) in linked:
            d['type'] = 'related'
        elif reaches(edges, j, i) or reaches(up, i, j):
            r['dependencies'].remove(d)
            r['metadata'].setdefault('dep_dropped', []).append(j)
            if 'dependency-dropped' not in r['labels']: r['labels'].append('dependency-dropped')
        else:
            edges[i].add(j)
            if d['type'] == 'parent-child': up[i].add(j)

def lay_lines(rows):
    """Turn each body line into an edge among this home's rows, and record the names no row here answers to."""
    linked = set()
    for r, other, kind, word in links.pending({r['id']: r for r in rows}):
        if other:
            one, two, kind = links.edge(r, other, kind)
            links.join(one, two, kind)
            linked.add((one['id'], two['id']))
        else:
            r['metadata'].setdefault('linked_to', []).append(word)
            if 'link-unresolved' not in r['labels']: r['labels'].append('link-unresolved')
    return linked

def plan(a):
    reg = json.load(open(f'{a.copy}/registry.json'))
    feed, src = read_feed(a.copy), read_sources(a.copy, sources(reg))
    groups = collections.defaultdict(list)
    for i in feed: groups[suffix(i)].append(i)
    for ids in groups.values(): ids.sort(key=lambda i: (feed[i]['at'], i.startswith('jg-')), reverse=True)
    buckets = {k for k, ids in groups.items() if feed[ids[0]]['title'].startswith('Not from your asks')}
    keys = (set(groups) | set(src)) - buckets
    canon = {k: groups[k][0] if len(groups.get(k, [])) == 1 else 'jg-' + k for k in keys}
    pick = lambda k, f: next((feed[i][f] for i in groups.get(k, []) if feed[i].get(f)), None)

    def parent_key(k):
        s = src.get(k)
        if s and s['parent']: return 'upkeep' if s['parent'] == 'upkeep' else digest(s['home'], s['parent'])
        return suffix(pick(k, 'parent')) if pick(k, 'parent') else None

    home, how = {}, {}
    for k in keys:
        lead = (pick(k, 'assignee') or {}).get('lead')
        home[k], how[k] = (src[k]['home'], 'source') if k in src else (lead, 'lead') if lead else (None, 'none')
    kids = collections.defaultdict(collections.Counter)
    for k in keys:
        if parent_key(k) in keys and home[k]: kids[parent_key(k)][home[k]] += 1
    for k in keys:
        if not home[k] and kids[k]: home[k], how[k] = kids[k].most_common(1)[0][0], 'children'
    parked = {k: home[k] for k in keys if home[k] not in reg['homes'] + reg['remote']}
    home.update({k: 'main' for k in parked})

    out, man, held = collections.defaultdict(list), {}, {}
    settle = collections.defaultdict(list)
    for k in sorted(keys):
        ids, s, i, h = groups.get(k, []), src.get(k), canon[k], home[k]
        w = feed[ids[0]] if ids else {}
        status = s['status'] if s else feed_status(w)
        reason = next((decode(x) for x in [(s or {}).get('hold')] + [feed[j].get('hold_reason') for j in ids] if x and x.strip()), '')
        md = {'legacy_id': ids[0] if ids else i, 'home': h, 'home_from': how[k], 'source_status': s and s['status'],
              'feed_state': w.get('state'), 'stage': w.get('stage'), 'progress': w.get('progress'), 'asked': bool(pick(k, 'asked')),
              'agent': pick(k, 'assignee'), 'prs': pick(k, 'prs') or (s or {}).get('prs') or [], 'release': pick(k, 'release'), 'feed_at': w.get('at')}
        labels = [f'home:{h}']
        if k in parked:
            labels.append(f'parked-home:{parked[k]}' if parked[k] else 'unplaced')
            if parked[k]: md['parked_from'] = parked[k]
        if len(ids) == 2: md['legacy_twin'] = ids[1]
        if s: md['legacy_item'] = s['item']
        if s and ids and w['title'] != s['title']: md['feed_title'] = w['title']
        if not ids: labels.append('not-on-board')
        elif not w.get('state') and not s: labels.append('state-missing')
        project = pick(k, 'project') or (s or {}).get('repo')
        if project: labels.append('project:' + slug(project))
        was_held = any(is_held(feed[j]) for j in ids) or (s and s['hold'] is not None and s['status'] != 'closed')
        if status in HELD:
            md['hold_reason'] = reason or NO_REASON
            if not reason: labels.append('hold-reason-missing')
            if s and s['hold_kind']: md['hold_kind'] = s['hold_kind']
            disposition = 'on_hold'
        elif was_held:
            md['past_hold'] = reason or NO_REASON
            disposition = 'dropped-by-source' if s else 'dropped-by-newer-twin'
            labels.append('hold-' + disposition)
        elif reason: md['past_hold'] = reason
        when = w.get('at') or stamp(s['when'])
        title = s['title'] if s else w['title']
        if len(title) > 480: md['full_title'] = title
        row = {'id': i, 'title': title[:480], 'status': status, 'metadata': md, 'labels': labels,
               'issue_type': {'bug': 'bug', 'epic': 'epic'}.get(w.get('type'), 'task'), 'created_at': when, 'updated_at': when,
               'priority': int(s['priority']) if s and (s['priority'] or '') in tuple('01234') else int(pick(k, 'priority')[1]) if pick(k, 'priority') else 2,
               'description': pick(k, 'description') or '\n'.join((s or {}).get('body', []))}
        if status == 'closed':
            row['closed_at'] = (s and stamp(s['when'], None)) or when
            row['close_reason'] = 'migrated: ' + ('source done' if s else 'feed state done')
        if md['prs']: row['external_ref'] = md['prs'][0]
        if s and status != 'closed' and stamp(s['hold_until'], None): row['defer_until'] = stamp(s['hold_until'], None)
        deps, p = [], parent_key(k)
        if p == 'upkeep' or p in buckets: labels.append('upkeep'); md['legacy_parent'] = 'upkeep'
        elif p and p not in keys: labels.append('parent-dangling'); md['legacy_parent'] = p
        elif p and p != k and home[p] != h:
            labels.append('parent-other-home'); md['legacy_parent'] = canon[p]; md['parent_home'] = home[p]
        elif p and p != k: deps.append({'issue_id': i, 'depends_on_id': canon[p], 'type': 'parent-child'})
        for item in (s or {}).get('blocked', []):
            b = digest(s['home'], item)
            if b in keys and b != k and home[b] == h: deps.append({'issue_id': i, 'depends_on_id': canon[b], 'type': 'blocks'})
            else: md.setdefault('blocked_by', []).append(item)
        if 'blocked_by' in md: labels.append('blocked-by-unresolved')
        if deps: row['dependencies'] = deps
        out[h].append(row)
        man[i] = {'home': h, 'status': status, 'deps': len(deps), 'legacy': ids, 'live_blocked': len(md.get('blocked_by', [])) if status != 'closed' else 0}
        if was_held or status in HELD:
            for j in [j for j in ids if is_held(feed[j])] or [i]: held[j] = {'row': i, 'disposition': disposition}
        note = {'id': i, 'home': h, 'title': row['title'], 'item': s and s['item'], 'status': status, 'source_status': s and s['status']}
        board_held = any(is_held(feed[j]) for j in ids)
        for group, hit in (('unplaced', k in parked and not parked[k]), ('unplaced_held', k in parked and not parked[k] and was_held),
                           ('no_reason', status in HELD and not reason), ('no_reason_past', status not in HELD and md.get('past_hold') == NO_REASON),
                           ('held_not_on_board', status in HELD and not ids), ('held_no_source_row', board_held and not s),
                           ('held_not_in_source', board_held and s and s['status'] not in HELD),
                           (f'parked:{parked.get(k)}', parked.get(k)), (f"remote:{h}", h in reg['remote'])):
            if hit: settle[group].append(note)
    held.update({j: {'row': None, 'disposition': 'dropped-upkeep-bucket'} for k in buckets for j in groups[k] if is_held(feed[j])})
    os.makedirs(a.out, exist_ok=True)
    for h, rows in out.items():
        break_cycles(rows, lay_lines(rows))
        for r in rows: man[r['id']]['deps'] = len(r.get('dependencies', []))
        rows.sort(key=lambda r: bool(r.get('dependencies')))
        with open(f'{a.out}/{h}.jsonl', 'w') as f:
            for r in rows: f.write(json.dumps(r) + '\n')
        open(f'{a.out}/{h}.prefixes', 'w').write(','.join(sorted({r['id'].split('-')[0] for r in rows})))
    json.dump({'rows': man, 'held': held, 'buckets': sorted(buckets)}, open(f'{a.out}/manifest.json', 'w'))
    json.dump(settle, open(f'{a.out}/settle.json', 'w'), indent=1)
    print('settle:', ' '.join(f'{g}={len(settle[g])}' for g in sorted(settle)) or 'nothing')

def verify(a):
    man = json.load(open(f'{a.out}/manifest.json'))
    reg = json.load(open(f'{a.copy}/registry.json'))
    feed, src, bad = read_feed(a.copy), read_sources(a.copy, sources(reg)), []
    homes = [a.home] if a.home else sorted({m['home'] for m in man['rows'].values()})
    exported, table = {}, []
    for h in homes:
        rows = {r['id']: r for r in map(json.loads, open(f'{a.runs}/{h}.export.jsonl')) if r.get('id')}
        want = {i: m for i, m in man['rows'].items() if m['home'] == h}
        exported.update(rows)
        bad += [f'{h}: {i} missing from the store' for i in want.keys() - rows.keys()]
        bad += [f'{h}: {i} in the store but not the manifest' for i in rows.keys() - want.keys()]
        for i in want.keys() & rows.keys():
            if rows[i]['status'] != want[i]['status']: bad.append(f"{h}: {i} is {rows[i]['status']}, manifest says {want[i]['status']}")
            if f'home:{h}' not in rows[i].get('labels', []): bad.append(f'{h}: {i} lost its home label')
            if len(rows[i].get('dependencies') or []) != want[i]['deps']: bad.append(f'{h}: {i} dependency count differs')
        bad += [f'{h}: {r["id"]} names {word} in a line with no edge' for r, _, _, word in links.pending(rows)]
        counted = dict(l.split() for l in open(f'{a.runs}/{h}.counts'))
        n = collections.Counter(m['status'] for m in want.values())
        bad += [f"{h}: bd counts {counted.get(s)} {s}, manifest {n[s]}" for s in STATUSES if int(counted.get(s, -1)) != n[s]]
        table.append((h, len(want), *(n[s] for s in STATUSES), sum('hold-reason-missing' in rows.get(i, {}).get('labels', []) for i in want)))
    if not a.home:
        keys = {suffix(i) for i in feed} | set(src)
        if len(man['rows']) + len(man['buckets']) != len(keys): bad.append(f"census: {len(man['rows'])} rows + {len(man['buckets'])} buckets, the copy holds {len(keys)}")
        must = {i for i, r in feed.items() if is_held(r)}
        must |= {'jg-' + k for k, s in src.items() if s['status'] in HELD and not ({'jg-' + k, 'fm-' + k} & feed.keys())}
        bad += [f'held: {i} has no disposition' for i in sorted(must - man['held'].keys())]
        for i, d in man['held'].items():
            md = exported.get(d['row'], {}).get('metadata') or {}
            if d['disposition'] == 'on_hold' and not (exported.get(d['row'], {}).get('status') in HELD and str(md.get('hold_reason', '')).strip()): bad.append(f'held: {i} lost its hold or reason')
            if d['disposition'].startswith('dropped-by') and not str(md.get('past_hold', '')).strip(): bad.append(f'held: {i} dropped with no trace')
        print('home rows ' + ' '.join(STATUSES) + ' no_reason')
        for t in table: print(*t)
        print('total', *(sum(t[c] for t in table) for c in range(1, 7)))
        print('feed ids', len(feed), 'twins collapsed', sum(len(m['legacy']) == 2 for m in man['rows'].values()),
              'dropped holds', collections.Counter(d['disposition'] for d in man['held'].values()), 'live unresolved blockers', sum(m['live_blocked'] for m in man['rows'].values()))
    for line in bad[:40]: print(line, file=sys.stderr)
    return 1 if bad else 0

class Stop(Exception):
    """A refusal: main prints it and exits 1, and the home is as the cut found it."""

def sha(path):
    return hashlib.sha256(open(path, 'rb').read()).hexdigest()

def text_of(path):
    return open(path).read() if os.path.exists(path) else None

def put(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + '.new', 'w') as f: f.write(text)
    os.replace(path + '.new', path)

def save(rec, phase):
    rec['phase'] = phase
    put(f"{rec['dir']}/data/beads-cut.json", json.dumps(rec, indent=1))

def beads(store, *args):
    run = subprocess.run([f'{HERE}/jg-beads.sh', *args], capture_output=True, text=True,
                         env={**os.environ, 'BEADS_DIR': store, 'BEADS_ACTOR': 'migrate-cut'})
    if run.returncode: raise Stop(f"jg-beads.sh {args[0]} failed: {(run.stderr or run.stdout).strip()[-400:]}")
    return run.stdout

def tasks(home_dir, *args):
    env = {k: v for k, v in os.environ.items() if k not in ('BEADS_DIR', 'JG_DATA_OVERRIDE', 'JG_CONFIG_OVERRIDE', 'JG_STATE_OVERRIDE')}
    run = subprocess.run([f'{HERE}/jg-tasks-axi.sh', *args], capture_output=True, text=True, env={**env, 'JG_HOME': home_dir})
    if run.returncode: raise Stop(f"jg-tasks-axi.sh {args[0]} failed: {(run.stderr or run.stdout).strip()[-400:]}")
    return run.stdout

def read_back(a, home_dir):
    """Every planned row reads through the worker's own reader, and a closed row keeps its title and close day."""
    view = {r['id']: r for r in map(json.loads, open(f'{a.out}/{a.home}.jsonl'))}
    lines = tasks(home_dir, 'list', '--full', '--fields', 'closed').splitlines()
    got = {c[0]: c for c in csv.reader((l.strip() for l in lines if l.startswith('  ') and not l.startswith('  - ')), escapechar='\\', doublequote=False)}
    if got.keys() != view.keys(): raise Stop(f'read back {len(got)} rows, planned {len(view)}: {sorted(got.keys() ^ view.keys())[:5]}')
    for i, r in view.items():
        if r['status'] != 'closed': continue
        if got[i][1] != 'done' or got[i][4] != r['title'] or got[i][5] == '-': raise Stop(f'closed row {i} reads back as {got[i]}')
    return len(got)

def cut(a):
    home_dir, h = os.path.abspath(a.dir), a.home
    path, lock = f'{home_dir}/data/beads-cut.json', f'{home_dir}/data/backlog.md.lock'
    if not a.order.strip(): raise Stop('--order must carry the text of the order to cut this home')
    if os.path.exists(path):
        rec = json.load(open(path))
        if rec['phase'] == 'cut' and rec['home'] == h:
            print(f'{h}: already cut')
            return 0
        raise Stop(f"{h}: an unfinished cut stopped at {rec['phase']}; run `back` first")
    reg, man = json.load(open(f'{a.copy}/registry.json')), json.load(open(f'{a.out}/manifest.json'))
    want = [i for i, m in man['rows'].items() if m['home'] == h]
    if h in reg['remote']: raise Stop(f'{h}: a remote home stays on the old path until proved')
    if h in reg.get('parked', {}): raise Stop(f'{h}: a parked home has no store; its rows cut with main')
    if not want or not os.path.exists(f'{a.out}/{h}.jsonl'): raise Stop(f'{h}: not in this plan')
    if (text_of(f'{home_dir}/config/beads-dir') or '').strip(): raise Stop(f'{h}: this home already reads a Beads store')
    store = os.path.abspath(a.store)
    parent = os.path.dirname(store)
    if os.path.basename(store) != '.beads': raise Stop('--store must be a BEADS_DIR, a path ending in .beads')
    if os.path.exists(parent) and os.listdir(parent): raise Stop(f'{parent} is not empty; a cut needs a fresh store')
    token = f'beads-cut {h} {int(time.time())}\n'
    config = {n: text_of(f'{home_dir}/config/{n}') for n in ('beads-dir',)}
    try:
        fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
    except FileExistsError:
        raise Stop(f'{lock} is held; a writer is busy or a cut is unfinished') from None
    os.write(fd, token.encode()); os.close(fd)
    live = [f for f in FILES if os.path.exists(f'{home_dir}/data/{f}')]
    rec = {'home': h, 'dir': home_dir, 'store': store, 'plan': os.path.abspath(a.out), 'order': a.order, 'at': int(time.time()), 'token': token, 'config': config,
           'files': {f: {'sha256': sha(f'{home_dir}/data/{f}'), 'mode': os.stat(f'{home_dir}/data/{f}').st_mode & 0o7777} for f in live}}
    save(rec, 'frozen')
    try:
        known = {f for f in FILES if os.path.exists(f'{a.copy}/homes/{h}/{f}')}
        if known != set(live) or any(sha(f'{a.copy}/homes/{h}/{f}') != rec['files'][f]['sha256'] for f in live):
            raise Stop(f'{h}: the old files changed since the copy; copy and plan again')
        for name, where in reg.get('parked', {}).items() if h == 'main' else ():
            if any(os.path.exists(f'{where}/data/{f}') and sha(f'{where}/data/{f}') != sha(f'{a.copy}/homes/{name}/{f}') for f in FILES):
                raise Stop(f'parked home {name} changed since the copy; copy and plan again')
        runs = f'{parent}/cut'
        os.makedirs(runs)
        beads(store, 'init', '--prefix', 'jg')
        beads(store, 'config', 'set', 'status.custom', 'on_hold:frozen')
        beads(store, 'config', 'set', 'allowed_prefixes', open(f'{a.out}/{h}.prefixes').read())
        put(f'{runs}/{h}.import.log', beads(store, 'import', os.path.abspath(f'{a.out}/{h}.jsonl')))
        beads(store, 'export', '-o', 'export.jsonl')
        os.replace(f'{parent}/export.jsonl', f'{runs}/{h}.export.jsonl')
        put(f'{runs}/{h}.counts', ''.join(f"{s} {beads(store, 'count', '--status', s).strip()}\n" for s in STATUSES))
        if verify(argparse.Namespace(out=a.out, copy=a.copy, runs=runs, home=h)): raise Stop(f'{h}: the store differs from the manifest')
        beads(store, 'check')
        save(rec, 'verified')
        put(f'{home_dir}/config/beads-dir', store + '\n')
        save(rec, 'switched')
        count = read_back(a, home_dir)
        for f in live: os.chmod(f'{home_dir}/data/{f}', rec['files'][f]['mode'] & ~0o222)
        save(rec, 'cut')
    except BaseException as failed:
        print(f'{h}: cut stopped at {rec["phase"]}, going back: {failed}', file=sys.stderr)
        undo(rec, False)
        raise
    print(f'{h}: cut {count} rows into {store}')
    return 0

def rows_of(path):
    return {r['id']: r for r in map(json.loads, open(path)) if r.get('id')}

def undo(rec, drop):
    home_dir, store, h = rec['dir'], rec['store'], rec['home']
    parent, data = os.path.dirname(store), f"{rec['dir']}/data"
    if rec['phase'] in ('switched', 'cut'):
        beads(store, 'export', '-o', 'after.jsonl')
        now, then = rows_of(f'{parent}/after.jsonl'), rows_of(f'{parent}/cut/{h}.export.jsonl')
        moved = sorted(i for i in now.keys() | then.keys() if now.get(i) != then.get(i))
        shutil.copy(f'{parent}/after.jsonl', f"{data}/beads-after-cut.{rec['at']}.jsonl")
        if moved and not drop:
            raise Stop(f"{h}: {len(moved)} rows written since the cut stay in the store and data/beads-after-cut.{rec['at']}.jsonl: {moved[:10]}; "
                       'pass --drop-new-writes to leave them out of the old files')
    for name, text in rec['config'].items():
        target = f'{home_dir}/config/{name}'
        if text is not None: put(target, text)
        elif os.path.exists(target): os.unlink(target)
    for f, was in rec['files'].items():
        os.chmod(f'{data}/{f}', was['mode'])
        if sha(f'{data}/{f}') != was['sha256']: raise Stop(f'{h}: data/{f} changed under the lock; left locked for a person')
    if os.path.exists(parent): os.rename(parent, f'{parent}.back.{int(time.time())}')
    os.replace(f'{data}/beads-cut.json', f"{data}/beads-cut.{rec['at']}.back.json")
    if text_of(f'{data}/backlog.md.lock') == rec['token']: os.unlink(f'{data}/backlog.md.lock')
    print(f'{h}: back on the old files')

def back(a):
    data = f'{os.path.abspath(a.dir)}/data'
    if os.path.exists(f'{data}/beads-cut.json'):
        undo(json.load(open(f'{data}/beads-cut.json')), a.drop_new_writes)
    elif (text_of(f'{data}/backlog.md.lock') or '').startswith('beads-cut '):
        os.unlink(f'{data}/backlog.md.lock')  # a `back` killed after its last record write
    else:
        print('no cut to undo')
    return 0

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    c = sub.add_parser('copy'); c.add_argument('--main', required=True); c.add_argument('--to', required=True)
    c = sub.add_parser('plan'); c.add_argument('--copy', required=True); c.add_argument('--out', required=True)
    c = sub.add_parser('verify'); c.add_argument('--copy', required=True); c.add_argument('--out', required=True)
    c.add_argument('--runs', required=True); c.add_argument('--home')
    c = sub.add_parser('cut')
    for flag in ('--home', '--dir', '--copy', '--out', '--store'): c.add_argument(flag, required=True)
    c.add_argument('--order', default='')
    c = sub.add_parser('back'); c.add_argument('--dir', required=True); c.add_argument('--drop-new-writes', action='store_true')
    a = p.parse_args()
    try:
        return {'copy': copy, 'plan': plan, 'verify': verify, 'cut': cut, 'back': back}[a.cmd](a) or 0
    except Stop as refused:
        print(f'jg-beads-migrate: {refused}', file=sys.stderr)
        return 1

if __name__ == '__main__':
    sys.exit(main())

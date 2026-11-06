#!/usr/bin/env python3
"""Turn a copy of every home's tickets into Beads import files. Runs no bd and moves nothing live.

  jg-beads-migrate.py copy --main <home> --to <dir>   copy feed and backlogs; the only read of a real home
  jg-beads-migrate.py plan --copy <dir> --out <dir>   write <home>.jsonl, <home>.prefixes and manifest.json

One row per piece of work: fm-/jg- twins collapse to jg-<hash>. The home's source row wins on status, title and
hold, on single rows too, because the board feed only mirrors it; with no source row the newest `at` twin wins.
A hold the winner drops stays visible as metadata.past_hold plus a hold-dropped-by-* label, for a person to settle.
The upkeep bucket is not imported: its children carry the `upkeep` label. A held row with no reason gets the
hold-reason-missing label. Inline blocked-by becomes a `blocks` dependency and hold-until becomes defer_until.
manifest.json records every row and the disposition of every held row, so a dry run has something to match.
"""
import argparse, base64, collections, hashlib, json, os, re, shutil, sys

NO_REASON = 'no reason recorded before migration'
TAG = r'\s*\((?:repo|kind|priority|since|done|merged|hold|until|hold-kind|hold-until)[: ][^)]*\)'

def registry(main):
    homes, remote = {'main': main}, []
    path = os.path.join(main, 'data/squad_leads.md')
    for line in open(path) if os.path.exists(path) else []:
        m = re.match(r'- (\S+) - .*\(home: ([^;]+);', line)
        if m: homes[m[1]] = m[2]
        elif re.match(r'- \S+ - .*\(host:', line): remote.append(line.split()[1])
    return homes, remote

def copy(a):
    homes, remote = registry(a.main)
    board = open(os.path.join(a.main, 'config/fleet-board')).read().strip()
    os.makedirs(a.to, exist_ok=True)
    shutil.copy(os.path.join(os.path.dirname(board), 'board.tickets.jsonl'), a.to)
    for name, path in homes.items():
        os.makedirs(f'{a.to}/homes/{name}', exist_ok=True)
        for f in ('backlog.md', 'done-archive.md'):
            if os.path.exists(f'{path}/data/{f}'): shutil.copy(f'{path}/data/{f}', f'{a.to}/homes/{name}/')
    json.dump({'homes': sorted(homes), 'remote': remote}, open(f'{a.to}/registry.json', 'w'))

def suffix(i): return i[3:] if i[:3] in ('jg-', 'fm-') else i
def digest(home, item): return hashlib.sha256(f'{home}/{item}'.encode()).hexdigest()[:32]
def slug(s): return re.sub(r'[^\w.-]', '-', s)
def is_held(r): return r.get('state') == 'on hold' or r.get('hold') is True

def decode(text):
    m = re.match(r'(?:fm|jg)-hold-v1:([A-Za-z0-9+/=_-]+)', text.strip())
    return base64.b64decode(m[1] + '==').decode('utf8', 'replace') if m else text.strip()

def read_feed(copy_dir):
    rows = {}
    for line in open(f'{copy_dir}/board.tickets.jsonl'):
        r = json.loads(line)
        if 'id' in r: rows[r['id']] = r
    return rows

def read_sources(copy_dir, homes):
    src = {}
    for home in homes:
        for f in ('backlog.md', 'done-archive.md'):
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
    status = 'closed' if closed else 'on_hold' if hold is not None else 'in_progress' if sec == 'In flight' else 'open'
    title = re.sub(r'\s*blocked-by: \S+', '', re.sub(TAG, '', rest)).strip()
    return dict(home=home, item=m[2], title=title or m[2], status=status, hold=hold, file=f, body=[], parent=None,
                blocked=re.findall(r'blocked-by: ([^\s)]+)', rest), repo=tag('repo'), priority=tag('priority'),
                when=tag('done') or tag('merged') or tag('since'), hold_kind=tag('hold-kind'),
                hold_until=tag('hold-until'), prs=re.findall(r'https://\S+/pull/\d+', rest))

def feed_status(r):
    if is_held(r): return 'on_hold'
    return {'done': 'closed', 'in progress': 'in_progress'}.get(r.get('state'), 'open')

def stamp(text, fallback='2026-01-01'):
    m = re.search(r'\d{4}-\d\d-\d\d', text or '')
    return (m[0] if m else fallback) + 'T00:00:00Z' if m or fallback else None

def break_cycles(rows):
    """bd skips an edge that closes a cycle or blocks a row on its own ancestor; record those instead, keeping parents."""
    edges, up = collections.defaultdict(set), collections.defaultdict(set)
    def reaches(graph, start, goal):
        seen, todo = set(), [start]
        while todo:
            n = todo.pop()
            if n == goal: return True
            if n not in seen: seen.add(n); todo += graph[n]
        return False
    pairs = [(r, d) for r in rows for d in r.get('dependencies', [])]
    for r, d in sorted(pairs, key=lambda p: p[1]['type'] != 'parent-child'):
        i, j = r['id'], d['depends_on_id']
        if reaches(edges, j, i) or reaches(up, i, j):
            r['dependencies'].remove(d)
            r['metadata'].setdefault('dep_dropped', []).append(j)
            if 'dependency-dropped' not in r['labels']: r['labels'].append('dependency-dropped')
        else:
            edges[i].add(j)
            if d['type'] == 'parent-child': up[i].add(j)

def plan(a):
    reg = json.load(open(f'{a.copy}/registry.json'))
    feed, src = read_feed(a.copy), read_sources(a.copy, reg['homes'])
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
        home[k], how[k] = (src[k]['home'], 'source') if k in src else (lead, 'lead') if lead else ('unplaced', 'none')
    kids = collections.defaultdict(collections.Counter)
    for k in keys:
        if parent_key(k) in keys and home[k] != 'unplaced': kids[parent_key(k)][home[k]] += 1
    for k in keys:
        if home[k] == 'unplaced' and kids[k]: home[k], how[k] = kids[k].most_common(1)[0][0], 'children'

    out, man, held = collections.defaultdict(list), {}, {}
    for k in sorted(keys):
        ids, s, i, h = groups.get(k, []), src.get(k), canon[k], home[k]
        w = feed[ids[0]] if ids else {}
        status = s['status'] if s else feed_status(w)
        reason = next((decode(x) for x in [(s or {}).get('hold')] + [feed[j].get('hold_reason') for j in ids] if x and x.strip()), '')
        md = {'legacy_id': ids[0] if ids else i, 'home': h, 'home_from': how[k], 'source_status': s and s['status'],
              'feed_state': w.get('state'), 'stage': w.get('stage'), 'progress': w.get('progress'), 'asked': bool(pick(k, 'asked')),
              'agent': pick(k, 'assignee'), 'prs': pick(k, 'prs') or (s or {}).get('prs') or [], 'release': pick(k, 'release'), 'feed_at': w.get('at')}
        labels = [f'home:{h}']
        if len(ids) == 2: md['legacy_twin'] = ids[1]
        if s: md['legacy_item'] = s['item']
        if s and ids and w['title'] != s['title']: md['feed_title'] = w['title']
        if not ids: labels.append('not-on-board')
        elif not w.get('state') and not s: labels.append('state-missing')
        project = pick(k, 'project') or (s or {}).get('repo')
        if project: labels.append('project:' + slug(project))
        was_held = any(is_held(feed[j]) for j in ids) or (s and s['hold'] is not None and s['status'] != 'closed')
        if status == 'on_hold':
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
        row = {'id': i, 'title': (s['title'] if s else w['title'])[:480], 'status': status, 'metadata': md, 'labels': labels,
               'issue_type': {'bug': 'bug', 'epic': 'epic'}.get(w.get('type'), 'task'), 'created_at': when, 'updated_at': when,
               'priority': int(s['priority']) if s and (s['priority'] or '') in tuple('01234') else int(pick(k, 'priority')[1]) if pick(k, 'priority') else 2,
               'description': (pick(k, 'description') or '\n'.join((s or {}).get('body', [])))[:4000]}
        if status == 'closed':
            row['closed_at'] = when
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
            b = digest(h, item)
            if b in keys and b != k and home[b] == h: deps.append({'issue_id': i, 'depends_on_id': canon[b], 'type': 'blocks'})
            else: md.setdefault('blocked_by', []).append(item)
        if 'blocked_by' in md: labels.append('blocked-by-unresolved')
        if deps: row['dependencies'] = deps
        out[h].append(row)
        man[i] = {'home': h, 'status': status, 'deps': len(deps), 'legacy': ids, 'live_blocked': len(md.get('blocked_by', [])) if status != 'closed' else 0}
        if was_held or status == 'on_hold':
            for j in [j for j in ids if is_held(feed[j])] or [i]: held[j] = {'row': i, 'disposition': disposition}
    held.update({j: {'row': None, 'disposition': 'dropped-upkeep-bucket'} for k in buckets for j in groups[k] if is_held(feed[j])})
    os.makedirs(a.out, exist_ok=True)
    for h, rows in out.items():
        break_cycles(rows)
        for r in rows: man[r['id']]['deps'] = len(r.get('dependencies', []))
        rows.sort(key=lambda r: bool(r.get('dependencies')))
        with open(f'{a.out}/{h}.jsonl', 'w') as f:
            for r in rows: f.write(json.dumps(r) + '\n')
        open(f'{a.out}/{h}.prefixes', 'w').write(','.join(sorted({r['id'].split('-')[0] for r in rows})))
    json.dump({'rows': man, 'held': held, 'buckets': sorted(buckets)}, open(f'{a.out}/manifest.json', 'w'))

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    c = sub.add_parser('copy'); c.add_argument('--main', required=True); c.add_argument('--to', required=True)
    c = sub.add_parser('plan'); c.add_argument('--copy', required=True); c.add_argument('--out', required=True)
    a = p.parse_args()
    return {'copy': copy, 'plan': plan}[a.cmd](a) or 0

if __name__ == '__main__':
    sys.exit(main())

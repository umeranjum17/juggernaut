#!/usr/bin/env python3
"""drafts.py - pull the early drafts of every Muster document at any stage, and send documents back for another round.

Run through bin/jg-muster-drafts.sh. Standard library only. This file owns the ledger format; formats.md is frozen and holds none of it.

  drafts  <project|ticket> [--out <dir>] [--json]       keep a version of every document that changed, then show each document's
                                                        status, version, what is open and what changed, as a text table, one board
                                                        page (<out>/index.html) and one folder of files (<out>/documents, <out>/diffs)
  revise  <project|ticket> <document|all> --note <words> [--source captain|war-room|recon]
                                                        send documents back: the note goes to the next draft round, the document
                                                        returns to discussion (an approved one is reopened, the note being the reason)
  checked <project|ticket> <document>                   the re-check a changed upstream document asked for found nothing to change

A document is named by its path, its file name without `.md`, or its kind (vision, glossary, domain-model, use-cases,
ways-of-working, technical-design, visual-direction, design-system, charter, spec, change, adr). The documents are the pack's
markdown files plus DESIGN.md. They are read from the live draft of a running Muster workflow, else from projects/<project>.

THE LEDGER is data/muster-drafts/<project>/ledger.tsv, append only, one row `at event doc version round source text`, with every
kept version in versions/<doc>/v<n>.md and its diff against the one before in diffs/<doc>/v<n>.diff (<doc> is the path
without `.md`, `/` written `__`); board/ holds the last pull. A running Muster workflow writes data/<ticket>/muster/project (the
project's name) so a pull finds the live draft. Events:
  version  a document's bytes differ from its last kept version; <text> is the sha256, <round> the draft round that made it
  revise   the captain, War Room or Recon sent a document back; <text> is the note
  reopen   a revise on an approved document; <text> is the reason
  sent     a draft round took the document's note into its brief (<round> is that round)
  recheck  an upstream document got a new version; <text> names it; this one is to be re-checked, never rewritten silently
  checked  the re-check found nothing to change
STATUS of a document is read, never stored, in this order (the transition table of the machine):
  abandoned   the document's own `status:` says abandoned (an ADR: superseded or deprecated)
  discussion  its newest revise or reopen has no newer version  <- revise, reopen
  approved    its bytes equal the copy in the captain's approved pack (jg-muster-approval.sh)  <- the captain's yes
  discussion  its own `status:` says discussion
  draft       any other document with a kept version                <- a new version after a revise
A ticket's open work is: notes not yet in a version, and re-checks with no newer version or `checked`.
Exit 0 done, 1 refused (one line saying why), 2 usage.
"""
import contextlib
import difflib
import fcntl
import hashlib
import html
import json
import os
import re
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import approval

HOME = approval.HOME
DATA = approval.DATA
PROJECTS = os.environ.get('JG_PROJECTS_OVERRIDE') or os.path.join(HOME, 'projects')
LEDGER_COLS = ('at', 'event', 'doc', 'version', 'round', 'source', 'text')
SOURCES = ('captain', 'war-room', 'recon')
Refused = approval.Refused

KINDS = (
    ('vision', r'docs/vision\.md'), ('glossary', r'GLOSSARY\.md'), ('domain-model', r'docs/domain/model\.md'),
    ('use-cases', r'docs/use-cases\.md'), ('ways-of-working', r'docs/ways-of-working\.md'),
    ('visual-direction', r'docs/design/visual-direction\.md'), ('design-system', r'DESIGN\.md'),
    ('technical-design', r'docs/(architecture|design)/[^/]+\.md'), ('charter', r'docs/charter\.md'),
    ('spec', r'docs/specs/[^/]+\.md'), ('change', r'docs/changes/[^/]+\.md'), ('adr', r'docs/adr/\d[^/]*\.md'))
# What each kind is written from: a new version of the right-hand kinds flags this kind to re-check.
DEPENDS = {
    'glossary': ('vision',), 'ways-of-working': ('vision',), 'domain-model': ('vision', 'glossary'),
    'use-cases': ('vision', 'domain-model'), 'technical-design': ('domain-model', 'ways-of-working'),
    'adr': ('domain-model',), 'visual-direction': ('vision', 'use-cases'), 'design-system': ('visual-direction',),
    'charter': ('vision', 'use-cases', 'technical-design'), 'spec': ('use-cases', 'domain-model', 'charter'),
    'change': ('spec', 'domain-model')}
OWN_STATUS = {'abandoned': 'abandoned', 'superseded': 'abandoned', 'deprecated': 'abandoned', 'discussion': 'discussion',
              'approved': 'draft', 'accepted': 'draft', 'draft': 'draft', 'proposed': 'draft'}


# ---- the target: which documents, and which ticket's approval and rounds they belong to -------------------------------------

class Target:
    def __init__(self, name, root, ticket=None, draft_round=0):
        self.name, self.root, self.ticket, self.round = name, root, ticket, draft_round
        self.ledger_dir = os.path.join(DATA, 'muster-drafts', name)


def read_line(path):
    try:
        with open(path) as f:
            return f.readline().strip()
    except OSError:
        return ''


def newest(paths):
    return max(paths, key=os.path.getmtime, default=None)


def target(arg):
    """A project name or a muster ticket -> the project, where its documents are now, and the ticket that asked the captain."""
    name, ticket = arg, None
    if read_line(os.path.join(DATA, arg, 'muster', 'project')):
        ticket, name = arg, os.path.basename(read_line(os.path.join(DATA, arg, 'muster', 'project')))
    project = os.path.join(PROJECTS, name)
    if not os.path.isdir(project):
        raise Refused(f'no project or muster ticket named {arg}')
    live = [d for d in _glob(os.path.join(DATA, 'workflows'), '.muster')
            if read_line(os.path.join(DATA, os.path.basename(d)[:-len('.muster')], 'muster', 'project')) == name
            and not os.path.exists(os.path.join(d, 'done'))]
    if ticket is None:
        ticket = os.path.basename(newest([d for d in _glob(DATA, '')
                                          if read_line(os.path.join(d, 'muster', 'project')) == name]) or '') or None
    if not live:
        return Target(name, project, ticket)
    root = newest(live)
    workers = [int(m.group(1)) for f in os.listdir(root) if (m := re.fullmatch(r'worker-(\d+)', f))]
    return Target(name, os.path.join(root, 'draft'), os.path.basename(root)[:-len('.muster')], max(workers, default=0))


def _glob(folder, suffix):
    try:
        return [os.path.join(folder, d) for d in os.listdir(folder) if d.endswith(suffix) and os.path.isdir(os.path.join(folder, d))]
    except OSError:
        return []


# ---- documents ---------------------------------------------------------------------------------------------------------------

def kind_of(rel):
    return next((k for k, pattern in KINDS if re.fullmatch(pattern, rel)), None)


def documents(root):
    """[(path, kind)] of every document under a root, in pack order."""
    out = []
    for rel in approval.pack_files(root) + [f for f in ('DESIGN.md',) if os.path.isfile(os.path.join(root, f))]:
        kind = kind_of(rel)
        if kind and os.path.isfile(os.path.join(root, rel)):
            out.append((rel, kind))
    order = [k for k, _ in KINDS]
    return sorted(set(out), key=lambda d: (order.index(d[1]), d[0]))


def slug(rel):
    return rel[:-3].replace('/', '__') if rel.endswith('.md') else rel.replace('/', '__')


def resolve(docs, ref):
    hits = [rel for rel, kind in docs if ref in (rel, kind, os.path.basename(rel)[:-3])]
    if not hits:
        raise Refused(f'no document named {ref}; the documents are: ' + ', '.join(rel for rel, _ in docs))
    if len(hits) > 1:
        raise Refused(f'{ref} names {len(hits)} documents; name one path: ' + ', '.join(hits))
    return hits[0]


def own_status(text):
    m = re.match(r'---\n(.*?)\n---\n', text, re.S)
    s = re.search(r'^status:\s*([a-z-]+)', m.group(1), re.M) if m else None
    return OWN_STATUS.get(s.group(1)) if s else None


def dependants(kind):
    """Every kind written from this one, directly or through another."""
    out, todo = set(), [kind]
    while todo:
        for k, sources in DEPENDS.items():
            if todo[0] in sources and k not in out:
                out.add(k)
                todo.append(k)
        todo.pop(0)
    return out


# ---- the ledger --------------------------------------------------------------------------------------------------------------

def ledger(t):
    try:
        with open(os.path.join(t.ledger_dir, 'ledger.tsv')) as f:
            return [dict(zip(LEDGER_COLS, line.rstrip('\n').split('\t'))) for line in f if line.strip()]
    except OSError:
        return []


def record(t, event, doc, version='-', draft_round=0, source='-', text='-'):
    os.makedirs(t.ledger_dir, exist_ok=True)
    row = [str(int(time.time())), event, doc, str(version), str(draft_round), source,
           re.sub(r'\s+', ' ', text).strip() or '-']
    with open(os.path.join(t.ledger_dir, 'ledger.tsv'), 'a') as f:
        f.write('\t'.join(row) + '\n')


@contextlib.contextmanager
def locked(t):
    """One writer at a time for the two steps that read the ledger and then write it (a kept version, a note taken by a round)."""
    os.makedirs(t.ledger_dir, exist_ok=True)
    with open(os.path.join(t.ledger_dir, 'lock'), 'w') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def history(rows, doc):
    return [r for r in rows if r['doc'] == doc]


def versions(rows, doc):
    return [r for r in history(rows, doc) if r['event'] == 'version']


def sha_of(path):
    with open(path, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()


def capture(t, draft_round=None):
    """Keep a new version of each document whose bytes differ from its last version; flag what is written from it."""
    with locked(t):
        _capture(t, t.round if draft_round is None else draft_round)


def _capture(t, draft_round):
    rows = ledger(t)
    for rel, kind in documents(t.root):
        path = os.path.join(t.root, rel)
        seen = versions(rows, rel)
        if seen and seen[-1]['text'] == sha_of(path):
            continue
        n = len(seen) + 1
        home = os.path.join(t.ledger_dir, 'versions', slug(rel))
        os.makedirs(home, exist_ok=True)
        shutil.copyfile(path, os.path.join(home, f'v{n}.md'))
        if seen:
            os.makedirs(os.path.join(t.ledger_dir, 'diffs', slug(rel)), exist_ok=True)
            with open(os.path.join(home, f'v{n - 1}.md')) as a, open(path) as b, \
                    open(os.path.join(t.ledger_dir, 'diffs', slug(rel), f'v{n}.diff'), 'w') as out:
                out.writelines(difflib.unified_diff(a.readlines(), b.readlines(), f'{rel} v{n - 1}', f'{rel} v{n}'))
        record(t, 'version', rel, n, draft_round, text=sha_of(path))
        if n > 1:
            for other, other_kind in documents(t.root):
                if other_kind in dependants(kind):
                    record(t, 'recheck', other, draft_round=draft_round, text=f'{rel} v{n}')
        rows = ledger(t)


def open_work(rows, doc):
    """(notes not yet in a version, re-checks with no newer version or `checked`) for one document."""
    mine, notes, checks = history(rows, doc), [], []
    for i, r in enumerate(mine):
        later = [x['event'] for x in mine[i + 1:]]
        if r['event'] in ('revise', 'reopen') and 'version' not in later:
            notes.append(r)
        if r['event'] == 'recheck' and not {'version', 'checked'} & set(later):
            checks.append(r)
    return notes, checks


def approved_copies(t):
    """{path: bytes} of the pack the captain approved on this ticket, or {} when none is approved."""
    if not t.ticket:
        return {}
    try:
        row, _, _ = approval.approved_manifest(t.ticket)
    except (Refused, OSError):
        return {}
    pack = os.path.join(approval.muster_dir(t.ticket), 'pack-' + row['manifest'])
    copies = {}
    for rel, _ in documents(pack):
        with open(os.path.join(pack, rel), 'rb') as f:
            copies[rel] = f.read()
    return copies


def status_of(t, rel, rows, approved):
    with open(os.path.join(t.root, rel), encoding='utf-8', errors='replace') as f:
        own = own_status(f.read())
    notes, _ = open_work(rows, rel)
    if own == 'abandoned':
        return 'abandoned'
    if notes:
        return 'discussion'
    with open(os.path.join(t.root, rel), 'rb') as f:
        if approved.get(rel) == f.read():
            return 'approved'
    return own or 'draft'


# ---- the commands ------------------------------------------------------------------------------------------------------------

def summary(t, rows, approved):
    out = []
    for rel, kind in documents(t.root):
        seen = versions(rows, rel)
        notes, checks = open_work(rows, rel)
        changed = 'first draft'
        if len(seen) > 1:
            lines = open(os.path.join(t.ledger_dir, 'diffs', slug(rel), f'v{len(seen)}.diff')).read().splitlines()
            plus = sum(1 for x in lines if x.startswith('+') and not x.startswith('+++'))
            minus = sum(1 for x in lines if x.startswith('-') and not x.startswith('---'))
            changed = f'+{plus} -{minus} since v{len(seen) - 1}'
        out.append({'document': rel, 'kind': kind, 'status': status_of(t, rel, rows, approved), 'version': len(seen),
                    'round': int(seen[-1]['round']) if seen else 0, 'changed': changed,
                    'open_notes': [f'{n["text"]} ({n["source"]})' for n in notes],
                    'recheck': [c['text'] for c in checks]})
    return out


def board_page(t, items, out):
    rows = []
    for d in items:
        open_ = [f'sent back: {html.escape(n)}' for n in d['open_notes']] + \
                [f're-check, {html.escape(c)} changed' for c in d['recheck']]
        diff = os.path.join(out, 'diffs', slug(d['document']) + '.diff')
        shown = ''
        if os.path.isfile(diff):
            shown = '<details><summary>diff</summary><pre>' + html.escape(open(diff).read()) + '</pre></details>'
        rows.append(f'<tr><td><a href="documents/{html.escape(d["document"])}">{html.escape(d["document"])}</a></td>'
                    f'<td>{d["status"]}</td><td>v{d["version"]} (round {d["round"]})</td>'
                    f'<td>{"<br>".join(open_) or "nothing"}</td><td>{html.escape(d["changed"])}{shown}</td></tr>')
    page = (f'<!doctype html><meta charset="utf-8"><title>Drafts of {html.escape(t.name)}</title>'
            '<style>body{font:15px system-ui;margin:2rem}td,th{border-bottom:1px solid #ccc;padding:.4rem .8rem;text-align:left;'
            'vertical-align:top}pre{white-space:pre-wrap}</style>'
            f'<h1>Drafts of {html.escape(t.name)}</h1><table><tr><th>Document</th><th>Status</th><th>Version</th>'
            f'<th>Open</th><th>Changed</th></tr>{"".join(rows)}</table>')
    with open(os.path.join(out, 'index.html'), 'w') as f:
        f.write(page)


def drafts(t, out=None):
    capture(t)
    rows = ledger(t)
    items = summary(t, rows, approved_copies(t))
    out = out or os.path.join(t.ledger_dir, 'board')
    for sub in ('documents', 'diffs'):
        shutil.rmtree(os.path.join(out, sub), ignore_errors=True)
        os.makedirs(os.path.join(out, sub))
    for d in items:
        os.makedirs(os.path.dirname(os.path.join(out, 'documents', d['document'])), exist_ok=True)
        shutil.copyfile(os.path.join(t.root, d['document']), os.path.join(out, 'documents', d['document']))
        diff = os.path.join(t.ledger_dir, 'diffs', slug(d['document']), f'v{d["version"]}.diff')
        if d['version'] > 1 and os.path.isfile(diff):
            shutil.copyfile(diff, os.path.join(out, 'diffs', slug(d['document']) + '.diff'))
    board_page(t, items, out)
    return {'project': t.name, 'ticket': t.ticket, 'documents': items, 'board': os.path.join(out, 'index.html'),
            'folder': out}


def revise(t, ref, note, source='captain'):
    if not note.strip():
        raise Refused('say what to change: --note <words>')
    if source not in SOURCES:
        raise Refused(f'--source is one of {", ".join(SOURCES)}')
    capture(t)
    rows = ledger(t)
    approved = approved_copies(t)
    docs = documents(t.root)
    chosen = [rel for rel, _ in docs] if ref == 'all' else [resolve(docs, ref)]
    sent = []
    for rel in chosen:
        status = status_of(t, rel, rows, approved)
        if status == 'abandoned':
            if ref != 'all':
                raise Refused(f'{rel} is abandoned; take the abandoned status off the document first')
            continue
        record(t, 'reopen' if status == 'approved' else 'revise', rel, len(versions(rows, rel)), t.round, source, note)
        sent.append((rel, status))
    return sent


def notes_of(rows, rel):
    """[(note row, rounds that took it)] for the notes of a document that no version answers yet."""
    mine, out = history(rows, rel), []
    for i, r in enumerate(mine):
        later = mine[i + 1:]
        if r['event'] in ('revise', 'reopen') and not any(x['event'] == 'version' for x in later):
            out.append((r, [x['round'] for x in later if x['event'] == 'sent']))
    return out


def notes_for_round(t, draft_round):
    """What the draft round `draft_round` must answer: each note not taken by an earlier round (taken now) and each re-check owed.
    Asking twice for one round gives the same text."""
    with locked(t):
        return _notes_for_round(t, draft_round)


def _notes_for_round(t, draft_round):
    rows, lines = ledger(t), []
    for rel, _ in documents(t.root):
        for r, took in notes_of(rows, rel):
            if took and str(draft_round) not in took:
                continue
            if not took:
                record(t, 'sent', rel, draft_round=draft_round)
            how = 'reopened, the note is the reason' if r['event'] == 'reopen' else 'sent back'
            lines.append(f'- {rel} ({how} by {r["source"]}): {r["text"]}')
        lines += [f'- {rel}: re-check it, {c["text"]} changed; change it only if it is now wrong, and say so'
                  for c in open_work(rows, rel)[1]]
    return '\n'.join(lines)


def pending(t):
    """True when a document was sent back and no draft round has taken the note yet."""
    rows = ledger(t)
    return any(not took for rel, _ in documents(t.root) for _, took in notes_of(rows, rel))


def checked(t, ref):
    docs = documents(t.root)
    rel = resolve(docs, ref)
    if not open_work(ledger(t), rel)[1]:
        raise Refused(f'{rel} has no re-check open')
    record(t, 'checked', rel)
    return rel


# ---- the command line --------------------------------------------------------------------------------------------------------

def option(argv, name, default=None):
    if name in argv:
        i = argv.index(name)
        if i + 1 >= len(argv):
            raise SystemExit(2)
        value = argv[i + 1]
        del argv[i:i + 2]
        return value
    return default


def main(argv):
    if len(argv) < 2 or argv[0] not in ('drafts', 'revise', 'checked'):
        sys.stderr.write(__doc__ + '\n')
        return 2
    cmd, args = argv[0], list(argv[1:])
    try:
        if cmd == 'drafts':
            as_json = '--json' in args
            args = [a for a in args if a != '--json']
            out = option(args, '--out')
            if len(args) != 1:
                return 2
            result = drafts(target(args[0]), out)
            if as_json:
                print(json.dumps(result))
                return 0
            print(f'drafts of {result["project"]}')
            for d in result['documents']:
                open_ = '; '.join([f'sent back: {n}' for n in d['open_notes']] + [f're-check: {c} changed' for c in d['recheck']])
                print(f'{d["document"]} | {d["status"]} | v{d["version"]} | {d["changed"]} | open: {open_ or "nothing"}')
            print(f'board: {result["board"]}\nfolder: {result["folder"]}')
        elif cmd == 'revise':
            note, source = option(args, '--note'), option(args, '--source', 'captain')
            if note is None or len(args) != 2:
                return 2
            for rel, status in revise(target(args[0]), args[1], note, source):
                print(f'{rel}: {status} -> discussion; the note goes to the next draft round')
        else:
            if len(args) != 2:
                return 2
            print(f'{checked(target(args[0]), args[1])}: re-check recorded, nothing to change')
    except Refused as e:
        sys.stderr.write(f'jg-muster-drafts: {e}\n')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

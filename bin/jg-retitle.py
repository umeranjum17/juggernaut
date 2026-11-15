#!/usr/bin/env python3
"""One pass that gives every open ticket a plain outcome title.

Usage: jg-retitle.py list                  open tickets whose title is not plain words, as `id<TAB>title`
       jg-retitle.py apply FILE [--write]  FILE holds `id<TAB>new title` lines; without --write it only prints the plan

The rule is bin/jg-backlog-lib.sh's jg_backlog_title_refusal, the same one `add` applies: a new title that fails it is
refused and nothing is written. A title is a few plain words that say the outcome; a plan code (J20d-3, mf-m2) and the
words it replaces go in the body, so nothing is lost: the pass adds `Plan code: <code>` and `Earlier title: <title>`
lines to the end of the body. A line already there is not added again, so a second run changes nothing.
The words of each new title are a person's call, so `list` names the rows and the file carries the words.
"""
import os
from pathlib import Path
import re
import subprocess as sp
import sys
import tempfile

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN.parent / 'core/tickets-sync'))
from task_rows import toon_rows  # the one reader of the backlog's tabular answer
BACKLOG = str(BIN / 'jg-backlog.sh')
TAG = re.compile(r'^\[[\w-]+\]\s*')


def backlog(*args):
    done = sp.run([BACKLOG, *args], text=True, capture_output=True)
    if done.returncode: sys.exit(f'jg-retitle: jg-backlog.sh {" ".join(args)} failed: {(done.stderr or done.stdout).strip()}')
    return done.stdout


def refusal(title):
    """Why the shared title rule refuses `title`, or '' when it passes."""
    done = sp.run(['bash', '-c', '. "$1"; jg_backlog_title_refusal "$2"', '_', str(BIN / 'jg-backlog-lib.sh'), title],
                  text=True, capture_output=True)
    return done.stdout.strip() if done.returncode else ''


def code_of(title):
    first = re.split(r'[ :]', title, maxsplit=1)[0]
    shared = sp.run(['bash', '-c', '. "$1"; jg_backlog_title_starts_with_code "$2"', '_', str(BIN / 'jg-backlog-lib.sh'), title])
    return first if shared.returncode == 0 else ''


def field(shown, key):
    match = re.search(rf'^  {key}: (.*)$', shown, re.M)
    if not match: return ''
    value = match[1].strip()
    if value.startswith('"'):
        import json
        value = json.loads(value)
    return value


def open_rows():
    """Every open ticket as (id, title): --full gives whole titles."""
    rows = []
    for row in toon_rows(backlog('list', '--full')) or []:
        if row['state'] == 'done': continue
        title = row['title']
        rows.append((row['id'], TAG.sub('', title)))
    return rows


def show(ident):
    shown = backlog('show', ident, '--full')
    return TAG.sub('', field(shown, 'title')), field(shown, 'body')


def listing():
    for ident, title in open_rows():
        if refusal(title): print(f'{ident}\t{title}', flush=True)


def parse(path):
    rows = []
    for number, line in enumerate(Path(path).read_text().splitlines(), 1):
        if not line.strip() or line.startswith('#'): continue
        ident, sep, title = line.partition('\t')
        if not sep or not title.strip(): sys.exit(f'jg-retitle: {path}:{number}: want `id<TAB>new title`')
        rows.append((ident.strip(), title.strip()))
    return rows


def apply(path, write):
    rows = parse(path)
    plan, bad = [], []
    for ident, new in rows:
        why = refusal(new)
        if why:
            bad.append(f'{ident}: "{new}" is not a plain title: {why}')
            continue
        old, body = show(ident)
        if old == new: continue
        notes = [f'Plan code: {code_of(old)}'] if code_of(old) else []
        notes.append(f'Earlier title: {old}')
        plan.append((ident, old, new, body, [n for n in notes if n not in body]))
    if bad: sys.exit('jg-retitle: nothing written.\n' + '\n'.join(bad))
    for ident, old, new, body, notes in plan:
        print(f'{ident}: "{old}" -> "{new}"')
        if not write: continue
        with tempfile.NamedTemporaryFile('w', suffix='.md', delete=False) as handle:
            handle.write('\n'.join([body, *notes]) if notes else body)
        try: backlog('update', ident, '--title', new, '--body-file', handle.name)
        finally: os.unlink(handle.name)
    print(f'{len(plan)} title(s) {"renamed" if write else "would be renamed (pass --write)"}')


def main(argv):
    if argv[:1] == ['list'] and len(argv) == 1: return listing()
    if argv[:1] == ['apply'] and len(argv) in (2, 3) and argv[2:] in ([], ['--write']): return apply(argv[1], argv[2:] == ['--write'])
    sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])

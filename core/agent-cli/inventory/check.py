#!/usr/bin/env python3
"""check.py [<operations.tsv>] [--tree <dir>] [--usage <file>] [--strict]

The drift check of the reviewed list of public operations (core/agent-cli/operations.tsv, one owner, one canonical path,
one method and one invocation form per operation). It runs the extractor on the tree and prints, for review and never
written into the list:
  - the list's own integrity: one row per operation, one owner each, a unique path, no alias that is another path, GET
    exactly for a row that changes nothing;
  - forward drift: a public operation the tree has and the list lacks;
  - reverse drift: a listed operation the tree lost (its script is gone, or the script no longer names it).
The coverage target is the list, never the extractor's class and never a usage count: --usage only reaches the
extractor's discovery column, so two runs, with and without private logs, print the same lines. Exit 1 when the list's
integrity fails; drift exits 0 and is printed, unless --strict.
"""
import argparse
import collections
import csv
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_LIST = os.path.join(HERE, '..', 'operations.tsv')
DEFAULT_TREE = os.path.join(HERE, '..', '..', '..')


def load_list(path):
    with open(path, newline='') as f:
        return list(csv.DictReader(f, delimiter='\t'))


def integrity(ops):
    """Problems with the list itself, one line each."""
    bad = []
    keys = collections.Counter((o['script'], o['operation']) for o in ops)
    bad += [f'integrity\tduplicate operation\t{s}\t{a}' for (s, a), n in keys.items() if n > 1]
    bad += [f'integrity\tno owner\t{o["script"]}\t{o["operation"]}' for o in ops if not o['owner'].strip()]
    paths = collections.Counter(o['path'] for o in ops)
    bad += [f'integrity\tpath used {n} times\t{p}' for p, n in paths.items() if n > 1]
    aliases = {a for o in ops for a in o['aliases'].split(',') if a not in ('-', '')}
    bad += [f'integrity\talias is also a path\t{a}' for a in sorted(aliases & set(paths))]
    bad += [f'integrity\tmethod {o["method"]} with changes={o["changes"]}\t{o["script"]}\t{o["operation"]}'
            for o in ops if (o['method'] == 'GET') != (o['changes'] == 'no') or o['method'] not in ('GET', 'POST')]
    return bad


def drift(ops, rows, scripts_in_tree):
    listed = {(o['script'], o['operation']) for o in ops}
    listed_first = listed | {(s, a.split(' ')[0]) for s, a in listed}
    found_any = {(r['script'], r['action']) for r in rows} | {(r['script'], r['action'].split(' ')[0]) for r in rows}
    found_public = {(r['script'], r['action']) for r in rows if r['class'] == 'public'}
    forward = sorted(found_public - listed_first)
    reverse = sorted(k for k in listed if k not in found_any)
    gone = {s for s, _ in reverse if s not in scripts_in_tree}
    return forward, reverse, gone


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('list', nargs='?', default=DEFAULT_LIST)
    ap.add_argument('--tree', default=DEFAULT_TREE)
    ap.add_argument('--usage')
    ap.add_argument('--strict', action='store_true', help='drift exits 1 too')
    args = ap.parse_args(argv)
    ops = load_list(args.list)
    rows, _dropped, _split = extract.extract(args.tree, args.usage)
    scripts = set(os.listdir(os.path.join(args.tree, 'bin')))
    bad = integrity(ops)
    forward, reverse, gone = drift(ops, rows, scripts)
    print(f'operations checked (the reviewed list): {len(ops)} in {len({o["script"] for o in ops})} scripts')
    print(f'owners: {len({o["owner"] for o in ops})}; paths: {len({o["path"] for o in ops})}; '
          f'methods: GET {sum(o["method"] == "GET" for o in ops)}, POST {sum(o["method"] == "POST" for o in ops)}')
    print(f'list integrity problems: {len(bad)}')
    for line in bad:
        print('  ' + line)
    print(f'drift, a public operation the tree has and the list lacks (to review): {len(forward)}')
    for s, a in forward:
        print(f'  drift+ {s} {a}')
    print(f'drift, a listed operation the tree lost (to review): {len(reverse)}')
    for s, a in reverse:
        print(f'  drift- {s} {a}' + (' (script gone)' if s in gone else ''))
    return 1 if bad or (args.strict and (forward or reverse)) else 0


if __name__ == '__main__':
    sys.exit(main())

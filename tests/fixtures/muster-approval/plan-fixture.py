#!/usr/bin/env python3
"""plan-fixture.py <manifest.tsv> <charter document> <ticket> <variant> <out.json> - writes the plan War Room's lanes
would write for an approved pack (formats.md section 5), from the approved manifest and the charter tables of the
document it came from (docs/charter.md for a project, the change pack for a feature). One slice per charter ticket;
a slice depends on the slices of the tickets its ticket depends on and of every ticket of the batches its batch starts
after; each slice claims its ticket's journeys. Variants:
  matching        the plan above
  r2-first        the second feature ticket's slice drops its dependencies (R2 scheduled before R1)
  c3-free         the C3 slice drops its dependency on the C1 slice (the project's reversed dependency)
  project-order   the block carries the project's charter (C1-C4) instead of the feature's
  drop-objective  the block drops one objective
  change-kind     the block changes one journey's kind
  other-ticket    the block names another ticket
  other-manifest  the block names another manifest
  drop-charter    the block drops one charter ticket
  unclaimed       the last milestone journey is claimed by no slice
  combined        one slice claims R2 and R1 together, depending on nothing
  c1c2-one        C1 and C2 (one batch, no edge between them) share one slice; the slices that followed either follow it
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', 'core', 'muster'))
import approval as A  # noqa: E402

mf_path, doc, ticket, variant, out = sys.argv[1:6]
mf = open(mf_path).read().splitlines()
sha = os.path.basename(mf_path)[len('manifest-'):-len('.tsv')]
chk = next(ln.split() for ln in mf if ln.startswith('check '))
text = open(doc).read()
charter_text = A.section(text, 'Charter') if chk[2] != '-' else text
tk = next((t for t in A.tables(charter_text) if t and len(t[0]) == 6), [])
journeys_of = {r[0]: A.ids(r[5]) for r in tk}
block = {'ticket': ticket, 'depth': chk[1], 'manifest_sha': sha, 'journeys': [], 'batches': [], 'charter': [], 'milestones': []}
for ln in mf:
    p = ln.split(' ')
    if p[0] == 'journey':
        block['journeys'].append({'id': p[1], 'kind': p[2]})
    elif p[0] == 'batch':
        block['batches'].append({'id': p[1], 'after': [] if p[2] == '-' else p[2].split(',')})
    elif p[0] == 'charter':
        block['charter'].append({'ticket': p[1], 'batch': p[2], 'depends': [] if p[3] == '-' else p[3].split(',')})
    elif p[0] == 'milestone':
        block['milestones'].append({'id': p[1], 'journeys': p[2].split(',')})
after = {b['id']: b['after'] for b in block['batches']}
rows = {c['ticket']: c for c in block['charter']}
slices = []
for t, c in rows.items():
    need = set(c['depends']) | {u for u, d in rows.items() for b in after.get(c['batch'], []) if d['batch'] == b}
    slices.append({'id': 's-' + t.lower(), 'depends_on': sorted('s-' + u.lower() for u in need), 'charter': [t],
                   'journeys': journeys_of.get(t, [])})
claimed = {j for s in slices for j in s['journeys']}
for j in block['journeys']:  # a preserve journey no ticket names is still run by the first slice
    if j['id'] not in claimed:
        slices[0]['journeys'].append(j['id'])


def slice_of(t):
    return next(s for s in slices if s['charter'] == [t])


if variant == 'r2-first':
    slice_of('R2')['depends_on'] = []
elif variant == 'c3-free':
    s = slice_of('C3')
    s['depends_on'] = [d for d in s['depends_on'] if d != 's-c1']
elif variant == 'project-order':
    block['charter'] = [{'ticket': 'C1', 'batch': 'B1', 'depends': []}, {'ticket': 'C2', 'batch': 'B1', 'depends': []},
                        {'ticket': 'C3', 'batch': 'B2', 'depends': ['C1']}, {'ticket': 'C4', 'batch': 'B2', 'depends': ['C1']}]
elif variant == 'combined':
    r1, r2 = slice_of('R1'), slice_of('R2')
    slices = [x for x in slices if x not in (r1, r2)]
    slices.insert(0, {'id': 's-r2r1', 'depends_on': [], 'charter': ['R2', 'R1'], 'journeys': r2['journeys'] + r1['journeys']})
elif variant == 'c1c2-one':
    c1, c2 = slice_of('C1'), slice_of('C2')
    slices = [x for x in slices if x not in (c1, c2)]
    for x in slices:
        x['depends_on'] = sorted({'s-c1c2' if d in ('s-c1', 's-c2') else d for d in x['depends_on']})
    slices.insert(0, {'id': 's-c1c2', 'depends_on': [], 'charter': ['C1', 'C2'], 'journeys': c1['journeys'] + c2['journeys']})
elif variant == 'drop-objective':
    block['journeys'] = block['journeys'][1:]
elif variant == 'change-kind':
    j = block['journeys'][0]
    j['kind'] = 'preserve' if j['kind'] == 'new' else 'new'
elif variant == 'other-ticket':
    block['ticket'] = 'jg-other'
elif variant == 'other-manifest':
    block['manifest_sha'] = '0' * 12
elif variant == 'drop-charter':
    block['charter'] = block['charter'][1:]
elif variant == 'unclaimed':
    gone = block['milestones'][-1]['journeys'][-1]
    for s in slices:
        s['journeys'] = [j for j in s['journeys'] if j != gone]
elif variant != 'matching':
    sys.exit(f'unknown variant {variant}')
json.dump({'plan': 'fixture-' + variant, 'slices': slices, 'muster': block}, open(out, 'w'), indent=1)
print(out)

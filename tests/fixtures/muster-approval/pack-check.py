#!/usr/bin/env python3
"""pack-check.py - the prototype of order m2's pack gate (and of m2c's objectives and code checks), run on the
jg-6si example pack. Critic round 3, finding 1: the example must pass the check it is meant to prove, with zero
missing references between the glossary, model, charter, spec, decision records and journey manifest.
Round 6 (closure review of draft 6, finding 3): the glossary delta is compared by definition both ways: a term the
real change adds, removes or redefines must be listed with that kind, and a listed kind must be what the change did.
Round 5 (critic closure review, findings 3, 7 and 8): the vision delta is compared both ways (a real added or removed
vision sentence the change pack does not list is refused); light and full depth check a feature, so they need the
change pack and the documents before it, and every pack holds at least one decision record; `Lifecycle: none` needs
a reason, and an object that keeps a state field needs its state machine.

Usage:
  pack-check.py all <example-pack dir>          gate both trees, the change pack against the real diff, the journeys
                                                 on base and head, the code check, and every planted fault
  pack-check.py gate <project> --depth <complete|full|light> [--change <slug> --before <project>]
  pack-check.py objectives <head project> --base-src <dir> [--base-only] --spec <slug> | --change <slug>
                                                 (base = head with <dir> laid over its src/; --base-only runs the
                                                 base half alone, before any code exists: every new journey must
                                                 fail on its named assertion and every preserve journey pass)
  pack-check.py code <project>
Exit 0 when nothing is refused; 1 with one `refused: <clause>: <detail>` line per finding; 2 usage.
No model call, no network. Journeys run with the same node that runs the project's own journeys.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

PH = re.compile(r'<[^<>\n]{2,60}>')  # a template placeholder left in a filled document


def read(p):
    return open(p, encoding='utf-8').read() if os.path.exists(p) else None


def section(text, title, level=2):
    """The body of a markdown section whose heading starts with `title` (up to the next heading of that level or higher)."""
    m = re.search(r'^' + '#' * level + r' ' + re.escape(title) + r'[^\n]*\n(.*?)(?=^#{1,%d} |\Z)' % level, text, re.M | re.S)
    return m.group(1) if m else None


def table(text):
    """Rows of the first markdown table in text, as lists of stripped cells, header and rule lines dropped."""
    rows, seen_header = [], False
    for line in (text or '').splitlines():
        if not line.startswith('|'):
            if rows or seen_header:
                break
            continue
        cells = [c.strip() for c in line.strip().strip('|').split('|')]
        if not seen_header:
            seen_header = True
            continue
        if set(''.join(cells)) <= set('-: '):
            continue
        rows.append(cells)
    return rows


def tables(text):
    """Every markdown table in text, in order."""
    out, cur = [], []
    for line in (text or '').splitlines() + ['']:
        if line.startswith('|'):
            cur.append(line)
        elif cur:
            out.append(table('\n'.join(cur)))
            cur = []
    return out


def ids(cell):
    return [x.strip().strip('`') for x in re.split(r'[,;]', cell or '') if x.strip() and x.strip() not in ('-', 'none')]


def norm_term(s):
    return re.sub(r'[\s_]+', ' ', s).strip().lower()


class Pack:
    def __init__(self, root):
        self.root = root
        self.refusals = []

    def refuse(self, clause, detail):
        self.refusals.append(f'refused: {clause}: {detail}')

    def p(self, rel):
        return os.path.join(self.root, rel)

    # ---------------------------------------------------------------- parsing
    def glossary(self):
        g = read(self.p('GLOSSARY.md'))
        if g is None:
            self.refuse('glossary', 'GLOSSARY.md is missing')
            return set(), set(), {}
        core_s = section(g, 'Core objects') or ''
        core = {m.strip() for m in re.findall(r'^### (.+)$', core_s, re.M)}
        terms = {m.strip() for m in re.findall(r'^### (.+)$', g, re.M)}
        owns = {name: (re.search(r'Owns: (.*?)(?:\n_Avoid_|\n\n|\Z)', body, re.S) or [None, ''])[1]
                for name, body in re.findall(r'^### ([^\n]+)\n(.*?)(?=^### |^## |\Z)', core_s, re.M | re.S)}
        return core, terms, owns

    def model(self):
        m = read(self.p('docs/domain/model.md'))
        if m is None:
            return None
        er = re.search(r'```mermaid\s*\nerDiagram\n(.*?)```', m, re.S)
        entities = set()
        for line in (er.group(1) if er else '').splitlines():
            for e in re.findall(r'^\s*([A-Z][A-Z_]*)\s+\S+\s+([A-Z][A-Z_]*)', line):
                entities.update(e)
        objects = {}
        core_s = section(m, 'Core objects') or ''
        for name, body in re.findall(r'^### ([^\n]+)\n(.*?)(?=^### |\Z)', core_s, re.M | re.S):
            o = {'behaviour': [], 'invariants': [], 'lives_in': None, 'lifecycle': None, 'fields': None}
            b = re.search(r'^- Behaviour: (.*)$', body, re.M)
            o['behaviour'] = re.findall(r'`(\w+)\(', b.group(1)) if b else []
            inv = re.search(r'^- Invariants:\n((?:  - .*\n?)+)', body, re.M)
            for line in (inv.group(1) if inv else '').splitlines():
                j = re.search(r'\(proved by `([^`]+)`\)', line)
                o['invariants'].append((re.sub(r'\s*\(proved by.*$', '', line[4:]).strip(), j.group(1) if j else None))
            li = re.search(r'^- Lives in: `([^`]+)`', body, re.M)
            o['lives_in'] = li.group(1) if li else None
            lc = re.search(r'^- Lifecycle: (.*)$', body, re.M)
            o['lifecycle'] = lc.group(1) if lc else None
            fi = re.search(r'^- Fields: (.*)$', body, re.M)
            o['fields'] = fi.group(1) if fi else None
            objects[name.strip()] = o
        machines = {}
        sm_s = section(m, 'State machines') or ''
        for name, body in re.findall(r'^### (\w+) state machine\n(.*?)(?=^### |\Z)', sm_s, re.M | re.S):
            st = re.search(r'^States: (.*)$', body, re.M)
            states = ids(st.group(1)) if st else []
            dia = re.search(r'```mermaid\s*\nstateDiagram-v2\n(.*?)```', body, re.S)
            edges = set()
            for line in (dia.group(1) if dia else '').splitlines():
                e = re.match(r'\s*(\[\*\]|\w+)\s*-->\s*(\w+)\s*(?::\s*(\w+))?', line)
                if e:
                    edges.add((e.group(1), e.group(2), e.group(3) or ''))
            rows = [dict(zip(['from', 'to', 'trigger', 'guard', 'effect', 'journey'], r)) for r in table(body)]
            machines[name] = {'states': states, 'edges': edges, 'rows': rows}
        return {'entities': entities, 'objects': objects, 'machines': machines, 'text': m}

    def specs(self):
        out = {}
        d = self.p('docs/specs')
        for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            if not f.endswith('.md'):
                continue
            s = read(os.path.join(d, f))
            obj = section(s, 'Objectives') or ''
            rows = table(obj)
            out[f[:-3]] = {r[0].strip('`'): r[1] for r in rows if len(r) >= 2}
            fm = s.split('---')[1] if s.startswith('---') else ''
            for key in ('title', 'slug', 'status', 'created', 'updated', 'owner', 'links'):
                if not re.search(r'^' + key + r':', fm, re.M):
                    self.refuse('spec', f'docs/specs/{f} has no spec-docs field {key}')
            if '## Verification' not in s:
                self.refuse('spec', f'docs/specs/{f} has no Verification section')
        return out

    def journeys_manifest(self):
        y = read(self.p('.done-done.yaml')) or ''
        return dict(re.findall(r'^  ([\w-]+): \{[^}]*command: ([^}]+)\}', y, re.M))

    def adrs(self):
        out = {}
        d = self.p('docs/adr')
        for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            m = re.match(r'(\d{4})-.*\.md$', f)
            if m:
                out[m.group(1)] = (f, read(os.path.join(d, f)))
        return out

    def charter_tables(self, text, where):
        ts = tables(text)
        ms = next((t for t in ts if t and len(t[0]) == 4), [])
        bs = next((t for t in ts if t and len(t[0]) == 3), [])
        tk = next((t for t in ts if t and len(t[0]) == 6), [])
        if not (ms and bs and tk):
            self.refuse('charter', f'{where}: the milestone, batch and ticket tables are not all present')
        return ms, bs, tk

    # ---------------------------------------------------------------- clauses
    def check_adr(self, num, f, text):
        where = f'docs/adr/{f}'
        status = re.search(r'^status: (.+)$', text, re.M)
        if not status:
            self.refuse('adr', f'{where}: no status (an idea, not a decision)')
        if not (section(text, 'Context') or '').strip():
            self.refuse('adr', f'{where}: no context')
        opts = re.findall(r'^- ', section(text, 'Considered options') or '', re.M)
        if len(opts) < 2:
            self.refuse('adr', f'{where}: fewer than two considered options (an idea, not a decision)')
        dec = (section(text, 'Decision') or '').strip()
        if not dec.startswith('We '):
            self.refuse('adr', f'{where}: no decision line starting "We" (an idea, not a decision)')
        cons = section(text, 'Consequences') or ''
        if 'Good:' not in cons or 'Bad:' not in cons:
            self.refuse('adr', f'{where}: consequences need a Good and a Bad line')
        if not (section(text, 'Confirmation') or '').strip():
            self.refuse('adr', f'{where}: no confirmation (no check enforces it)')
        if PH.search(text.split('---', 2)[-1]):
            self.refuse('adr', f'{where}: a template placeholder is left: {PH.search(text.split("---", 2)[-1]).group(0)}')
        return re.search(r'^kind: (\w+)', text, re.M).group(1) if re.search(r'^kind: (\w+)', text, re.M) else ''

    def check_charter(self, ms, bs, tk, objectives, where):
        batches = {}
        for r in bs:
            after = [] if r[1].startswith('-') else ids(r[1])
            batches[r[0]] = after
        for b, after in batches.items():
            for a in after:
                if a not in batches:
                    self.refuse('charter', f'{where}: batch {b} starts after unknown batch {a}')
        order = {}

        def depth(b, seen=()):
            if b in seen:
                self.refuse('charter', f'{where}: batch cycle through {b}')
                return 0
            if b not in order:
                order[b] = 1 + max((depth(a, seen + (b,)) for a in batches.get(b, []) if a in batches), default=0)
            return order[b]
        for b in batches:
            depth(b)
        tickets = {}
        for r in tk:
            tickets[r[0]] = {'batch': r[2], 'depends': ids(r[3]), 'journeys': ids(r[5])}
        claimed = set()
        for t, v in tickets.items():
            if v['batch'] not in batches:
                self.refuse('charter', f'{where}: ticket {t} has no known batch')
                continue
            for d in v['depends']:
                if d not in tickets:
                    self.refuse('charter', f'{where}: ticket {t} depends on unknown ticket {d}')
                elif tickets[d]['batch'] == v['batch']:
                    self.refuse('charter', f'{where}: ticket {t} depends on {d} in its own batch; tickets of a batch run in parallel')
                elif order.get(tickets[d]['batch'], 0) > order.get(v['batch'], 0):
                    self.refuse('charter', f'{where}: ticket {t} depends on {d} of a later batch')
            for j in v['journeys']:
                claimed.add(j)
                if j not in objectives:
                    self.refuse('reference', f'{where}: ticket {t} names journey {j}, which no spec objective has')
        for r in ms:
            js = ids(r[2])
            if not js:
                self.refuse('charter', f'{where}: milestone {r[0]} has no journey')
            for j in js:
                if j not in objectives:
                    self.refuse('reference', f'{where}: milestone {r[0]} names journey {j}, which no spec objective has')
            for t in ids(r[3]):
                if t not in tickets:
                    self.refuse('reference', f'{where}: milestone {r[0]} names unknown ticket {t}')
        return tickets, claimed

    def gate(self, depth, change=None, before=None):
        if depth not in ('complete', 'full', 'light'):
            self.refuse('depth', f'unknown depth {depth} (complete, full or light; skip has no pack)')
            return self.refusals
        if depth in ('full', 'light') and not (change and before):
            self.refuse('change', f'{depth} depth checks a feature: name its change pack and the documents before it '
                                  '(--change <slug> --before <dir>); with no feature named there is nothing to check')
            return self.refusals
        core, terms, owns = self.glossary()
        model = self.model()
        specs = self.specs()
        objectives = {j: k for s in specs.values() for j, k in s.items()}
        manifest = self.journeys_manifest()
        tnorm = {norm_term(t) for t in terms}
        if model is None and depth == 'complete':
            self.refuse('model', 'docs/domain/model.md is missing')
        if model:
            for e in model['entities']:
                if norm_term(e) not in tnorm:
                    self.refuse('reference', f'model: entity {e} is not a glossary term')
            for name in model['objects']:
                if name not in core:
                    self.refuse('reference', f'model: core object {name} is not a glossary core object')
            for name in core:
                if name not in model['objects']:
                    self.refuse('reference', f'glossary: core object {name} has no section in the model')
            for name, o in model['objects'].items():
                if not o['behaviour']:
                    self.refuse('model', f'{name} has no behaviour (a data bag)')
                if not o['invariants']:
                    self.refuse('model', f'{name} has no invariant (a data bag)')
                for inv, j in o['invariants']:
                    if not j:
                        self.refuse('model', f'{name}: invariant "{inv}" names no journey that tries to break it')
                    elif j not in objectives:
                        self.refuse('reference', f'{name}: invariant "{inv}" is proved by {j}, which no spec objective has')
                if not o['lives_in']:
                    self.refuse('model', f'{name} has no Lives in line')
                lc = o['lifecycle']
                if not lc:
                    self.refuse('model', f'{name} has no Lifecycle line (a state machine, or "none - <reason>")')
                elif lc.startswith('none'):
                    if not re.match(r'none\s*[-:–—]\s*\S', lc):
                        self.refuse('model', f'{name}: "Lifecycle: {lc}" gives no reason (write "none - <why it has no states>")')
                    if re.search(r'(^|,)\s*(state|status)\s*(,|$)', o['fields'] or ''):
                        self.refuse('model', f'{name} keeps a state field but has no state machine ("none" is only for a stateless object)')
                elif name not in model['machines']:
                    self.refuse('model', f'{name} names a lifecycle but the model has no {name} state machine')
            for name, sm in model['machines'].items():
                o = model['objects'].get(name, {'behaviour': []})
                if not sm['states']:
                    self.refuse('model', f'{name} state machine lists no states')
                if not any(e[0] == '[*]' for e in sm['edges']):
                    self.refuse('model', f'{name} state machine has no start edge [*] --> <state>')
                table_edges = set()
                for r in sm['rows']:
                    key = (r['from'], r['to'], r['trigger'])
                    table_edges.add(key)
                    if r['from'] != '[*]' and r['from'] not in sm['states']:
                        self.refuse('model', f'{name}: transition from unknown state {r["from"]}')
                    if r['to'] not in sm['states']:
                        self.refuse('model', f'{name}: transition to unknown state {r["to"]}')
                    if not r['trigger'] or r['trigger'] not in o['behaviour']:
                        self.refuse('model', f'{name}: transition {r["from"]} -> {r["to"]} has trigger "{r["trigger"]}", not a behaviour of {name}')
                    if not r['guard']:
                        self.refuse('model', f'{name}: transition {r["from"]} -> {r["to"]} has no guard (write "always")')
                    js = ids(r['journey'])
                    if not js:
                        self.refuse('model', f'{name}: transition {r["from"]} -> {r["to"]} is driven by no journey')
                    for j in js:
                        if j not in objectives:
                            self.refuse('reference', f'{name}: transition {r["from"]} -> {r["to"]} names journey {j}, which no spec objective has')
                for e in sm['edges'] - table_edges:
                    self.refuse('model', f'{name}: diagram edge {e[0]} --> {e[1]} : {e[2]} has no table row')
                for e in table_edges - sm['edges']:
                    self.refuse('model', f'{name}: table row {e[0]} -> {e[1]} ({e[2]}) has no diagram edge')
        for j in objectives:
            if j not in manifest:
                self.refuse('reference', f'spec objective {j} has no journey in .done-done.yaml')
        for j, cmd in manifest.items():
            if j not in objectives:
                self.refuse('reference', f'.done-done.yaml journey {j} is no spec objective')
            script = re.search(r'node (\S+\.ts)', cmd)
            if script and not os.path.exists(self.p(script.group(1))):
                self.refuse('reference', f'journey {j} runs {script.group(1)}, which does not exist')
            if script and j not in (read(self.p(script.group(1))) or ''):
                self.refuse('reference', f'journey {j} is not defined in {script.group(1)}')
        adrs = self.adrs()
        if not adrs:
            self.refuse('adr', 'docs/adr holds no decision record (every pack at every depth holds at least one)')
        kinds = set()
        for num, (f, text) in adrs.items():
            kinds.add(self.check_adr(num, f, text))
            for j in re.findall(r'`([a-z][a-z0-9]*(?:-[a-z0-9]+)+)`', section(text, 'Confirmation') or ''):
                if j in manifest and j not in objectives:
                    self.refuse('reference', f'docs/adr/{f}: confirmation names journey {j}, which no spec objective has')
                if re.search(r'journey', section(text, 'Confirmation') or '') and '-' in j and j not in manifest and not j.startswith(('core', 'src', 'journeys')) and '/' not in j and '.' not in j:
                    self.refuse('reference', f'docs/adr/{f}: confirmation names journey {j}, which .done-done.yaml lacks')
        if depth == 'complete':
            for k in ('stack', 'storage', 'hosting'):
                if k not in kinds:
                    self.refuse('adr', f'complete depth needs a decision record of kind {k}')
            v = read(self.p('docs/vision.md'))
            if v is None:
                self.refuse('vision', 'docs/vision.md is missing')
            else:
                body = v.split('---', 2)[-1]
                for s_ in ('Press release', 'Who it is for', 'End state', 'Time budget', 'No-gos', 'Open risks', 'FAQ', 'Decisions'):
                    if not (section(body, s_) or '').strip():
                        self.refuse('vision', f'section "{s_}" is missing or empty')
                if PH.search(body):
                    self.refuse('vision', f'a template placeholder is left: {PH.search(body).group(0)}')
                if len(body.strip().splitlines()) > 60:
                    self.refuse('vision', 'over one page (60 lines)')
            w = read(self.p('docs/ways-of-working.md')) or ''
            if not w:
                self.refuse('rules', 'docs/ways-of-working.md is missing')
            for r in table(section(w, 'Rules') or ''):
                if len(r) < 4 or not r[2] or not r[3]:
                    self.refuse('rules', f'rule "{r[0]}" names no check or no planted-fault proof')
            for n in re.findall(r'decision (\d{4})', section(w, 'Stack') or ''):
                if n not in adrs:
                    self.refuse('reference', f'ways of working: stack line names decision {n}, which does not exist')
            if not table(section(read(self.p('docs/design/visual-direction.md')) or '', 'Key screens') or ''):
                self.refuse('visual', 'docs/design/visual-direction.md has no key screens')
            c = read(self.p('docs/charter.md'))
            if c is None:
                self.refuse('charter', 'docs/charter.md is missing')
            else:
                ms, bs, tk = self.charter_tables(c, 'docs/charter.md')
                _, claimed = self.check_charter(ms, bs, tk, objectives, 'docs/charter.md')
                for j, k in objectives.items():
                    if k == 'new' and j not in claimed:
                        self.refuse('charter', f'new journey {j} is claimed by no charter ticket')
        for f in sorted(os.listdir(self.p('docs/design'))) if os.path.isdir(self.p('docs/design')) else []:
            if f != 'visual-direction.md':
                u = (section(read(self.p('docs/design/' + f)), 'Unresolved questions') or '').strip()
                if u and u != 'None.':
                    self.refuse('design', f'docs/design/{f} has unresolved questions not held on the board')
        if change:
            self.change_pack(change, before, depth, objectives, manifest)
        return self.refusals

    # ---------------------------------------------------------------- the change pack against the real difference
    def change_pack(self, slug, before_root, depth, objectives, manifest):
        where = f'docs/changes/{slug}.md'
        c = read(self.p(where))
        if c is None:
            self.refuse('change', f'{where} is missing')
            return
        b = Pack(before_root)
        bm, am = b.model(), self.model()
        _, bterms, bowns = b.glossary()
        _, aterms, aowns = self.glossary()
        bglos, aglos = read(b.p('GLOSSARY.md')), read(self.p('GLOSSARY.md'))
        for r in table(section(c, 'Objects changed')):
            obj = r[0]
            ao, bo = am['objects'].get(obj), bm['objects'].get(obj)
            if not ao:
                self.refuse('change', f'{where}: object {obj} is not in the model after')
                continue
            for meth in re.findall(r'`(\w+)\(', r[1]):
                if meth not in ao['behaviour'] or (bo and meth in bo['behaviour']):
                    self.refuse('change', f'{where}: behaviour {meth} of {obj} is not added by the real change')
            for inv in re.findall(r'ADDED: ([^;]+)', r[3]):
                a_inv = [i for i, _ in ao['invariants']]
                b_inv = [i for i, _ in bo['invariants']] if bo else []
                if inv.strip() not in a_inv or inv.strip() in b_inv:
                    self.refuse('change', f'{where}: invariant "{inv.strip()}" of {obj} is not added by the real change')
        real_added_beh = {(o, m_) for o, ao in am['objects'].items() for m_ in ao['behaviour']} - {(o, m_) for o, bo in bm['objects'].items() for m_ in bo['behaviour']}
        listed_beh = {(r[0], m_) for r in table(section(c, 'Objects changed')) for m_ in re.findall(r'`(\w+)\(', r[1])}
        for o, m_ in real_added_beh - listed_beh:
            self.refuse('change', f'{where}: the real change adds {o}.{m_}, which Objects changed does not list')
        sm_rows = table(section(c, 'State machine changes'))
        change_objectives = dict(re.findall(r'^- ([\w-]+) \((new|preserve)\)', section(c, 'Objectives') or '', re.M))
        for r in sm_rows:
            obj, tr, kind, trig = r[0], r[1], r[2], r[3]
            f_, t_ = [x.strip() for x in tr.split('->')]
            key = (f_, t_, trig)
            arows = {(x['from'], x['to'], x['trigger']): x for x in am['machines'].get(obj, {}).get('rows', [])}
            brows = {(x['from'], x['to'], x['trigger']): x for x in bm['machines'].get(obj, {}).get('rows', [])}
            if kind.startswith('ADDED') and (key not in arows or key in brows):
                self.refuse('change', f'{where}: transition {tr} ({trig}) is not added by the real change')
            if kind.startswith('MODIFIED') and (key not in arows or key not in brows or arows[key] == brows[key]):
                self.refuse('change', f'{where}: transition {tr} ({trig}) is not modified by the real change')
            for j in ids(r[5]):
                if j not in change_objectives:
                    self.refuse('reference', f'{where}: state machine change {tr} names journey {j}, which its Objectives omit')
        for obj in am['machines']:
            arows = {(x['from'], x['to'], x['trigger']): x for x in am['machines'][obj]['rows']}
            brows = {(x['from'], x['to'], x['trigger']): x for x in bm['machines'].get(obj, {}).get('rows', [])}
            listed = {(r[1].split('->')[0].strip(), r[1].split('->')[1].strip(), r[3]) for r in sm_rows if r[0] == obj}
            for k in set(arows) ^ set(brows) | {k for k in set(arows) & set(brows) if arows[k] != brows[k]}:
                if k not in listed:
                    self.refuse('change', f'{where}: the real change alters {obj} transition {k[0]} -> {k[1]} ({k[2]}), which State machine changes does not list')
        # both ways, by definition: every term the real change adds, removes or redefines is listed with that kind,
        # and every listed kind is what the real change did (closure review of draft 6, finding 3)
        ablk, bblk = term_blocks(aglos or ''), term_blocks(bglos or '')
        real_kind = {t: 'ADDED' for t in set(ablk) - set(bblk)}
        real_kind.update({t: 'REMOVED' for t in set(bblk) - set(ablk)})
        real_kind.update({t: 'MODIFIED' for t in set(ablk) & set(bblk) if ablk[t] != bblk[t]})
        listed_kind = {r[0]: r[1] for r in table(section(c, 'Glossary changes'))}
        verb = {'ADDED': 'added', 'REMOVED': 'removed', 'MODIFIED': 'modified'}
        does = {'ADDED': 'adds', 'REMOVED': 'removes', 'MODIFIED': 'redefines'}
        for term, kind in listed_kind.items():
            if real_kind.get(term) != kind:
                self.refuse('change', f'{where}: glossary term {term} is not {verb.get(kind, kind)} by the real change')
        for term, kind in sorted(real_kind.items()):
            if term not in listed_kind:
                self.refuse('change', f'{where}: the real change {does[kind]} glossary term {term}, which Glossary changes does not list')
        av, bv = read(self.p('docs/vision.md')) or '', read(b.p('docs/vision.md')) or ''
        flat = lambda s: re.sub(r'\s+', ' ', s).strip()
        vis = section(c, 'Vision changes') or ''
        listed_v = re.findall(r'^- [^\n]*?, (added|removed): "(.+)"\s*$', vis, re.M)
        quotes = [q for _, q in listed_v]
        for kind, q in listed_v:
            now, was = flat(q) in flat(av), flat(q) in flat(bv)
            if kind == 'added' and (not now or was):
                self.refuse('change', f'{where}: vision line "{q[:50]}..." is not added by the real change')
            if kind == 'removed' and (now or not was):
                self.refuse('change', f'{where}: vision line "{q[:50]}..." is not removed by the real change')
        # both ways: every sentence the real change adds to or removes from the vision is listed. The vision's
        # Decisions section is the round log (m5 writes it from the round record and checks it), so it is left out.
        au, bu = vision_units(av), vision_units(bv)
        for kind, units in (('added', au - bu), ('removed', bu - au)):
            for u in sorted(units):
                if not any(u in flat(q) for k, q in listed_v if k == kind):
                    self.refuse('change', f'{where}: the real change {"adds" if kind == "added" else "removes"} vision line "{u[:60]}", which Vision changes does not list')
        badrs, aadrs = b.adrs(), self.adrs()
        new_adrs = re.findall(r'^- New: \[ADR (\d{4})\]', section(c, 'Decisions') or '', re.M)
        if not new_adrs:
            self.refuse('adr', f'{where}: no new decision record (every pack holds one; an idea is not one)')
        for n in new_adrs:
            if n not in aadrs or n in badrs:
                self.refuse('change', f'{where}: ADR {n} is not added by the real change')
        for n in set(aadrs) - set(badrs) - set(new_adrs):
            self.refuse('change', f'{where}: the real change adds ADR {n}, which Decisions does not list')
        for j, k in change_objectives.items():
            if j not in manifest:
                self.refuse('reference', f'{where}: objective {j} has no journey in .done-done.yaml')
            if k == 'new' and j in b.journeys_manifest():
                self.refuse('change', f'{where}: objective {j} is marked new but the base already has it')
            if k == 'preserve' and j not in b.journeys_manifest():
                self.refuse('change', f'{where}: objective {j} is marked preserve but the base lacks it')
            if j not in objectives:
                self.refuse('reference', f'{where}: objective {j} is in no spec Objectives table')
        if depth == 'full':
            ms, bs, tk = self.charter_tables(section(c, 'Charter') or '', where + ' Charter')
            self.check_charter(ms, bs, tk, objectives, where + ' Charter')
            if not (section(c, 'Screens changed') or '').strip():
                self.refuse('visual', f'{where}: Screens changed is empty (write "None: <why>")')
        cl = section(c, 'Changelog') or ''
        listed = [(k, v.strip()) for k, v in re.findall(r'^- (Added|Changed|Removed|Fixed|Deprecated|Security): (.+)$', cl, re.M)]
        if not listed:
            self.refuse('change', f'{where}: no changelog lines')

        def unreleased(root):
            t = read(os.path.join(root, 'CHANGELOG.md')) or ''
            u = re.search(r'^## \[Unreleased\]\n(.*?)(?=^## \[|\Z)', t, re.M | re.S)
            out, sec = [], None
            for line in (u.group(1) if u else '').splitlines():
                h = re.match(r'### (\w+)', line)
                if h:
                    sec = h.group(1)
                elif line.startswith('- '):
                    out.append((sec, line[2:].strip()))
            return out
        real = [x for x in unreleased(self.root) if x not in unreleased(before_root)]
        if sorted(real) != sorted(listed):
            self.refuse('change', f'{where}: changelog lines {sorted(listed)} differ from the real Unreleased lines {sorted(real)}')


def term_blocks(g):
    """Every glossary term (a ### heading) with its whole definition, whitespace-flattened; a term under two headings
    keeps both blocks."""
    out = {}
    for name, body in re.findall(r'^### ([^\n]+)\n(.*?)(?=^### |^## |\Z)', g, re.M | re.S):
        out[name.strip()] = (out.get(name.strip(), '') + ' ' + re.sub(r'\s+', ' ', body)).strip()
    return out


def vision_units(text):
    """The sentences of a vision outside its Decisions section, whitespace-flattened, list markers dropped."""
    body = re.sub(r'^## Decisions\n.*?(?=^## |\Z)', '', text.split('---', 2)[-1] if text.startswith('---') else text, flags=re.M | re.S)
    out = set()
    for block in re.split(r'\n\s*\n|\n(?=- |#)', body):
        b = re.sub(r'\s+', ' ', block).strip()
        b = re.sub(r'^(- |#+ )', '', b)
        for sent in re.split(r'(?<=[.!?])\s+(?=[A-Z*"])', b):
            if sent.strip():
                out.add(sent.strip())
    return out


def run_journey(root, jid):
    r = subprocess.run([sys.executable and 'node', 'journeys/run.ts', jid], cwd=root, capture_output=True, text=True)
    first = (r.stdout.splitlines() or [''])[0]
    return r.returncode, first


def overlay(head, src_dir, tmp):
    d = os.path.join(tmp, 'base')
    shutil.copytree(head, d)
    shutil.rmtree(os.path.join(d, 'src'))
    shutil.copytree(os.path.join(src_dir, 'src'), os.path.join(d, 'src'))
    return d


def objectives_run(head, base_src, spec_slug, base_only=False):
    """m2c's objectives rule: a new journey fails on its named assertion on the base and passes on the head; a preserve
    journey passes on both; exit 77 is a setup error, never the expected failure. base_only runs the base half alone
    (no head code yet): the head column is None and only the base condition decides."""
    out = []
    p = Pack(head)
    objs = p.specs()[spec_slug]
    with tempfile.TemporaryDirectory(prefix='pack-check-') as tmp:
        base = overlay(head, base_src, tmp)
        for j, kind in objs.items():
            bc, bl = run_journey(base, j)
            hc = None if base_only else run_journey(head, j)[0]
            base_ok = (kind == 'new' and bc == 1 and bl.startswith('assert: ')) or (kind == 'preserve' and bc == 0)
            out.append((j, kind, bc, bl, hc, base_ok and (base_only or hc == 0)))
    return out


def code_check(root):
    p = Pack(root)
    m = p.model()
    missing = []
    for name, o in m['objects'].items():
        src = read(p.p(o['lives_in'])) or ''
        for meth in o['behaviour']:
            if not re.search(r'^\s*(static\s+)?' + re.escape(meth) + r'\s*\(', src, re.M):
                missing.append(f'{name}.{meth} not found in {o["lives_in"]}')
    return missing


MUTANTS = [  # (name, file, find, replace, expected clause text) - each planted fault must be refused with its own line
    ('idea-only ADR: one option', 'docs/adr/0002-keep-conversations-in-one-store-file.md', '- SQLite on the host.\n- Postgres as a separate service.\n', '', 'fewer than two considered options'),
    ('idea-only ADR: no decision', 'docs/adr/0001-use-typescript-on-node.md', 'We use TypeScript on Node, because', 'Maybe TypeScript on Node, because', 'no decision line'),
    ('idea-only ADR: no consequences', 'docs/adr/0003-host-on-one-small-server.md', '- Bad: one server is one point of failure', '- one server is one point of failure', 'consequences need a Good and a Bad line'),
    ('idea-only ADR: no confirmation', 'docs/adr/0003-host-on-one-small-server.md', 'Each release record names the server and the version; the done-done receipts of the objective journeys are taken on\nthat released build.\n', '', 'no confirmation'),
    ('missing vision', 'docs/vision.md', None, None, 'docs/vision.md is missing'),
    ('vision left as a template', 'docs/vision.md', 'Two weeks of agent time for the first charter.', '<How much time this is worth>', 'vision: a template placeholder'),
    ('fields-only object', 'docs/domain/model.md', '- Behaviour: `create(reason)`, `accept(agent)`, `close(note)`', '- Behaviour: none', 'Handoff has no behaviour'),
    ('invariant with no breaking journey', 'docs/domain/model.md', '  - a closed handoff cannot be accepted (proved by `closed-handoff-cannot-be-accepted`)', '  - a closed handoff cannot be accepted', 'names no journey that tries to break it'),
    ('no lifecycle line', 'docs/domain/model.md', '- Lifecycle: the Handoff state machine below.\n', '', 'Handoff has no Lifecycle line'),
    ('start edge with no row', 'docs/domain/model.md', '| [*] | waiting | create | a reason is given | HandoffRequested | bot-hands-off-unknown |\n', '', 'diagram edge [*] --> waiting : create has no table row'),
    ('empty guard', 'docs/domain/model.md', '| answered | awaiting_answer | receive | always |', '| answered | awaiting_answer | receive |  |', 'has no guard'),
    ('entity not in glossary', 'docs/domain/model.md', 'AGENT ||--o{ HANDOFF : accepts', 'SUPERVISOR ||--o{ HANDOFF : accepts', 'entity SUPERVISOR is not a glossary term'),
    ('journey no objective has', 'docs/charter.md', '| C2 | Command line for the bot | B1 | - | none (the public operations) | first-question-gets-answer |', '| C2 | Command line for the bot | B1 | - | none (the public operations) | widget-loads |', 'names journey widget-loads'),
    ('ticket waits on its own batch', 'docs/charter.md', '| C2 | Command line for the bot | B1 | - |', '| C2 | Command line for the bot | B1 | C1 |', "depends on C1 in its own batch"),
    ('no hosting record at complete', 'docs/adr/0003-host-on-one-small-server.md', 'kind: hosting', 'kind: other', 'decision record of kind hosting'),
    ('stateful object: machine removed, "Lifecycle: none" with no reason', 'docs/domain/model.md',
     [('### Handoff state machine\nStates: waiting, accepted, closed\n```mermaid\nstateDiagram-v2\n  [*] --> waiting : create\n  waiting --> accepted : accept\n  accepted --> closed : close\n```\n\n| From | To | Trigger | Guard | Effect | Journey |\n|---|---|---|---|---|---|\n| [*] | waiting | create | a reason is given | HandoffRequested | bot-hands-off-unknown |\n| waiting | accepted | accept | the handoff is waiting | HandoffAccepted | agent-closes-handoff |\n| accepted | closed | close | a note is given | HandoffClosed | agent-closes-handoff |\n', ''), ('- Lifecycle: the Handoff state machine below.', '- Lifecycle: none')],
     None, ['"Lifecycle: none" gives no reason', 'Handoff keeps a state field but has no state machine']),
    ('stateful object: machine removed, a reason given', 'docs/domain/model.md',
     [('### Handoff state machine\nStates: waiting, accepted, closed\n```mermaid\nstateDiagram-v2\n  [*] --> waiting : create\n  waiting --> accepted : accept\n  accepted --> closed : close\n```\n\n| From | To | Trigger | Guard | Effect | Journey |\n|---|---|---|---|---|---|\n| [*] | waiting | create | a reason is given | HandoffRequested | bot-hands-off-unknown |\n| waiting | accepted | accept | the handoff is waiting | HandoffAccepted | agent-closes-handoff |\n| accepted | closed | close | a note is given | HandoffClosed | agent-closes-handoff |\n', ''), ('- Lifecycle: the Handoff state machine below.', '- Lifecycle: none - it is simple')],
     None, 'Handoff keeps a state field but has no state machine'),
    ('no decision record at all', 'docs/adr', None, None, 'docs/adr holds no decision record'),
    ('rule with no check', 'docs/ways-of-working.md', '| Strict types, no `any` | refusals are typed, not guessed | typescript-eslint strictTypeChecked in `core/standards/typescript-react/base.js` |', '| Strict types, no `any` | refusals are typed, not guessed |  |', 'names no check'),
]
CHANGE_MUTANTS = [
    ('change pack omits a named journey from Objectives', 'docs/changes/rate-a-conversation.md', '- reopen-clears-rating (new)\n', '', 'names journey reopen-clears-rating, which its Objectives omit'),
    ('change pack ADR reduced to an idea', 'docs/adr/0004-store-the-rating-on-the-conversation.md', '- A separate ratings list keyed by conversation id, written by a reporting service.\n', '', 'fewer than two considered options'),
    ('change pack with no decision record', 'docs/changes/rate-a-conversation.md', '- New: [ADR 0004](../adr/0004-store-the-rating-on-the-conversation.md) store the rating on the conversation (accepted).\n', '', 'no new decision record'),
    ('vision line not really added', 'docs/changes/rate-a-conversation.md', 'and that score is kept with it."', 'and that score is shown to the agent."', 'is not added by the real change'),
    ('changelog differs from the real lines', 'docs/changes/rate-a-conversation.md', '- Changed: Reopening a conversation clears its rating.\n', '', 'differ from the real Unreleased lines'),
    ('a real behaviour left out', 'docs/changes/rate-a-conversation.md', '| Conversation | `rate(score)` |', '| Conversation | - |', 'adds Conversation.rate, which Objects changed does not list'),
    ('a feature ticket waits on a later batch', 'docs/changes/rate-a-conversation.md', '| R1 | Conversation can be rated | B1 | - |', '| R1 | Conversation can be rated | B1 | R2 |', 'depends on R2 of a later batch'),
    ('an unlisted vision promise (closure review, finding 3)', 'docs/vision.md', 'and that score is kept with it.', 'and that score is kept with it. Support leads can export every rating to a report.', 'adds vision line "Support leads can export every rating to a report.", which Vision changes does not list'),
    ('an unlisted vision removal', 'docs/vision.md', ' No question waits without an owner: it is with the bot, with a person, or resolved.', '', 'removes vision line "No question waits without an owner'),
    ('an unlisted new meaning for an existing term (closure review of draft 6, finding 3)', 'GLOSSARY.md', 'One turn from the user or the bot inside a conversation.', 'One turn from the user, the bot or an external auditor inside a conversation.', 'the real change redefines glossary term Message, which Glossary changes does not list'),
    ('a term listed with a kind the real change did not make', 'docs/changes/rate-a-conversation.md', '| Rating | ADDED |', '| Rating | MODIFIED |', 'glossary term Rating is not modified by the real change'),
]
# Cases that must PASS: a legitimate stateless value object with a reason (closure review, finding 8)
POSITIVE = [
    ('a stateless value object with a reason passes', [
        ('GLOSSARY.md', '## Other terms\n\n### Message\n', '### Answer source\nA document or page the bot may quote; every answer names at least one. Owns: a source has a link.\n_Avoid_: knowledge, context\n\n## Other terms\n\n### Message\n'),
        ('GLOSSARY.md', '\n### Answer source\nA document or page the bot may quote; every answer names at least one.\n_Avoid_: knowledge, context\n\n### User', '\n### User'),
        ('docs/domain/model.md', '## State machines\n', '### Answer source\n- Responsibility: name one document or page an answer quotes.\n- Behaviour: `cite(link)`\n- Invariants:\n  - a source has a link (proved by `answer-without-source-refused`)\n- Lives in: `src/domain/conversation.ts`\n- Lifecycle: none - a value: it is written once when quoted and never changes.\n- Fields: title, link\n\n## State machines\n'),
    ]),
]


def mutate(root, tmp, name, f, find, repl):
    """A copy of root with one planted fault: find None removes f (a file or a folder); find a list of (find, repl)
    pairs applies each to f in turn."""
    d = os.path.join(tmp, re.sub(r'\W+', '-', name))
    shutil.copytree(root, d)
    p = os.path.join(d, f)
    if find is None:
        shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
        return d
    for fd, rp in (find if isinstance(find, list) else [(find, repl)]):
        s = open(p).read()
        assert fd in s, f'mutant {name}: text not found in {f}'
        open(p, 'w').write(s.replace(fd, rp, 1))
    return d


def hits(refusals, want):
    """Every expected clause text is refused (want is one text or a list)."""
    wants = want if isinstance(want, list) else [want]
    got = [next((x for x in refusals if w in x), None) for w in wants]
    return got if all(got) else None


SHORT_ADR = """---
status: accepted
date: 2026-12-20
decision-makers: the captain
kind: feature
muster: rating feature muster
---
# Store the rating on the conversation

## Context and problem
A rating needs a home that clears on reopen.

## Considered options
- A field on Conversation, set by `rate(score)`. (chosen)
- A separate ratings list.

## Decision
We keep the rating on Conversation, because the reopen rule lives there.

## Consequences
- Good: one owner for the rule. Bad: reports read whole conversations.

## Confirmation
The journey `reopen-clears-rating` passes.
"""
IDEA_ADR = """---
date: 2026-12-20
---
# Ratings

## Context and problem
Maybe store ratings somewhere; a table could work, or the conversation.

## Confirmation
To be decided.
"""


def light_case(rt, hd, tmp, adr_text):
    d = os.path.join(tmp, 'light-' + str(len(os.listdir(tmp))))
    shutil.copytree(rt, d)
    open(os.path.join(d, 'docs/adr/0004-store-the-rating-on-the-conversation.md'), 'w').write(adr_text)
    c = os.path.join(d, 'docs/changes/rate-a-conversation.md')
    s = open(c).read()
    s = re.sub(r'## Charter\n.*?(?=## Changelog)', '', s, flags=re.S).replace('depth: full', 'depth: light')
    open(c, 'w').write(s)
    os.remove(os.path.join(d, 'docs/design/rate-a-conversation.md'))
    return Pack(d).gate('light', 'rate-a-conversation', hd)


def main(argv):
    if len(argv) >= 2 and argv[0] == 'gate':
        a = argv[1:]
        root = a[0]
        depth = a[a.index('--depth') + 1]
        change = a[a.index('--change') + 1] if '--change' in a else None
        before = a[a.index('--before') + 1] if '--before' in a else None
        r = Pack(root).gate(depth, change, before)
        print('\n'.join(r) if r else 'PASS')
        return 1 if r else 0
    if len(argv) >= 2 and argv[0] == 'objectives':
        a = argv[1:]
        head, base_src = a[0], a[a.index('--base-src') + 1]
        slug = a[a.index('--spec') + 1] if '--spec' in a else a[a.index('--change') + 1]
        rows = objectives_run(head, base_src, slug, '--base-only' in a)
        for j, kind, bc, bl, hc, ok in rows:
            print(f'{"ok  " if ok else "FAIL"} {j} ({kind}): base exit {bc} "{bl}"' + ('' if hc is None else f'; head exit {hc}'))
        bad = [r for r in rows if not r[5]]
        print('PASS' if not bad else f'refused: objectives: {len(bad)} journey(s) break the rule')
        return 1 if bad else 0
    if len(argv) >= 2 and argv[0] == 'code':
        miss = code_check(argv[1])
        print('\n'.join('refused: code: ' + m for m in miss) if miss else 'PASS')
        return 1 if miss else 0
    if len(argv) != 2 or argv[0] != 'all':
        print(__doc__)
        return 2
    ex = argv[1]
    hd, rt, sk = (os.path.join(ex, x) for x in ('helpdesk', 'rated', 'skeleton'))
    rc = 0
    print('== 1. gate: the brand-new project at complete depth')
    r = Pack(hd).gate('complete')
    print('\n'.join(r) if r else 'PASS (0 refusals, 0 missing references)')
    rc |= bool(r)
    print('== 2. gate: the rating feature at full depth, change pack against the real diff (before = helpdesk)')
    r = Pack(rt).gate('full', 'rate-a-conversation', hd)
    print('\n'.join(r) if r else 'PASS (0 refusals, 0 missing references, every delta line matches the real diff)')
    rc |= bool(r)
    print('== 3. objectives: brand-new project (base = skeleton commit, head = built charter)')
    for j, kind, bc, bl, hc, ok in objectives_run(hd, sk, 'helpdesk'):
        print(f'  {"ok  " if ok else "FAIL"} {j} ({kind}): base exit {bc} "{bl}"; head exit {hc}')
        rc |= not ok
    print('== 4. objectives: feature (base = helpdesk code with the feature journeys, head = rated)')
    for j, kind, bc, bl, hc, ok in objectives_run(rt, hd, 'rate-a-conversation'):
        print(f'  {"ok  " if ok else "FAIL"} {j} ({kind}): base exit {bc} "{bl}"; head exit {hc}')
        rc |= not ok
    print('== 5. code: every behaviour of the model is found in its Lives-in module')
    for root in (hd, rt):
        miss = code_check(root)
        print(f'  {os.path.basename(root)}: ' + ('PASS' if not miss else '; '.join(miss)))
        rc |= bool(miss)
    print('== 6. planted faults: each must be refused with its own line')
    with tempfile.TemporaryDirectory(prefix='pack-mutants-') as tmp:
        for name, f, find, repl, want in MUTANTS:
            d = mutate(hd, tmp, name, f, find, repl)
            r = Pack(d).gate('complete')
            hit = hits(r, want)
            print(f'  {"ok  " if hit else "FAIL"} {name}: ' + (' | '.join(hit) if hit else 'not refused; got ' + str(r[:3])))
            rc |= not hit
        for name, f, find, repl, want in CHANGE_MUTANTS:
            d = mutate(rt, tmp, name, f, find, repl)
            r = Pack(d).gate('full', 'rate-a-conversation', hd)
            hit = hits(r, want)
            print(f'  {"ok  " if hit else "FAIL"} {name}: ' + (' | '.join(hit) if hit else 'not refused; got ' + str(r[:3])))
            rc |= not hit
        for name, edits in POSITIVE:
            d = os.path.join(tmp, re.sub(r'\W+', '-', name))
            shutil.copytree(hd, d)
            for f, fd, rp in edits:
                t = open(os.path.join(d, f)).read()
                assert fd in t, f'positive case {name}: text not found in {f}'
                open(os.path.join(d, f), 'w').write(t.replace(fd, rp, 1))
            r = Pack(d).gate('complete')
            print(f'  {"ok  " if not r else "FAIL"} {name}: ' + ('PASS' if not r else 'refused: ' + str(r[:3])))
            rc |= bool(r)
    print('== 7. light depth: a short real decision record passes; an idea-only one, no record, or no named feature is refused')
    with tempfile.TemporaryDirectory(prefix='pack-light-') as tmp:
        d = os.path.join(tmp, 'no-adr')
        shutil.copytree(rt, d)
        shutil.rmtree(os.path.join(d, 'docs/adr'))
        r = Pack(d).gate('light')
        hit = [x for x in r if 'light depth checks a feature' in x]
        print('  ' + ('ok   light depth with no feature named (no decision records either): ' + hit[0] if hit else 'FAIL light depth with no feature named: ' + str(r or 'PASS')))
        rc |= not hit
        r = Pack(d).gate('light', 'rate-a-conversation', hd)
        hit = hits(r, ['docs/adr holds no decision record', 'ADR 0004 is not added by the real change'])
        print('  ' + ('ok   light depth, feature named, no decision record: ' + ' | '.join(hit) if hit else 'FAIL light depth, feature named, no decision record: ' + str(r or 'PASS')))
        rc |= not hit
        r = Pack(rt).gate('full')
        hit = [x for x in r if 'full depth checks a feature' in x]
        print('  ' + ('ok   full depth with no feature named: ' + hit[0] if hit else 'FAIL full depth with no feature named: ' + str(r or 'PASS')))
        rc |= not hit
        r = light_case(rt, hd, tmp, SHORT_ADR)
        print('  ' + ('ok   short record at light depth: PASS' if not r else 'FAIL short record refused: ' + str(r)))
        rc |= bool(r)
        r = light_case(rt, hd, tmp, IDEA_ADR)
        hit = [x for x in r if 'an idea, not a decision' in x]
        print('  ' + ('ok   idea-only record at light depth: ' + hit[0] if hit else 'FAIL idea-only record not refused: ' + str(r)))
        rc |= not hit
    print('== result:', 'PASS' if rc == 0 else 'FAIL')
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

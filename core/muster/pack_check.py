#!/usr/bin/env python3
"""pack_check.py - the pack gate of a muster: checks a project's documents (the "pack") for their depth.

Usage:
  pack_check.py <project> --depth complete
  pack_check.py <project> --depth full|light --change <slug> --before <dir>

Entry point: bin/jg-muster-gate.sh. Plan verification in approval.py shares the pack readers. Reads files under
<project> and <dir>, writes nothing, makes no
model call and no network call, and prints the same lines for the same files.

complete checks a brand-new project's whole pack. full and light check a feature: the project is the tree after the
feature, <dir> is the tree before it, and `docs/changes/<slug>.md` (the change pack) is compared with the real
difference between the two, both ways.

Exit 0 prints `PASS` and reports legacy technical design paths on stderr. Exit 1 prints one
`refused: <clause>: <detail>` line for every finding. Exit 2 is a usage error or a failure to read the files,
named on stderr.

Standard library only; run it as `python3 -I`.
"""
import argparse
import os
import re
import sys

PH = re.compile(r'<[^<>\n]{2,60}>')  # a template placeholder left in a filled document
SLUG = re.compile(r'[a-z0-9][a-z0-9-]*\Z')
USE_CASE_CATALOGUE = 'docs/use-cases.md'
USE_CASE_FIELDS = ('ID', 'Actors', 'Goal', 'Main flow', 'Alternate flow', 'Failure flow', 'Journeys', 'Domain objects')
VISION_SECTIONS = ('Press release', 'Who it is for', 'End state', 'Time budget', 'No-gos', 'Open risks', 'FAQ', 'Decisions')
VISION_LINES = 60  # one page


def read(p):
    if not os.path.isfile(p):
        return None
    with open(p, encoding='utf-8') as f:
        return f.read()


def section(text, title, level=2):
    """The body of a markdown section whose heading starts with `title` (up to the next heading of that level or higher)."""
    pat = r'^' + '#' * level + r' ' + re.escape(title) + r'[^\n]*\n(.*?)(?=^#{1,%d} |\Z)' % level
    m = re.search(pat, text or '', re.M | re.S)
    return m.group(1) if m else None


class Row(list):
    """A table row whose missing cells read as empty, so a short row is a finding and never a crash."""

    def __getitem__(self, i):
        try:
            return super().__getitem__(i)
        except IndexError:
            return ''


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
        rows.append(Row(cells))
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


def flat(s):
    return re.sub(r'\s+', ' ', s).strip()


def term_blocks(g):
    """Every glossary term (a ### heading) with its whole definition, whitespace-flattened; a term under two headings
    keeps both blocks."""
    out = {}
    for name, body in re.findall(r'^### ([^\n]+)\n(.*?)(?=^### |^## |\Z)', g, re.M | re.S):
        out[name.strip()] = (out.get(name.strip(), '') + ' ' + flat(body)).strip()
    return out


def vision_units(text):
    """The sentences of a vision outside its Decisions section, whitespace-flattened, list markers dropped."""
    body = text.split('---', 2)[-1] if text.startswith('---') else text
    body = re.sub(r'^## Decisions\n.*?(?=^## |\Z)', '', body, flags=re.M | re.S)
    out = set()
    for block in re.split(r'\n\s*\n|\n(?=- |#)', body):
        b = re.sub(r'^(- |#+ )', '', flat(block))
        for sent in re.split(r'(?<=[.!?])\s+(?=[A-Z*"])', b):
            if sent.strip():
                out.add(sent.strip())
    return out


class Pack:
    """One project tree: parses its documents and collects refusals."""

    def __init__(self, root):
        self.root = root
        self.refusals = []
        self.warnings = []

    def refuse(self, clause, detail):
        self.refusals.append(f'refused: {clause}: {detail}')

    def p(self, rel):
        return os.path.join(self.root, rel)

    # ---------------------------------------------------------------- parsing
    def glossary(self):
        g = read(self.p('GLOSSARY.md'))
        if g is None:
            self.refuse('glossary', 'GLOSSARY.md is missing')
            return set(), set()
        core_s = section(g, 'Core objects') or ''
        core = {m.strip() for m in re.findall(r'^### (.+)$', core_s, re.M)}
        terms = {m.strip() for m in re.findall(r'^### (.+)$', g, re.M)}
        return core, terms

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
            rows = [dict(zip(['from', 'to', 'trigger', 'guard', 'effect', 'journey'], list(r) + [''] * 6)) for r in table(body)]
            machines[name] = {'states': states, 'edges': edges, 'rows': rows}
        return {'entities': entities, 'objects': objects, 'machines': machines}

    def specs(self):
        """The objectives of every spec: {journey id: kind}."""
        out = {}
        d = self.p('docs/specs')
        for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            if not f.endswith('.md'):
                continue
            s = read(os.path.join(d, f)) or ''
            for r in table(section(s, 'Objectives') or ''):
                if len(r) >= 2:
                    out[r[0].strip('`')] = r[1]
            fm = s.split('---')[1] if s.startswith('---') else ''
            for key in ('title', 'slug', 'status', 'created', 'updated', 'owner', 'links'):
                if not re.search(r'^' + key + r':', fm, re.M):
                    self.refuse('spec', f'docs/specs/{f} has no spec-docs field {key}')
            if '## Verification' not in s:
                self.refuse('spec', f'docs/specs/{f} has no Verification section')
        return out

    def manifest(self):
        """The journeys of .done-done.yaml: {journey id: command}."""
        y = read(self.p('.done-done.yaml')) or ''
        return dict(re.findall(r'^  ([\w-]+): \{[^}]*command: ([^}]+)\}', y, re.M))

    def adrs(self):
        out = {}
        d = self.p('docs/adr')
        for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            m = re.match(r'(\d{4})-.*\.md$', f)
            if m:
                out[m.group(1)] = (f, read(os.path.join(d, f)) or '')
        return out

    # ---------------------------------------------------------------- clauses: decision records
    def check_adr(self, f, text):
        """One decision record; returns its kind. A record missing any of its six parts is an idea."""
        where = f'docs/adr/{f}'
        if not re.search(r'^status: (.+)$', text, re.M):
            self.refuse('adr', f'{where}: no status (an idea, not a decision)')
        if not (section(text, 'Context') or '').strip():
            self.refuse('adr', f'{where}: no context')
        if len(re.findall(r'^- ', section(text, 'Considered options') or '', re.M)) < 2:
            self.refuse('adr', f'{where}: fewer than two considered options (an idea, not a decision)')
        if not (section(text, 'Decision') or '').strip().startswith('We '):
            self.refuse('adr', f'{where}: no decision line starting "We" (an idea, not a decision)')
        cons = section(text, 'Consequences') or ''
        if 'Good:' not in cons or 'Bad:' not in cons:
            self.refuse('adr', f'{where}: consequences need a Good and a Bad line')
        if not (section(text, 'Confirmation') or '').strip():
            self.refuse('adr', f'{where}: no confirmation (no check enforces it)')
        ph = PH.search(text.split('---', 2)[-1])
        if ph:
            self.refuse('adr', f'{where}: a template placeholder is left: {ph.group(0)}')
        k = re.search(r'^kind: (\w+)', text, re.M)
        return k.group(1) if k else ''

    def check_adrs(self, adrs, objectives, manifest):
        if not adrs:
            self.refuse('adr', 'docs/adr holds no decision record (every pack at every depth holds at least one)')
        kinds = set()
        for f, text in adrs.values():
            kinds.add(self.check_adr(f, text))
            confirmation = section(text, 'Confirmation') or ''
            for j in re.findall(r'`([a-z][a-z0-9]*(?:-[a-z0-9]+)+)`', confirmation):
                if j in manifest and j not in objectives:
                    self.refuse('reference', f'docs/adr/{f}: confirmation names journey {j}, which no spec objective has')
                if 'journey' in confirmation and j not in manifest and not j.startswith(('core', 'src', 'journeys')):
                    self.refuse('reference', f'docs/adr/{f}: confirmation names journey {j}, which .done-done.yaml lacks')
        return kinds

    # ---------------------------------------------------------------- clauses: the domain model
    def check_model(self, model, core, terms, objectives):
        tnorm = {norm_term(t) for t in terms}
        for e in sorted(model['entities']):
            if norm_term(e) not in tnorm:
                self.refuse('reference', f'model: entity {e} is not a glossary term')
        for name in model['objects']:
            if name not in core:
                self.refuse('reference', f'model: core object {name} is not a glossary core object')
        for name in sorted(core):
            if name not in model['objects']:
                self.refuse('reference', f'glossary: core object {name} has no section in the model')
        for name, o in model['objects'].items():
            self.check_object(name, o, model['machines'], objectives)
        for name, sm in model['machines'].items():
            self.check_machine(name, sm, model['objects'].get(name, {'behaviour': []}), objectives)

    def check_object(self, name, o, machines, objectives):
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
        elif name not in machines:
            self.refuse('model', f'{name} names a lifecycle but the model has no {name} state machine')

    def check_machine(self, name, sm, obj, objectives):
        if not sm['states']:
            self.refuse('model', f'{name} state machine lists no states')
        if not any(e[0] == '[*]' for e in sm['edges']):
            self.refuse('model', f'{name} state machine has no start edge [*] --> <state>')
        table_edges = set()
        for r in sm['rows']:
            table_edges.add((r['from'], r['to'], r['trigger']))
            arrow = f'transition {r["from"]} -> {r["to"]}'
            if r['from'] != '[*]' and r['from'] not in sm['states']:
                self.refuse('model', f'{name}: transition from unknown state {r["from"]}')
            if r['to'] not in sm['states']:
                self.refuse('model', f'{name}: transition to unknown state {r["to"]}')
            if not r['trigger'] or r['trigger'] not in obj['behaviour']:
                self.refuse('model', f'{name}: {arrow} has trigger "{r["trigger"]}", not a behaviour of {name}')
            if not r['guard']:
                self.refuse('model', f'{name}: {arrow} has no guard (write "always")')
            js = ids(r['journey'])
            if not js:
                self.refuse('model', f'{name}: {arrow} is driven by no journey')
            for j in js:
                if j not in objectives:
                    self.refuse('reference', f'{name}: {arrow} names journey {j}, which no spec objective has')
        for e in sorted(sm['edges'] - table_edges):
            self.refuse('model', f'{name}: diagram edge {e[0]} --> {e[1]} : {e[2]} has no table row')
        for e in sorted(table_edges - sm['edges']):
            self.refuse('model', f'{name}: table row {e[0]} -> {e[1]} ({e[2]}) has no diagram edge')

    # ---------------------------------------------------------------- clauses: journeys, vision, rules, charter
    def check_journeys(self, objectives, manifest):
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

    def check_use_cases(self):
        """Check the catalogue against the approved project's journeys and core objects."""
        catalogue = read(self.p(USE_CASE_CATALOGUE))
        if catalogue is None:
            self.refuse('use cases', f'{USE_CASE_CATALOGUE} is missing from the approved pack')
            return
        block = section(catalogue, 'Use cases') or ''
        header = tuple(cell.strip() for cell in next(
            (line for line in block.splitlines() if line.startswith('|')), ''
        ).strip('|').split('|'))
        rows = table(block)
        if header != USE_CASE_FIELDS or not rows:
            self.refuse('use cases', f'{USE_CASE_CATALOGUE} needs a Use cases table with columns '
                        + ', '.join(USE_CASE_FIELDS) + ' and at least one use case')
            return
        journeys = set(self.manifest())
        objects = set((self.model() or {}).get('objects', {}))
        seen = set()
        covered = set()
        for row in rows:
            case = row[0].strip('`')
            if len(row) != len(USE_CASE_FIELDS) or any(not cell or PH.search(cell) for cell in row):
                self.refuse('use cases', f'{case or "(unnamed row)"}: fill every use case column')
                continue
            if not SLUG.fullmatch(case) or case in seen:
                self.refuse('use cases', f'{case}: use a unique lowercase use case id')
            seen.add(case)
            links = set(ids(row[6]))
            domain = set(ids(row[7]))
            if not links:
                self.refuse('use cases', f'{case} has no journey')
            for journey in sorted(links - journeys):
                self.refuse('use cases', f'{case} names unknown journey {journey}')
            if not domain:
                self.refuse('use cases', f'{case} has no domain object')
            for name in sorted(domain - objects):
                self.refuse('use cases', f'{case} names unknown domain object {name}')
            covered.update(links)
        for journey in sorted(journeys - covered):
            self.refuse('use cases', f'journey {journey} has no use case')

    def check_vision(self):
        v = read(self.p('docs/vision.md'))
        if v is None:
            self.refuse('vision', 'docs/vision.md is missing')
            return
        body = v.split('---', 2)[-1]
        for s in VISION_SECTIONS:
            if not (section(body, s) or '').strip():
                self.refuse('vision', f'section "{s}" is missing or empty')
        ph = PH.search(body)
        if ph:
            self.refuse('vision', f'a template placeholder is left: {ph.group(0)}')
        if len(body.strip().splitlines()) > VISION_LINES:
            self.refuse('vision', f'over one page ({VISION_LINES} lines)')

    def check_rules(self, adrs):
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

    def charter_tables(self, text, where):
        ts = tables(text)
        ms = next((t for t in ts if t and len(t[0]) == 4), [])
        bs = next((t for t in ts if t and len(t[0]) == 3), [])
        tk = next((t for t in ts if t and len(t[0]) == 6), [])
        if not (ms and bs and tk):
            self.refuse('charter', f'{where}: the milestone, batch and ticket tables are not all present')
        return ms, bs, tk

    def check_charter(self, ms, bs, tk, objectives, where):
        batches = {r[0]: ([] if r[1].startswith('-') else ids(r[1])) for r in bs}
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
        tickets = {r[0]: {'batch': r[2], 'depends': ids(r[3]), 'journeys': ids(r[5])} for r in tk}
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
        return claimed

    def check_project_charter(self, objectives):
        c = read(self.p('docs/charter.md'))
        if c is None:
            self.refuse('charter', 'docs/charter.md is missing')
            return
        ms, bs, tk = self.charter_tables(c, 'docs/charter.md')
        claimed = self.check_charter(ms, bs, tk, objectives, 'docs/charter.md')
        for j, k in objectives.items():
            if k == 'new' and j not in claimed:
                self.refuse('charter', f'new journey {j} is claimed by no charter ticket')

    def check_technical_design(self):
        for directory in ('docs/architecture', 'docs/design'):
            root = self.p(directory)
            for name in sorted(os.listdir(root)) if os.path.isdir(root) else []:
                if not name.endswith('.md'):
                    continue
                path = f'{directory}/{name}'
                design = read(self.p(path))
                if design is None:
                    continue
                if directory == 'docs/design':
                    target = f'docs/architecture/{name}'
                    if re.search(r'^# Technical design\b', design, re.M | re.I):
                        self.refuse('design', f'{path} is a technical design; move it to {target}')
                        continue
                    if not (section(design, 'Design:', level=1) is not None
                            and section(design, 'Reference level') is not None):
                        continue
                    self.warnings.append(f'warning: design: {path} is a legacy technical design; use {target}')
                questions = (section(design, 'Unresolved questions') or '').strip()
                if questions and questions != 'None.':
                    self.refuse('design', f'{path} has unresolved questions not held on the board')

    # ---------------------------------------------------------------- the gate
    def gate(self, depth, change=None, before=None):
        if depth not in ('complete', 'full', 'light'):
            self.refuse('depth', f'unknown depth {depth} (complete, full or light; skip has no pack)')
            return self.refusals
        if depth in ('full', 'light') and not (change and before):
            self.refuse('change', f'{depth} depth checks a feature: name its change pack and the documents before it '
                                  '(--change <slug> --before <dir>); with no feature named there is nothing to check')
            return self.refusals
        core, terms = self.glossary()
        model = self.model()
        objectives = self.specs()
        manifest = self.manifest()
        if model is None and depth == 'complete':
            self.refuse('model', 'docs/domain/model.md is missing')
        if model:
            self.check_model(model, core, terms, objectives)
        self.check_journeys(objectives, manifest)
        adrs = self.adrs()
        kinds = self.check_adrs(adrs, objectives, manifest)
        if depth == 'complete':
            for k in ('stack', 'storage', 'hosting'):
                if k not in kinds:
                    self.refuse('adr', f'complete depth needs a decision record of kind {k}')
            self.check_vision()
            self.check_rules(adrs)
            self.check_project_charter(objectives)
        self.check_technical_design()
        if change:
            self.check_change_pack(change, Pack(before), depth, objectives, manifest)
        return self.refusals

    # ---------------------------------------------------------------- the change pack against the real difference
    def check_change_pack(self, slug, b, depth, objectives, manifest):
        where = f'docs/changes/{slug}.md'
        c = read(self.p(where))
        if c is None:
            self.refuse('change', f'{where} is missing')
            return
        empty = {'entities': set(), 'objects': {}, 'machines': {}}
        am, bm = self.model() or empty, b.model() or empty
        self.change_objects(c, am, bm, where)
        change_objectives = self.change_machines(c, am, bm, where)
        self.change_glossary(c, b, where)
        self.change_vision(c, b, where)
        self.change_adrs(c, b, where)
        for j, k in change_objectives.items():
            if j not in manifest:
                self.refuse('reference', f'{where}: objective {j} has no journey in .done-done.yaml')
            if k == 'new' and j in b.manifest():
                self.refuse('change', f'{where}: objective {j} is marked new but the base already has it')
            if k == 'preserve' and j not in b.manifest():
                self.refuse('change', f'{where}: objective {j} is marked preserve but the base lacks it')
            if j not in objectives:
                self.refuse('reference', f'{where}: objective {j} is in no spec Objectives table')
        if depth == 'full':
            ms, bs, tk = self.charter_tables(section(c, 'Charter') or '', where + ' Charter')
            self.check_charter(ms, bs, tk, objectives, where + ' Charter')
            if not (section(c, 'Screens changed') or '').strip():
                self.refuse('visual', f'{where}: Screens changed is empty (write "None: <why>")')
        self.change_changelog(c, b, where)

    def change_objects(self, c, am, bm, where):
        rows = table(section(c, 'Objects changed'))
        for r in rows:
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
        real = {(o, m) for o, ao in am['objects'].items() for m in ao['behaviour']} \
            - {(o, m) for o, bo in bm['objects'].items() for m in bo['behaviour']}
        listed = {(r[0], m) for r in rows for m in re.findall(r'`(\w+)\(', r[1])}
        for o, m in sorted(real - listed):
            self.refuse('change', f'{where}: the real change adds {o}.{m}, which Objects changed does not list')

    def change_machines(self, c, am, bm, where):
        """The state machine changes against the real transition rows; returns the pack's objectives {journey: kind}."""
        sm_rows = table(section(c, 'State machine changes'))
        change_objectives = dict(re.findall(r'^- ([\w-]+) \((new|preserve)\)', section(c, 'Objectives') or '', re.M))

        def keyed(model, obj):
            return {(x['from'], x['to'], x['trigger']): x for x in model['machines'].get(obj, {}).get('rows', [])}

        def edge(tr):
            f, _, t = tr.partition('->')
            return f.strip(), t.strip()
        for r in sm_rows:
            obj, tr, kind, trig = r[0], r[1], r[2], r[3]
            key = (*edge(tr), trig)
            arows, brows = keyed(am, obj), keyed(bm, obj)
            if kind.startswith('ADDED') and (key not in arows or key in brows):
                self.refuse('change', f'{where}: transition {tr} ({trig}) is not added by the real change')
            if kind.startswith('MODIFIED') and (key not in arows or key not in brows or arows[key] == brows[key]):
                self.refuse('change', f'{where}: transition {tr} ({trig}) is not modified by the real change')
            for j in ids(r[5]):
                if j not in change_objectives:
                    self.refuse('reference', f'{where}: state machine change {tr} names journey {j}, which its Objectives omit')
        for obj in am['machines']:
            arows, brows = keyed(am, obj), keyed(bm, obj)
            listed = {(*edge(r[1]), r[3]) for r in sm_rows if r[0] == obj}
            altered = set(arows) ^ set(brows) | {k for k in set(arows) & set(brows) if arows[k] != brows[k]}
            for k in sorted(altered - listed):
                self.refuse('change', f'{where}: the real change alters {obj} transition {k[0]} -> {k[1]} ({k[2]}), which State machine changes does not list')
        return change_objectives

    def change_glossary(self, c, b, where):
        """Both ways, by definition: every term the real change adds, removes or redefines is listed with that kind,
        and every listed kind is what the real change did."""
        ablk, bblk = term_blocks(read(self.p('GLOSSARY.md')) or ''), term_blocks(read(b.p('GLOSSARY.md')) or '')
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

    def change_vision(self, c, b, where):
        """Both ways: every listed line really changed, and every sentence the real change adds to or removes from the
        vision is listed. The vision's Decisions section is the round log (m5 writes and checks it) and is left out."""
        av, bv = read(self.p('docs/vision.md')) or '', read(b.p('docs/vision.md')) or ''
        listed = re.findall(r'^- [^\n]*?, (added|removed): "(.+)"\s*$', section(c, 'Vision changes') or '', re.M)
        for kind, q in listed:
            now, was = flat(q) in flat(av), flat(q) in flat(bv)
            if kind == 'added' and (not now or was):
                self.refuse('change', f'{where}: vision line "{q[:50]}..." is not added by the real change')
            if kind == 'removed' and (now or not was):
                self.refuse('change', f'{where}: vision line "{q[:50]}..." is not removed by the real change')
        au, bu = vision_units(av), vision_units(bv)
        for kind, units in (('added', au - bu), ('removed', bu - au)):
            for u in sorted(units):
                if not any(u in flat(q) for k, q in listed if k == kind):
                    self.refuse('change', f'{where}: the real change {"adds" if kind == "added" else "removes"} vision line "{u[:60]}", which Vision changes does not list')

    def change_adrs(self, c, b, where):
        badrs, aadrs = b.adrs(), self.adrs()
        new_adrs = re.findall(r'^- New: \[ADR (\d{4})\]', section(c, 'Decisions') or '', re.M)
        if not new_adrs:
            self.refuse('adr', f'{where}: no new decision record (every pack holds one; an idea is not one)')
        for n in new_adrs:
            if n not in aadrs or n in badrs:
                self.refuse('change', f'{where}: ADR {n} is not added by the real change')
        for n in sorted(set(aadrs) - set(badrs) - set(new_adrs)):
            self.refuse('change', f'{where}: the real change adds ADR {n}, which Decisions does not list')

    def change_changelog(self, c, b, where):
        listed = [(k, v.strip()) for k, v in re.findall(r'^- (Added|Changed|Removed|Fixed|Deprecated|Security): (.+)$', section(c, 'Changelog') or '', re.M)]
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
        was = unreleased(b.root)
        real = [x for x in unreleased(self.root) if x not in was]
        if sorted(real) != sorted(listed):
            self.refuse('change', f'{where}: changelog lines {sorted(listed)} differ from the real Unreleased lines {sorted(real)}')


def main(argv):
    ap = argparse.ArgumentParser(prog='jg-muster-gate.sh check', description='Check a project pack for its depth.')
    ap.add_argument('project')
    ap.add_argument('--depth', required=True)
    ap.add_argument('--change')
    ap.add_argument('--before')
    a = ap.parse_args(argv)
    if a.change is not None and not SLUG.match(a.change):
        ap.error(f'--change {a.change!r} is not a change pack slug (lowercase letters, digits and dashes)')
    for label, d in (('project', a.project), ('--before', a.before)):
        if d is not None and not os.path.isdir(d):
            ap.error(f'{label} {d!r} is not a directory')
    pack = Pack(a.project)
    refusals = pack.gate(a.depth, a.change, a.before)
    if not refusals:
        for warning in pack.warnings:
            print(warning, file=sys.stderr)
    print('\n'.join(refusals) if refusals else 'PASS')
    return 1 if refusals else 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, UnicodeDecodeError) as e:
        print(f'jg-muster-gate: cannot read the pack: {e}', file=sys.stderr)
        sys.exit(2)

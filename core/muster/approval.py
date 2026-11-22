#!/usr/bin/env python3
"""approval.py - the captain's approval of a muster pack, bound to the exact revision he saw (order m2b).

Run through bin/jg-muster-approval.sh. Standard library only. The machine formats are
.agents/skills/muster/formats.md sections 3 to 5 (frozen copy: example-pack/formats.md of plan jg-6si).

  manifest <ticket> <project dir> --depth <d> [--change <slug> --before <dir>]
      runs the pack gate on the project; on any refusal prints it and exits 1 with nothing written. On PASS it saves
      a complete byte-for-byte copy of the pack (pack-<sha12>/) and, for a feature, of the documents before it
      (base-<sha12>/), runs the ordinary gate again on those copies, writes manifest-<sha12>.tsv with its `check`
      line and prints the sha12.
  ask <ticket> <project name> <sha12>        hold "Approve the agreed documents for <name>, version <n>?"
  exception-ask <ticket> <project name>      hold "Start planning <name> without agreed documents, request <n>?"
      both refuse words the card rule refuses (jg_ask_card_junk), refuse when JG_TASK_ID is set, and record
      `ask kind manifest gate words at` in data/<ticket>/muster/approvals.tsv with the gate id the backlog returned.
      `ask` also refuses a manifest with no passing check line or a saved copy that no longer passes.
  verify <ticket> <project dir>              depth, change and baseline come from the approved manifest
  exception <ticket>                         the planning exception, for that ticket only
  verify-plan <ticket> <plan.json>           check requirements, the approved manifest and the slice order

Exit 0 approved, 1 refused (one line saying why), 2 usage. The only accepted answer is exactly `yes`, the hold card's
affirmative, with the signed approved-by-captain line that jg-captain-hold.sh answer alone writes. This file never
writes that line and holds no key.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TREE = os.environ.get('JG_ROOT_OVERRIDE') or os.path.dirname(os.path.dirname(HERE))
HOME = os.environ.get('JG_HOME') or TREE
STATE = os.environ.get('JG_STATE_OVERRIDE') or os.path.join(HOME, 'state')
DATA = os.environ.get('JG_DATA_OVERRIDE') or os.path.join(HOME, 'data')
GATE = os.environ.get('JG_MUSTER_GATE') or os.path.join(TREE, 'bin', 'jg-muster-gate.sh')
PACK_FILES = ('GLOSSARY.md', 'CHANGELOG.md', '.done-done.yaml')
PACK_DIRS = ('docs', 'journeys')
DEPTHS = ('complete', 'full', 'light')
CONTENT = ('check', 'file', 'journey', 'batch', 'charter', 'milestone', 'adr')
REQUIREMENT_SECTIONS = ('Functional requirements', 'Non-functional requirements')


class Refused(Exception):
    """One line saying why the action is refused."""


def sh(*argv):
    return subprocess.run(list(argv), capture_output=True, text=True)


def backlog(*argv):
    r = sh(os.path.join(TREE, 'bin', 'jg-backlog.sh'), *argv)
    if r.returncode != 0:
        raise Refused('the backlog could not answer: ' + ((r.stderr or r.stdout).strip().splitlines() or ['no output'])[-1])
    return r.stdout


def gates_of(ticket):
    return json.loads(backlog('questions', '--ticket', ticket, '--all', '--json') or '[]')


def muster_dir(ticket, create=False):
    d = os.path.join(DATA, ticket, 'muster')
    if create:
        os.makedirs(d, exist_ok=True)
    return d


def sha256_file(path):
    with open(path, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()


# ---- the pack's files and the markdown pieces the scope lines read -------------------------------------------------

def pack_files(project):
    """Every pack file of a project, sorted; rendered views (*.html) are not pack files."""
    out = [f for f in PACK_FILES if os.path.exists(os.path.join(project, f))]
    for d in PACK_DIRS:
        for dp, _, fs in os.walk(os.path.join(project, d)):
            out += [os.path.relpath(os.path.join(dp, f), project) for f in fs if not f.endswith('.html')]
    return sorted(out)


def normalized(path, text):
    """In a spec, the frontmatter lines `status:` and `updated:` and the `## Revisions` section are left out, so a
    status move keeps the approval; every other edit changes the text."""
    if path.startswith('docs/specs/') and path.endswith('.md'):
        text = re.sub(r'^(status|updated):.*\n', '', text, flags=re.M)
        text = re.sub(r'^## Revisions\n.*?(?=^## |\Z)', '', text, flags=re.M | re.S)
    return text


def section(text, title, level=2):
    m = re.search(r'^' + '#' * level + r' ' + re.escape(title) + r'[^\n]*\n(.*?)(?=^#{1,%d} |\Z)' % level, text, re.M | re.S)
    return m.group(1) if m else None


def table_rows(block):
    """Rows of one markdown table as lists of stripped cells, the header and the rule line dropped."""
    rows = [[c.strip() for c in ln.strip().strip('|').split('|')] for ln in block if ln.startswith('|')]
    return [r for r in rows[1:] if not set(''.join(r)) <= set('-: ')]


def tables(text):
    out, cur = [], []
    for ln in (text or '').splitlines() + ['']:
        if ln.startswith('|'):
            cur.append(ln)
        elif cur:
            out.append(table_rows(cur))
            cur = []
    return out


def ids(cell):
    return [x.strip().strip('`') for x in re.split(r'[,;]', cell or '') if x.strip() and x.strip() not in ('-', 'none')]


def scope_lines(texts, change):
    """journey, batch, charter and milestone lines: the feature's own (its change pack: Objectives and Charter) when
    a change is named, else the project's (every spec's Objectives table and docs/charter.md). One kind per journey."""
    kinds = {}
    if change:
        pack = texts.get(f'docs/changes/{change}.md') or ''
        for j, k in re.findall(r'^- ([\w-]+) \((new|preserve)\)', section(pack, 'Objectives') or '', re.M):
            kinds.setdefault(j, set()).add(k)
        charter = section(pack, 'Charter') or ''
    else:
        for f, t in texts.items():
            if f.startswith('docs/specs/'):
                for r in table_rows((section(t, 'Objectives') or '').splitlines()):
                    if len(r) >= 2 and r[1] in ('new', 'preserve'):
                        kinds.setdefault(r[0].strip('`'), set()).add(r[1])
        charter = texts.get('docs/charter.md') or ''
    lines = []
    for j, ks in kinds.items():
        if len(ks) != 1:
            raise Refused(f'manifest: journey {j} has two kinds ({", ".join(sorted(ks))}); one kind per journey')
        lines.append(f'journey {j} {next(iter(ks))}')
    ts = tables(charter)
    milestones = next((t for t in ts if t and len(t[0]) == 4), [])
    batches = next((t for t in ts if t and len(t[0]) == 3), [])
    tickets = next((t for t in ts if t and len(t[0]) == 6), [])
    lines += [f'batch {r[0]} {"-" if r[1].startswith("-") else ",".join(ids(r[1]))}' for r in batches]
    lines += [f'charter {r[0]} {r[2]} {",".join(ids(r[3])) or "-"}' for r in tickets]
    lines += [f'milestone {r[0].split()[0]} {",".join(ids(r[2]))}' for r in milestones]
    return lines


def gate_sha():
    try:
        return sha256_file(GATE)[:12]
    except OSError:
        raise Refused(f'the pack gate is missing: {GATE}')


def content_lines(project, depth, change):
    """The normalized lines that say what was agreed. A spec status move leaves them equal; any other edit changes one."""
    lines = [f'check {depth} {change or "-"} pass {gate_sha()}']
    texts = {}
    for f in pack_files(project):
        with open(os.path.join(project, f), encoding='utf-8') as fh:
            t = normalized(f, fh.read())
        texts[f] = t
        lines.append(f'file {f} {hashlib.sha256(t.encode()).hexdigest()}')
        m = re.match(r'docs/adr/(\d{4})-', f)
        if m:
            st = re.search(r'^status: (.+)$', t, re.M)
            lines.append(f'adr {m.group(1)} {st.group(1).split()[0] if st else "-"}')
    return sorted(set(lines + scope_lines(texts, change)))


# ---- the pack gate ---------------------------------------------------------------------------------------------------

def run_gate(project, depth, change, before):
    """(passed, output) of the pack gate, called as `<gate> check <project> --depth <d> [--change <slug> --before <dir>]`."""
    if not os.path.isfile(GATE):
        raise Refused(f'the pack gate is missing: {GATE}')
    argv = [GATE, 'check', project, '--depth', depth]
    if change:
        argv += ['--change', change, '--before', before or '']
    r = sh(*argv)
    return r.returncode == 0, (r.stdout + r.stderr).strip()


def print_gate_warnings(output):
    for line in output.splitlines():
        if line.startswith('warning: '):
            print(line, file=sys.stderr)


def first_line(text):
    return (text.splitlines() or ['no output'])[0]


# ---- the manifest and its two saved copies -----------------------------------------------------------------------------

def copy_files(src, dst):
    """Complete byte-for-byte copy of src's pack files into dst; returns {path: sha256}."""
    out = {}
    for f in pack_files(src):
        os.makedirs(os.path.dirname(os.path.join(dst, f)), exist_ok=True)
        shutil.copyfile(os.path.join(src, f), os.path.join(dst, f))
        out[f] = sha256_file(os.path.join(src, f))
    return out


def build_manifest(ticket, project, depth, change, before):
    """Gate the project, save both copies, gate the copies, write the manifest. Returns its sha12."""
    ok, checked = run_gate(project, depth, change, before)
    if not ok:
        raise Refused(checked + '\nrefused: the pack check did not pass; no manifest, no ask')
    lines = content_lines(project, depth, change)
    d = muster_dir(ticket, create=True)
    tmp = os.path.join(d, 'snapshot.tmp')
    shutil.rmtree(tmp, ignore_errors=True)
    try:
        lines += [f'raw {f} {h}' for f, h in copy_files(project, os.path.join(tmp, 'pack')).items()]
        if change:
            lines += [f'base {f} {h}' for f, h in copy_files(before, os.path.join(tmp, 'base')).items()]
        ok, out = run_gate(os.path.join(tmp, 'pack'), depth, change, os.path.join(tmp, 'base') if change else None)
        if not ok:
            raise Refused(out + '\nrefused: the saved copy does not pass the pack check; no manifest, no ask')
        body = '\n'.join(sorted(set(lines))) + '\n'
        sha = hashlib.sha256(body.encode()).hexdigest()[:12]
        for part in ('pack', 'base'):
            if os.path.isdir(os.path.join(tmp, part)):
                dst = os.path.join(d, f'{part}-{sha}')
                shutil.rmtree(dst, ignore_errors=True)
                os.rename(os.path.join(tmp, part), dst)
        with open(os.path.join(d, f'manifest-{sha}.tsv'), 'w') as f:
            f.write(body)
        print_gate_warnings(checked)
        return sha
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def read_manifest(ticket, sha):
    p = os.path.join(muster_dir(ticket), f'manifest-{sha}.tsv')
    if not os.path.isfile(p):
        raise Refused(f'no manifest for version {sha}; run manifest first')
    with open(p) as f:
        return f.read().splitlines()


def manifest_scope(mf, sha):
    chk = next((ln.split() for ln in mf if ln.startswith('check ')), None)
    if not chk or len(chk) < 5 or chk[3] != 'pass':
        raise Refused(f'the manifest of version {sha} has no passing check line; run manifest first')
    return chk[1], (None if chk[2] == '-' else chk[2])


def saved_copy_check(ticket, sha):
    """Both saved copies are byte for byte what the manifest lists, and the ordinary gate passes on them at the
    manifest's depth and change. Returns the manifest lines and gate output; raises Refused otherwise."""
    mf = read_manifest(ticket, sha)
    depth, change = manifest_scope(mf, sha)
    d = muster_dir(ticket)
    for part, key in (('pack', 'raw'), ('base', 'base')):
        root = os.path.join(d, f'{part}-{sha}')
        listed = {p[1]: p[2] for p in (ln.split(' ') for ln in mf) if p[0] == key}
        if not listed and not os.path.isdir(root):
            continue
        have = set(pack_files(root)) if os.path.isdir(root) else set()
        for f in sorted(set(listed) | have):
            if f not in listed:
                raise Refused(f'the saved copy {part}-{sha} holds {f}, which the manifest does not list')
            if f not in have or sha256_file(os.path.join(root, f)) != listed[f]:
                raise Refused(f'the approved snapshot of {f} was changed after the ask')
    base = os.path.join(d, f'base-{sha}') if change else None
    ok, out = run_gate(os.path.join(d, f'pack-{sha}'), depth, change, base)
    if not ok:
        raise Refused('the pack check does not pass on the saved copy: ' + first_line(out))
    return mf, out


# ---- the two owner questions and the approvals record -------------------------------------------------------------------

def approvals(ticket):
    p = os.path.join(muster_dir(ticket), 'approvals.tsv')
    if not os.path.isfile(p):
        return []
    with open(p) as f:
        return [dict(zip(['ask', 'kind', 'manifest', 'gate', 'words', 'at'], ln.rstrip('\n').split('\t'))) for ln in f if ln.strip()]


def newest(ticket, kind):
    rows = [r for r in approvals(ticket) if r['kind'] == kind]
    return max(rows, key=lambda r: int(r['ask'])) if rows else None


def card_junk(words):
    lib = os.path.join(TREE, 'bin', 'jg-ask-gate-lib.sh')
    return sh('bash', '-c', '. "$1"; jg_ask_card_junk "$2"', '_', lib, words).stdout.strip()


def no_worker(what):
    if os.environ.get('JG_TASK_ID'):
        raise Refused(f'a worker cannot {what}')


def ask(ticket, kind, name, sha):
    no_worker('ask the captain for approval or an exception')
    checked = ''
    if kind == 'approve':
        _, checked = saved_copy_check(ticket, sha)
    n = 1 + sum(1 for r in approvals(ticket) if r['kind'] == kind)
    words = (f'Approve the agreed documents for {name}, version {n}?' if kind == 'approve'
             else f'Start planning {name} without agreed documents, request {n}?')
    junk = card_junk(words)
    if junk:
        raise Refused(f'the card rule refuses these words ("{junk}")')
    r = sh(os.path.join(TREE, 'bin', 'jg-captain-hold.sh'), 'hold', ticket, '--reason', words)
    if r.returncode != 0:
        raise Refused('the hold failed: ' + ((r.stderr or r.stdout).strip().splitlines() or ['no output'])[-1])
    found = [g for g in gates_of(ticket) if g.get('question') == words]
    if len(found) != 1:
        raise Refused(f'{len(found)} gates carry these words; expected exactly one')
    with open(os.path.join(muster_dir(ticket, create=True), 'approvals.tsv'), 'a') as f:
        f.write('\t'.join([str(n), kind, sha or '-', found[0]['id'], words, str(int(time.time()))]) + '\n')
    print_gate_warnings(checked)
    print(f'asked: {words} (gate {found[0]["id"]})')


def signed_line_ok(ticket, ref):
    """The ticket holds the approved-by-captain line for this reference: the signature is recomputed by the
    answer owner's own library (bin/jg-captain-ask-lib.sh), never here."""
    key = os.path.join(STATE, 'captain-approval.key')
    if not os.path.isfile(key):
        return False
    lib = os.path.join(TREE, 'bin', 'jg-captain-ask-lib.sh')
    r = sh('bash', '-c', '. "$1" && captain_ask_approval_sig "$2" "$3" "$4"', '_', lib, ticket, ref, key)
    want = r.stdout.strip()
    shown = backlog('show', ticket, '--full').replace('\\n', '\n')
    return r.returncode == 0 and bool(want) and f'approved-by-captain: {ref} sig={want}' in shown


def answered_yes(ticket, row):
    """None when the row's gate was closed by the owner with exactly `yes` and the signed line is on the ticket."""
    g = next((g for g in gates_of(ticket) if g['id'] == row['gate']), None)
    if not g:
        raise Refused(f'gate {row["gate"]} is not on {ticket}')
    if g.get('state') != 'closed':
        raise Refused(f'the newest question ({row["words"]}) is still open')
    if g.get('resolution') not in ('answered', 'released'):
        raise Refused(f'the question was closed as {g.get("resolution")}, not by the owner\'s answer')
    words = g.get('words') or ''
    answer = next((ln[len('Answer: '):] for ln in words.split('\n') if ln.startswith('Answer: ')), '')
    if answer != 'yes':
        raise Refused(f'the answer was "{answer}", which is not yes (recorded, not an approval)')
    if not signed_line_ok(ticket, 'answer:' + hashlib.sha256(words.encode()).hexdigest()):
        raise Refused('no signed approved-by-captain line for those words')


def approved_manifest(ticket):
    """Return the approval row, manifest lines and gate output after checking the signed snapshot."""
    row = newest(ticket, 'approve')
    if not row:
        raise Refused(f'no approval was asked on {ticket}')
    mf, checked = saved_copy_check(ticket, row['manifest'])
    answered_yes(ticket, row)
    return row, mf, checked


def verify(ticket, project):
    row, mf, _ = approved_manifest(ticket)
    sha = row['manifest']
    depth, change = manifest_scope(mf, sha)
    base = os.path.join(muster_dir(ticket), f'base-{sha}') if change else None
    ok, out = run_gate(project, depth, change, base)
    if not ok:
        raise Refused('the pack check does not pass on the current documents: ' + first_line(out))
    if content_lines(project, depth, change) != sorted(ln for ln in mf if ln.split(' ')[0] in CONTENT):
        raise Refused(f'the documents changed since version {row["ask"]} was asked; a fresh approval is needed')
    print_gate_warnings(out)
    print(f'approved: version {row["ask"]} ({sha}) answered yes on {ticket}; the pack check passed at {depth} on the '
          f'saved copy{" and its saved baseline" if change else ""} and on the current documents')


def use_exception(ticket):
    no_worker('use the planning exception')
    row = newest(ticket, 'exception')
    if not row:
        raise Refused(f'no exception was asked on {ticket}')
    answered_yes(ticket, row)
    print(f'let through: {ticket} only, on the captain\'s yes')


# ---- a plan against the approved manifest -----------------------------------------------------------------------------

def block_lines(m):
    """The muster block of a plan as the manifest's scope lines, by kind."""
    return {
        'journey': sorted(f'{j["id"]} {j["kind"]}' for j in m.get('journeys', [])),
        'batch': sorted(f'{b["id"]} {",".join(b.get("after") or []) or "-"}' for b in m.get('batches', [])),
        'charter': sorted(f'{c["ticket"]} {c["batch"]} {",".join(c.get("depends") or []) or "-"}' for c in m.get('charter', [])),
        'milestone': sorted(f'{x["id"]} {",".join(x["journeys"])}' for x in m.get('milestones', [])),
    }


def check_order(m, plan):
    """formats.md section 5: shape and order rules, store-free. A slice that claims T must depend, directly or
    through other slices, on every slice that claims a ticket T depends on or of a batch T's batch starts after."""
    slices = {s['id']: s for s in plan.get('slices', [])}
    deps = {i: set(s.get('depends_on') or []) for i, s in slices.items()}

    def reach(i):
        seen, todo = set(), list(deps.get(i, ()))
        while todo:
            d = todo.pop()
            if d not in seen:
                seen.add(d)
                todo += deps.get(d, ())
        return seen

    claims = {}
    for i, s in slices.items():
        for t in s.get('charter') or []:
            claims.setdefault(t, set()).add(i)
    claimed_j = {j for s in slices.values() for j in s.get('journeys') or []}
    journeys = {j['id']: j['kind'] for j in m['journeys']}
    charter = {c['ticket']: c for c in m['charter']}
    batches = {b['id']: set(b.get('after') or []) for b in m['batches']}
    for t in charter:
        if t not in claims:
            raise Refused(f'charter ticket {t} is claimed by no slice')
    for j, k in journeys.items():
        if k == 'new' and j not in claimed_j:
            raise Refused(f'new journey {j} is claimed by no slice')
    for x in m['milestones']:
        for j in x['journeys']:
            if j not in claimed_j:
                raise Refused(f'milestone {x["id"]} journey {j} is claimed by no slice')
    for b, after in batches.items():
        if b in after:
            raise Refused(f'batch {b} waits on itself')
    for i, s in slices.items():
        for j in s.get('journeys') or []:
            if j not in journeys:
                raise Refused(f'slice {i} names journey {j}, which the approved manifest does not hold')
        for t in s.get('charter') or []:
            if t not in charter:
                raise Refused(f'slice {i} names charter ticket {t}, which the approved manifest does not hold')
            need = set(charter[t]['depends'])
            for b in batches.get(charter[t]['batch'], ()):
                need |= {u for u, c in charter.items() if c['batch'] == b}
            for u in sorted(need):
                for other in sorted(claims.get(u, ())):
                    if other == i:
                        raise Refused(f'slice {i} claims charter {t} together with {u}, which {t} must follow; put {u} on a slice {i} depends on')
                    if other not in reach(i):
                        raise Refused(f'slice {i} (charter {t}) can start before slice {other} (charter {u}), which it must follow')
    return len(slices)


def check_requirements(ticket, sha, mf):
    """Check the coverage in the approved spec, whose bytes are checked by approved_manifest."""
    _, change = manifest_scope(mf, sha)
    pack = os.path.join(muster_dir(ticket), f'pack-{sha}')
    specs = {}
    scoped = {}
    for path in pack_files(pack):
        if not (path.startswith('docs/specs/') and path.endswith('.md')):
            continue
        with open(os.path.join(pack, path), encoding='utf-8') as file:
            specs[path] = text = file.read()
        frontmatter = text.split('\n---\n', 1)[0] if text.startswith('---\n') else ''
        owns = re.search(r'^muster:[ \t]*' + re.escape(ticket) + r'[ \t]*$', frontmatter, re.M)
        if owns or (change and path == f'docs/specs/{change}.md'):
            scoped[path] = text
    if change or scoped:
        specs = scoped

    coverage = {name: {} for name in REQUIREMENT_SECTIONS}
    has_coverage = False
    for name, results in coverage.items():
        for spec in specs.values():
            block = section(spec, name)
            has_coverage |= block is not None
            for rows in tables(block):
                for cells in rows:
                    category = cells[0].casefold()
                    outcome = cells[1].casefold() if len(cells) > 1 else ''
                    closed = outcome in ('answered', 'accepted recommendation', 'out of scope')
                    results[category] = results.get(category, True) and closed
    if not has_coverage:
        return False  # Legacy specs predate the requirements tables.

    taxonomy_path = os.path.join(TREE, '.agents', 'skills', 'muster', 'requirements.md')
    try:
        with open(taxonomy_path, encoding='utf-8') as file:
            taxonomy = file.read()
    except OSError as err:
        raise Refused(f'cannot read the Muster requirements map: {err}') from err
    open_categories = []
    for name, results in coverage.items():
        groups = tables(section(taxonomy, name))
        if not groups or not groups[0]:
            raise Refused(f'the Muster requirements map has no categories for {name.lower()}')
        labels = {cells[0].casefold() for cells in groups[0]}
        unknown = sorted(results.keys() - labels)
        if unknown:
            raise Refused(f'unknown categories in {name.lower()}: ' + ', '.join(unknown))
        for category, *_ in groups[0]:
            if not results.get(category.casefold()):
                open_categories.append(category)
    if open_categories:
        raise Refused('open requirements categories: ' + ', '.join(open_categories))
    return True


def slice_directions(plan, muster, required):
    """Validate the decisions table and resolve one direction per decision for the slices that use it."""
    rows = muster.get('decisions_and_assumptions', None if required else [])
    if not isinstance(rows, list):
        raise Refused('decisions_and_assumptions must be a table of decision rows')
    slices = {s['id'] for s in plan.get('slices', [])}
    directions = {}
    seen = set()

    def line(value):
        return isinstance(value, str) and bool(value.strip()) and value.splitlines() == [value]

    for decision in rows:
        key = decision.get('id') if isinstance(decision, dict) else None
        if not isinstance(key, str) or not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9-]*', key):
            raise Refused('each decision or assumption needs an id with letters, digits or dashes')
        if key in seen:
            raise Refused(f'decision {key} is listed twice')
        seen.add(key)
        recommendation = decision.get('recommendation')
        if not line(recommendation):
            raise Refused(f'decision {key} needs a one-line recommendation')
        status, answer, override = (decision.get(k) for k in ('status', 'answer', 'override'))
        if status not in ('answered', 'accepted recommendation', 'overridden'):
            raise Refused(f'decision {key} needs status answered, accepted recommendation or overridden')
        if override is not None and not line(override):
            raise Refused(f'decision {key} needs a one-line override or null')
        if status == 'answered' and not line(answer):
            raise Refused(f'decision {key} needs a one-line answer')
        if status == 'overridden' and override is None:
            raise Refused(f'decision {key} is overridden and needs an override')
        targets = decision.get('slices')
        if not isinstance(targets, list) or not targets:
            raise Refused(f'decision {key} must name at least one slice')
        direction = override or (answer if status == 'answered' else recommendation)
        for target in targets:
            if not isinstance(target, str) or target not in slices:
                raise Refused(f'decision {key} names unknown slice {target}')
            selected = directions.setdefault(target, {})
            if key in selected:
                raise Refused(f'decision {key} names slice {target} twice')
            selected[key] = direction
    return directions


def verify_plan(ticket, plan_path, emit_directions=False):
    row, mf, checked = approved_manifest(ticket)
    try:
        with open(plan_path, 'rb') as f:
            source = f.read()
        plan = json.loads(source)
    except (OSError, ValueError) as e:
        raise Refused(f'the plan cannot be read: {e}')
    m = plan.get('muster') if isinstance(plan, dict) else None
    if not isinstance(m, dict) or not m:
        raise Refused('the plan has no muster block')
    if m.get('ticket') != ticket:
        raise Refused(f'the plan\'s muster block names ticket {m.get("ticket")}, not {ticket}')
    if m.get('manifest_sha') != row['manifest']:
        raise Refused(f'the plan was made from version {m.get("manifest_sha")}, not the approved {row["manifest"]}')
    depth, _ = manifest_scope(mf, row['manifest'])
    if m.get('depth') != depth:
        raise Refused(f'the plan\'s depth does not match the approved {depth} manifest')
    try:
        got_by_kind = block_lines(m)
    except (KeyError, TypeError) as e:
        raise Refused(f'the plan\'s muster block is malformed: missing {e}')
    for kind, got in got_by_kind.items():
        have = sorted(ln[len(kind) + 1:] for ln in mf if ln.startswith(kind + ' '))
        if got != have:
            raise Refused(f'the plan\'s {kind} lines differ from the approved manifest: missing '
                          f'{sorted(set(have) - set(got)) or "none"}, extra {sorted(set(got) - set(have)) or "none"}')
    has_coverage = check_requirements(ticket, row['manifest'], mf)
    n = check_order(m, plan)
    directions = slice_directions(plan, m, has_coverage)
    print_gate_warnings(checked)
    if emit_directions:
        print(json.dumps({'plan_sha256': hashlib.sha256(source).hexdigest(), 'directions': directions}))
    else:
        print(f'plan ok: {n} slices keep the approved version {row["manifest"]} and its charter order')


# ---- the command line --------------------------------------------------------------------------------------------------

def option(argv, name):
    return argv[argv.index(name) + 1] if name in argv and argv.index(name) + 1 < len(argv) else None


def manifest_cmd(argv):
    ticket, project = argv[1], argv[2]
    depth, change, before = option(argv, '--depth'), option(argv, '--change'), option(argv, '--before')
    if depth not in DEPTHS:
        raise Refused(f'--depth must be one of {", ".join(DEPTHS)}')
    if depth == 'complete' and (change or before):
        raise Refused('depth complete checks a project; --change and --before belong to full and light')
    if depth != 'complete' and not (change and before):
        raise Refused(f'depth {depth} checks a feature: it needs --change <slug> and --before <the documents before it>')
    print(build_manifest(ticket, project, depth, change, before))


def main(argv):
    n, cmd = len(argv), (argv or [''])[0]
    try:
        if cmd == 'manifest' and n >= 3:
            manifest_cmd(argv)
        elif cmd == 'ask' and n == 4:
            ask(argv[1], 'approve', argv[2], argv[3])
        elif cmd == 'exception-ask' and n == 3:
            ask(argv[1], 'exception', argv[2], None)
        elif cmd == 'verify' and n == 3:
            verify(argv[1], argv[2])
        elif cmd == 'exception' and n == 2:
            use_exception(argv[1])
        elif cmd == 'verify-plan' and (n == 3 or (n == 4 and argv[3] == '--slice-directions')):
            verify_plan(argv[1], argv[2], emit_directions=n == 4)
        else:
            print(__doc__)
            return 2
    except Refused as why:
        print('refused: ' + str(why).removeprefix('refused: '))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

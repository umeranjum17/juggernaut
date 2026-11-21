#!/usr/bin/env bash
# jg-muster-survey.sh - /muster survey: read an existing project first, write the drafts, ask only about gaps.
#
# Usage: jg-muster-survey.sh <project> [--ticket <id>]
#        jg-muster-survey.sh --help
#
# <project> is a project name under the projects folder (JG_PROJECTS_OVERRIDE, else $JG_HOME/projects) or the path of a project
# folder. The survey reads the project and never writes to it. It writes five drafts to data/<ticket>/muster/survey/ with --ticket,
# else data/muster-survey/<project>/ (JG_DATA_OVERRIDE, else $JG_HOME/data); every one is marked draft for the drafter:
#   GLOSSARY.draft.md           terms from type names (class, interface, enum) and doc headings; a doc's first sentence under a
#                               matching heading is the proposed definition; terms in GLOSSARY.md already are skipped
#   core-objects.draft.md       objects with a state or status field, their state values (enum members, string unions), behaviour
#                               names and fields, in the shape of docs/domain/model.md
#   ways-of-working.draft.md    detected lint, test, CI and folder setup; an existing CONSTRAINTS.md read into the sections of
#                               docs/ways-of-working.md (Floor, Measured, not yet enforced, Exceptions, the rest kept by heading)
#   preserve-journeys.draft.md  candidate preserve journeys from the names of existing tests (it/test, def test_, `# T<n>` lines)
#   gaps.md                     the questions the first rounds ask, five a round, most important first, as `- Q: ... | A: | owner: ...`
# It reads TypeScript and JavaScript source; any other source file is counted as unread and becomes a gap. The drafts hold no
# time or random value, so a second run writes the same files. Nothing here decides: the drafter confirms every line.
# Exit 0 written, 1 refused (nothing to read, or the output folder is inside the project), 2 usage, 4 project not found.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_HOME="${JG_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
PROJECTS="${JG_PROJECTS_OVERRIDE:-$JG_HOME/projects}"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
die() { echo "jg-muster-survey: $*" >&2; exit 2; }

project='' ticket=''
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --ticket) [ $# -ge 2 ] || die "--ticket needs an id"; ticket=$2; shift 2 ;;
    -*) die "unknown option $1 (usage: jg-muster-survey.sh <project> [--ticket <id>])" ;;
    *) [ -z "$project" ] || die "one project only (usage: jg-muster-survey.sh <project> [--ticket <id>])"; project=$1; shift ;;
  esac
done
[ -n "$project" ] || die "usage: jg-muster-survey.sh <project> [--ticket <id>]"
case $ticket in */*|.*) die "ticket '$ticket' is not a plain id" ;; esac

case $project in
  */*) root=$project ;;
  *) root=$PROJECTS/$project ;;
esac
[ -d "$root" ] || { echo "jg-muster-survey: no project folder at $root" >&2; exit 4; }
root=$(cd "$root" && pwd -P)
name=$(basename "$root")
if [ -n "$ticket" ]; then out=$DATA/$ticket/muster/survey; else out=$DATA/muster-survey/$name; fi
mkdir -p "$out" || die "cannot create $out"
out=$(cd "$out" && pwd -P)
case $out/ in
  "$root"/*) echo "jg-muster-survey: refused: the output folder $out is inside the project; a survey never writes to a project" >&2; exit 1 ;;
esac

exec python3 -I - "$root" "$name" "$out" <<'PY'
import json, os, re, sys

root, name, out = sys.argv[1:4]
SKIP = {'.git', 'node_modules', 'dist', 'build', 'coverage', '.next', 'vendor', '__pycache__', '.venv'}
READ = ('.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs')
CODE = READ + ('.py', '.go', '.rs', '.java', '.kt', '.rb', '.php', '.cs', '.swift', '.sh')
GENERIC = {'install', 'installation', 'usage', 'contributing', 'license', 'getting started', 'overview', 'introduction', 'testing',
           'development', 'setup', 'scripts', 'contents', 'table of contents', 'requirements', 'features', 'tests', 'changelog',
           'quick start', 'configuration', 'documentation'}
NOT_DOC = {'CONSTRAINTS.md', 'GLOSSARY.md', 'AGENTS.md', 'CLAUDE.md', 'CHANGELOG.md'}


def read(rel):
    try:
        return open(os.path.join(root, rel), encoding='utf-8', errors='replace').read()
    except OSError:
        return ''


files = []
for d, dirs, names in os.walk(root):
    dirs[:] = sorted(x for x in dirs if x not in SKIP)
    files += [os.path.relpath(os.path.join(d, n), root) for n in sorted(names)]
if not files:
    print(f'jg-muster-survey: refused: {root} holds no files to read', file=sys.stderr)
    sys.exit(1)


def is_test(rel):
    p = rel.split('/')
    return bool({'tests', 'test', '__tests__'} & set(p[:-1])) or bool(re.search(r'\.(test|spec)\.', p[-1])) or p[-1].startswith('test_')


def words(ident):
    return ' '.join(re.findall(r'[A-Z]+(?![a-z])|[A-Z]?[a-z]+|\d+', ident))


def key(term):
    k = re.sub(r'[^a-z0-9]+', ' ', term.lower()).strip()
    return k[:-1] if k.endswith('s') and not k.endswith('ss') else k


def slug(text, n=48):
    return re.sub(r'[^a-z0-9]+', '-', text.lower()).strip('-')[:n].strip('-')


def body_of(text, start):
    depth, i = 1, start
    while i < len(text) and depth:
        depth += {'{': 1, '}': -1}.get(text[i], 0)
        i += 1
    return text[start:i - 1]


def top_level(body):
    depth, keep = 0, []
    for c in body:
        if c == '{':
            depth += 1
            keep.append('{}' if depth == 1 else '')
            continue
        if c == '}':
            depth -= 1
            continue
        if depth == 0:
            keep.append(c)
    return ''.join(keep)


def literals(text):
    return re.findall(r'[\'"]([^\'"]+)[\'"]', text)


# 1. Source: type names, state types, objects.
srcs = [f for f in files if f.endswith(READ) and not is_test(f) and '.config.' not in f]
state_types, decls = {}, []
for f in srcs:
    text = read(f)
    for m in re.finditer(r'^\s*(?:export\s+)?type\s+([A-Z]\w*)\s*=\s*((?:\s*\|?\s*[\'"][^\'"]+[\'"])+)\s*;?', text, re.M):
        state_types[m.group(1)] = literals(m.group(2))
    for m in re.finditer(r'^\s*(?:export\s+)?(?:default\s+)?(?:declare\s+)?(?:abstract\s+)?(class|interface|enum)\s+([A-Z]\w*)[^{;]*\{', text, re.M):
        body = body_of(text, m.end())
        if m.group(1) == 'enum':
            vals = []
            for item in top_level(body).split(','):
                mm = re.match(r'\s*(\w+)\s*(?:=\s*[\'"]([^\'"]+)[\'"])?', item)
                if mm:
                    vals.append(mm.group(2) or mm.group(1).lower())
            state_types[m.group(2)] = vals
        else:
            decls.append((m.group(1), m.group(2), f, top_level(body)))

objects, terms = [], {}
for kind, nm, f, top in decls:
    fields, state, methods = [], None, []
    for fm in re.finditer(r'^\s*(?:(?:public|private|protected|readonly|static)\s+)*(\w+)\??\s*:\s*([^;=\n]+)', top, re.M):
        fields.append(fm.group(1))
        if re.search(r'(?i)(^|[a-z])(status|state)$', fm.group(1)):
            t = fm.group(2).strip()
            vals = state_types.get(t) or (literals(t) if "'" in t or '"' in t else None)
            if vals:
                state = (fm.group(1), t, vals)
    for mm in re.finditer(r'^\s*(?:(?:public|static|async)\s+)*(\w+)\s*\([^)]*\)[^;{=\n]*[{;]', top, re.M):
        if mm.group(1) not in ('constructor', 'if', 'for', 'while', 'switch', 'return') and not top[:mm.start(1)].rstrip().endswith('private'):
            methods.append(mm.group(1))
    if state:
        objects.append({'name': nm, 'file': f, 'fields': fields, 'methods': methods, 'state': state})
    if not re.search(r'(Props|Options|Config|Params)$', nm):
        terms.setdefault(key(nm), {'term': words(nm), 'code': f, 'doc': None, 'def': None})

# 2. Docs: headings with their first sentence.
have = {key(m.group(1)) for m in re.finditer(r'^###\s+(.+?)\s*$', read('GLOSSARY.md'), re.M)}
doc_terms = []
for f in files:
    if not f.endswith('.md') or os.path.basename(f) in NOT_DOC:
        continue
    lines, fence = read(f).splitlines(), False
    for i, line in enumerate(lines):
        fence ^= line.startswith('```')
        m = None if fence else re.match(r'^#{1,4}\s+(.+?)\s*$', line)
        if not m or m.group(1).lower() in GENERIC or key(m.group(1)) == key(name) or len(m.group(1).split()) > 4:
            continue
        para = []
        for nxt in lines[i + 1:]:
            if not nxt.strip() and para:
                break
            if nxt.startswith('#'):
                break
            if nxt.strip() and not nxt.startswith(('|', '`', '-', '*')):
                para.append(nxt.strip())
        sentence = re.split(r'(?<=\.)\s', ' '.join(para))[0][:200] if para else None
        doc_terms.append((m.group(1), f, sentence))
for term, f, sentence in doc_terms:
    t = terms.get(key(term))
    if t:
        t['doc'], t['def'] = f, t['def'] or sentence
    else:
        terms[key(term)] = {'term': term, 'code': None, 'doc': f, 'def': sentence}
states_of = {key(o['name']): o for o in objects}
glossary = {k: t for k, t in terms.items() if k not in have}

# 3. Standards.
def has(*patterns):
    return [f for f in files if any(re.fullmatch(p, f) for p in patterns)]


pkg = {}
try:
    pkg = json.loads(read('package.json'))
except ValueError:
    pass
scripts, deps = pkg.get('scripts', {}), {**pkg.get('dependencies', {}), **pkg.get('devDependencies', {})}
pyproject = read('pyproject.toml')
rules = []  # (what, config, command)
for tool, pats, dep in (('eslint', [r'eslint\.config\.\w+', r'\.eslintrc(\.\w+)?'], 'eslint'), ('biome', [r'biome\.jsonc?'], '@biomejs/biome'),
                        ('ruff', [r'ruff\.toml', r'\.ruff\.toml'], None), ('shellcheck', [r'\.shellcheckrc'], None), ('prettier', [r'\.prettierrc(\.\w+)?'], 'prettier')):
    found = has(*pats) or (['pyproject.toml'] if tool == 'ruff' and '[tool.ruff' in pyproject else [])
    if found:
        rules.append((f'Lint with {tool}', found[0], scripts.get('lint', '')))
if has('tsconfig\\.json'):
    rules.append(('Type-check with tsc' + (' (strict)' if re.search(r'"strict"\s*:\s*true', read('tsconfig.json')) else ''), 'tsconfig.json', scripts.get('typecheck', '')))
runners = [(n, c[0]) for n, c in (('vitest', has(r'vitest\.config\.\w+')), ('jest', has(r'jest\.config\.\w+')),
           ('pytest', has('pytest\\.ini') or (['pyproject.toml'] if '[tool.pytest' in pyproject else [])),
           ('bash tests', has(r'tests/[^/]+\.test\.sh'))) if c]
ci = has(r'\.github/workflows/[^/]+\.ya?ml')
NAMES = {'.ts': 'TypeScript', '.tsx': 'TypeScript', '.js': 'JavaScript', '.jsx': 'JavaScript', '.mjs': 'JavaScript', '.cjs': 'JavaScript',
         '.py': 'Python', '.go': 'Go', '.rs': 'Rust', '.java': 'Java', '.kt': 'Kotlin', '.rb': 'Ruby', '.php': 'PHP', '.cs': 'C#',
         '.swift': 'Swift', '.sh': 'Shell'}
langs = {}
for f in files:
    if f.endswith(CODE) and not is_test(f) and '.config.' not in f:
        langs[NAMES[os.path.splitext(f)[1]]] = langs.get(NAMES[os.path.splitext(f)[1]], 0) + 1
unread = [f for f in files if f.endswith(CODE) and not f.endswith(READ) and not is_test(f)]
unread_langs = sorted({NAMES[os.path.splitext(f)[1]] for f in unread})
tops = sorted({f.split('/')[0] for f in files if '/' in f and f.split('/')[0] not in {'.github'}})
srcdirs = sorted({'/'.join(f.split('/')[:2]) for f in srcs if f.startswith('src/') and f.count('/') > 1})

# 4. CONSTRAINTS.md into the sections of docs/ways-of-working.md.
sections, cur = [], None
for line in read('CONSTRAINTS.md').splitlines():
    if line.startswith('## '):
        cur = [line[3:].strip(), []]
        sections.append(cur)
    elif cur is not None:
        cur[1].append(line)
mapped = {}
for head, body in sections:
    low = head.lower()
    target = ('Floor (numbers)' if low.startswith(('floor', 'threshold')) else 'Measured, not yet enforced' if low.startswith('measured')
              else 'Exceptions (time-limited)' if low.startswith('exception') else f'From CONSTRAINTS.md: {head}')
    mapped.setdefault(target, []).append((head, '\n'.join(body).strip()))

# 5. Candidate preserve journeys from existing tests.
journeys, seen = [], set()
for f in (f for f in files if is_test(f)):
    text, suite = read(f), ''
    for line in text.splitlines():
        s = re.search(r'\bdescribe\(\s*([\'"`])(.+?)\1', line)
        t = re.search(r'\b(?:it|test)(?:\.\w+)?\(\s*([\'"`])(.+?)\1', line)
        p = re.match(r'\s*(?:async\s+)?def (test_\w+)', line)
        b = re.match(r'#\s*[TS]\d+[.:]?\s+(.+)$', line)
        suite = s.group(2) if s else suite
        label = (f'{suite}: {t.group(2)}' if suite else t.group(2)) if t else p.group(1).replace('_', ' ') if p else b.group(1) if b else None
        if label and slug(label) not in seen:
            seen.add(slug(label))
            journeys.append((slug(label), label, f))
alltests = ' '.join(read(f) for f in files if is_test(f))

# 6. Gaps, most important first: impact times uncertainty, five to a round.
gaps = []  # (score, question, owner)
for o in objects:
    field, typ, vals = o['state']
    gaps.append((9, f'What moves the {o["name"]} between its states ({", ".join(vals)}), and what stops a move?', 'no'))
for o in objects:
    untested = [v for v in o['state'][2] if not re.search(re.escape(v), alltests, re.I)]
    if untested:
        gaps.append((6, f'No test drives the {o["name"]} state(s) {", ".join(untested)}: are they reachable, and what must hold there?', 'no'))
for k, t in terms.items():
    if t['code'] is None:
        gaps.append((6, f'"{t["term"]}" is in the docs ({t["doc"]}) but in no type: is it a missing feature or an old word?', 'no'))
for k, t in glossary.items():
    if t['code'] and not t['doc'] and k not in states_of and not t['def']:
        gaps.append((4, f'What does "{t["term"]}" ({t["code"]}) mean to a user?', 'no'))
if journeys:
    gaps.append((8, f'Which of the {len(journeys)} existing test behaviours must never change?', 'yes'))
if not has(r'docs/vision\.md', r'VISION\.md'):
    gaps.append((8, 'Why does this product exist, and for whom?', 'yes'))
if not any(r.startswith('Lint') for r, _, _ in rules):
    gaps.append((7, 'No linter was found: which rules does this project hold itself to?', 'yes'))
if not runners and not scripts.get('test'):
    gaps.append((7, 'No test runner was found: how is a change proved today?', 'yes'))
if not has(r'docs/adr/.+\.md', r'docs/decisions/.+\.md'):
    gaps.append((5, f'No decision records exist: which choices ({", ".join(sorted(langs)) or "stack"}, storage, hosting) were deliberate and hard to undo?', 'yes'))
if unread:
    gaps.append((3, f'{len(unread)} source file(s) in languages the survey does not read ({", ".join(unread_langs)}): do they hold core objects?', 'no'))
gaps.sort(key=lambda g: -g[0])


def table(rows):
    return '\n'.join(rows)


def w(fname, text):
    with open(os.path.join(out, fname), 'w', encoding='utf-8') as fh:
        fh.write(text.rstrip('\n') + '\n')


DRAFT = 'Draft for the drafter: written by `jg muster survey` from the code and the docs; confirm, rewrite or remove every line.'
g = ['# Glossary: ' + name + ' (draft)', '', DRAFT, '', '## Core objects', '']
for k, t in sorted(glossary.items(), key=lambda kv: kv[1]['term']):
    if k in states_of:
        o = states_of[k]
        g += [f'### {t["term"]}', f'{t["def"] or "Draft: no definition found."} Owns: draft - states {", ".join(o["state"][2])}.',
              f'_Found in_: {o["file"]}', '']
g += ['## Other terms', '']
for k, t in sorted(glossary.items(), key=lambda kv: kv[1]['term']):
    if k not in states_of:
        g += [f'### {t["term"]}', t['def'] or 'Draft: no definition found.',
              '_Found in_: ' + ('code ' + t['code'] if t['code'] else '') + (' and ' if t['code'] and t['doc'] else '') + ('docs ' + t['doc'] if t['doc'] else ''), '']
w('GLOSSARY.draft.md', '\n'.join(g))

c = ['---', 'status: draft', '---', f'# Domain model: {name} (draft)', '', DRAFT, '', '## Core objects', '']
for o in sorted(objects, key=lambda o: o['name']):
    field, typ, vals = o['state']
    c += [f'### {o["name"]}', '- Responsibility: draft - not found in the code; ask',
          '- Behaviour: ' + (', '.join(f'`{m}()`' for m in o['methods']) or 'none found'),
          '- Invariants: draft - none found in the code; ask',
          f'- Lives in: `{o["file"]}`',
          f'- Lifecycle: draft - states found in `{typ if typ in state_types else field}`: {", ".join(vals)}; transitions unknown',
          '- Fields: ' + ', '.join(o['fields']), '']
w('core-objects.draft.md', '\n'.join(c))

wow = ['---', 'status: draft', '---', f'# Ways of working: {name} (draft)', '', DRAFT, '', '## Stack',
       '- Source read: ' + (', '.join(f'{l} {n} file(s)' for l, n in sorted(langs.items())) or 'no source files') + ' - decision draft.',
       '', '## Rules', '| Rule | Why | Enforced by | Proof (planted fault fails, allowed use passes) |', '|---|---|---|---|']
wow += [f'| {r} | draft | `{cmd or "no command found"}` ({cfg}) | draft: plant one fault and one allowed file |' for r, cfg, cmd in rules] or ['| none detected | draft | none | draft |']
for target in ('Floor (numbers)', 'Measured, not yet enforced'):
    if target in mapped:
        wow += ['', f'## {target}'] + [(f'### {h}\n' if h != target.split(' (')[0] else '') + b for h, b in mapped[target]]
for target in sorted(t for t in mapped if t.startswith('From CONSTRAINTS.md')):
    wow += ['', f'## {target}', mapped[target][0][1]]
wow += ['', '## Folders', 'Top level: ' + (', '.join(tops) or 'none') + ('. Under src: ' + ', '.join(srcdirs) if srcdirs else '') + '.',
        '', '## Tests', ('Runners: ' + ', '.join(f'{n} ({c})' for n, c in runners) + '.' if runners else 'No runner found.')
        + (f' `npm test` runs `{scripts["test"]}`.' if 'test' in scripts else '') + (' CI: ' + ', '.join(ci) + '.' if ci else ' No CI workflow found.')]
if 'Exceptions (time-limited)' in mapped:
    wow += ['', '## Exceptions (time-limited)'] + [b for _, b in mapped['Exceptions (time-limited)']]
w('ways-of-working.draft.md', '\n'.join(wow))

w('preserve-journeys.draft.md', '\n'.join(['# Candidate preserve journeys (draft)', '', DRAFT,
   'Each row is working behaviour that an existing test already names; the captain keeps the ones that must never change.', '',
   '| Candidate | Behaviour | Source | Kind |', '|---|---|---|---|'] + [f'| {j} | {b} | {s} | preserve (draft) |' for j, b, s in journeys]))

gp = ['# Gaps: what the first rounds ask (draft)', '',
      f'Found by reading, so not asked: {len(glossary)} term(s), {len(objects)} object(s) with states, {len(rules)} lint or type rule(s), {len(runners)} test runner(s), {len(journeys)} test behaviour(s).', '']
for n in range(0, len(gaps), 5):
    gp += [f'## Round {n // 5 + 1}', ''] + [f'- Q: {q} | A: | owner: {o}' for _, q, o in gaps[n:n + 5]] + ['']
w('gaps.md', '\n'.join(gp))
print(f'surveyed {name}: {len(glossary)} terms, {len(objects)} core objects, {len(journeys)} candidate journeys, {len(gaps)} gaps in {-(-len(gaps) // 5)} round(s); drafts in {out}')
PY

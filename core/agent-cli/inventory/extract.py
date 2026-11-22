#!/usr/bin/env python3
"""extract.py <tree> <out.tsv> [--usage <file>] [--cases <cases.tsv>]

Finds every action of every `bin/*.sh` script of <tree> and writes one row per (script, action) to <out.tsv>.
An action is reconciled from three sources:
  help      the header comment block: every line that names the script (a `Usage:` prefix allowed); placeholders
            (<...>, [...]) are skipped, so `jg-control.sh <task-id> interrupt` gives `interrupt` and
            `jg-control.sh primary relaunch` gives the two-word action `primary relaunch`;
  dispatch  every top-level `case` on the first argument or a verb variable: its plain-word arms are actions,
            `a|b)` makes b an alias of a;
  callers   lines in agent text and code that name the script followed on the same line by the action word.
`source` says which of help and dispatch found the action; a one-source row is listed for review.

Two review rules turn that discovery into the operations the reviewed list (core/agent-cli/operations.tsv) names:
  usage-line + case-arm  a help-only word with no usage-shaped header line (`<script> [<arg>|--flag]... <word>`) and
                         no case arm in the script is a word of a description, not an operation: it is dropped
                         (`with` in `jg-control.sh ... with`);
  sub-words              an action whose usage lines name two or more plain sub-words (`reconcile list`,
                         `reconcile close`) is split into one action per sub-word, so a read and a change never
                         share a path.

Class (`public`, `internal`, `lib`, `test-only`, `orphan`) comes from what the tree itself says: a script an agent
instruction names or an operation the command contract exposes is public.
The optional --usage file (the executed-script counts of a private log, rows of
`count<TAB>...<TAB>...<TAB>script`) only fills the `main_runs_30d` column for discovery: no class and no coverage
line ever reads it, so a tree gives the same operations with or without private logs.

Effect, by behavior: the action's dispatch arm plus the bodies of the script's own functions it calls (two hops), or the
whole script for a single-action script, are scanned for writes. Any write: `change`. No write and a read-like name:
`read`. No write and any other name: `change?` (unreviewed, served as a change).

With --cases (script, action, class, effect; written by hand from reading the scripts) every case row must be present
with that class, and none may be served with the wrong effect: a change found as a read, or a read found to write,
exits 1 naming it. A read found as `change?` is reported `unreviewed` and left to the parse check's run.
"""
import argparse
import collections
import json
import os
import re
import sys

COLUMNS = ['script', 'action', 'aliases', 'source', 'kind', 'agent_refs', 'code_callers', 'first_code_caller',
           'action_callers', 'test_files', 'main_runs_30d', 'class', 'effect', 'area', 'command', 'rule']

# Areas: first match wins; planning is tested before notifications so `swarm` is never read as `arm`.
AREAS = [
    ('planning', 'plan', r'war-room|swarm|blitz|op-order|(^|-)plan|council|muster'),
    ('outside channels', 'relay', r'(^|-)x-|public-|contribution|procevent|relay|voice|telegram'),
    ('reports', 'report', r'report|bearings|whats-left|outcome|ready-trace|claim|clause|carrier|catalog|tokens|audience|kpi|ledger'),
    ('notifications', 'radio', r'wake|watch|(^|-)bus(-|$)|supervision|session-?start|sentinel|heartbeat|afk|turnend|startup|guard|digest|cycle|(^|-)arm(-|$)|nudge|hook|host-wiring|subagent|supervise|(^|-)beat|check-(un)?register|^on$'),
    ('steering', 'radio', r'send|inbox|operational-input|delivery|peek|mail|chat|(^|-)say'),
    ('workers', 'crew', r'spawn|control|brief|dispatch|harness|restart|relaunch|lease|crew|fleet|tasks-axi|stack|worker|lane|pane|tmux|herdr|endpoint|account|profile|quota|model|trust|backend|compat|vendor|remote-doctor|switch'),
    ('cleanup', 'crew', r'teardown|cleanup|reaper|prune|tmp-|sweep|park'),
    ('backlog', 'ticket', r'backlog|beads|ticket|move|machine|goal|stage|retitle|classify|triage|promote|flow|workflow|wait-write'),
    ('decisions', 'hold', r'captain|question|board|decision|owner|hold|ask|card|sign-?off|answer'),
    ('alerts', 'alert', r'alert|stall|escalat|wait-timer|drift'),
    ('proof', 'proof', r'proof|recon|dod|done-done|test|receipt|lint|checks|verify|gate|evidence|journey|critic|scratch|run-owned|runner|suite|hc-lab|stow|acceptance'),
    ('landing', 'land', r'pr-|merge|trunk|land|release|branch|live|post-merge|ci-|push|forge|git-'),
    ('homes', 'home', r'update|sync|config|squad|lead|home|resupply|inherit|project|bootstrap|install|skill|role|lock|state|pref|agents-md|migrat'),
]
READ_NAME = re.compile(r'^(list|ls|show|status|get|check|digest|report|view|peek|verify|find|keys|state|open|answered|phase|'
                       r'blocking|binding|questions|why|explain|print|read|count|tree|summary|lint|audit|split|has|which|'
                       r'path|doctor|snapshot|trace|whats-left|kpi|score|diff|compare|clean-days|lanes|tasks|board|wakes|'
                       r'holds|pr|tickets|decisions|messages|status-line)$|^(is|can|show|list|get)-')
SPLIT_READ_WORDS = ('list', 'show', 'status', 'view')
STEM_READ = re.compile(r'(peek|state|status|view|report|digest|show|list|doctor|kpi|whats-left|trace|audit|axi)$')
WRITE = re.compile(
    r'(?<![\w&>-])>{1,2}\s*(?![&>]|/dev/null)["$/A-Za-z_.~{]'      # a redirect into a file (not >&2, 2>, or <id>)
    r'|\b(mv|rm|mkdir|touch|tee|cp|ln|install|chmod|truncate|rsync)\s+-?'
    r'|\bgit\s+(-C\s+\S+\s+)?(commit|push|update-ref|merge|checkout|switch|worktree|tag|branch|reset|rebase|cherry-pick|am|apply|fetch|pull|clone|init|config|notes)\b'
    r'|\b(jg_backlog_mutate|backlog_cmd|backlog_|bd_|bd)\s+(add|create|update|done|close|hold|unhold|resolve|gate|reopen|start|block|unblock|edit|move|delete|set)\b'
    r'|jg-(send|spawn|teardown|control|backlog|captain-hold|move|pr-merge|merge-local|trunk|swarm|plan-file|alert|inbox|question-card|delivery|lease|fleet-ledger)\.sh\s+(?!--help|-h\b|show|list|status|questions|open|answered|check\b|report\b)'
    r'|\bgh(-axi)?\s+\S+\s+(create|merge|edit|comment|close|reopen|delete|review|release|ready)\b'
    r'|\bcurl\b[^\n]*-X\s*(POST|PUT|PATCH|DELETE)|\bsqlite3\b[^\n]*(insert|update|delete|create)\b|\bopenssl\s+rand\b'
    r'|\btmux\s+(send-keys|new-session|kill|split|respawn)|\bherdr\s+(start|stop|kill|send|new)|\bkill\s+-')
SUBJECT = re.compile(r'^case\s+"?\$\{?([A-Za-z_][A-Za-z0-9_]*|1|1:-|1-)\}?"?\s+in\b')
VERBVAR = re.compile(r'^(1|1:-|1-|[A-Za-z_]*(?:verb|VERB|cmd|CMD|sub|SUB|action|ACTION|mode|MODE|command|COMMAND|op|OP))$')
ARM = re.compile(r'^\s+([A-Za-z0-9][A-Za-z0-9|_-]*|--?[a-z][a-z0-9-]*(?:\|--?[a-z][a-z0-9-]*)*)\)')
FUNC = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{', re.M)
USAGE_ARG = re.compile(r'^(?:<[^>]*>|\[[^\]]*\]|--?[\w-]+(?:=\S+)?|\{[^}]*\}|[A-Z_][A-Z0-9_]*|\||\.\.\.|-)$')
WORD = re.compile(r'^[a-z][a-z0-9-]*$')


def read(path):
    try:
        with open(path, errors='replace') as f:
            return f.read()
    except OSError:
        return ''


def header(text, limit=200):
    """The leading comment block of a script (the shebang line left out)."""
    out = []
    for line in text.splitlines()[1:limit]:
        if not line.startswith('#'):
            break
        out.append(line)
    return out


class Tree:
    """What a tree says about its scripts: agent text that names them, code that calls them, tests that cover them."""

    def __init__(self, root):
        self.root = root
        self.bin = os.path.join(root, 'bin')
        self.scripts = sorted(n for n in os.listdir(self.bin) if n.endswith('.sh'))
        agent_files = []
        for top in ('.agents/skills', 'skills', 'docs/supervision-protocols'):
            for dp, _, fs in os.walk(os.path.join(root, top)):
                agent_files += [os.path.join(dp, f) for f in fs if f.endswith('.md')]
        agent_files += [os.path.join(root, 'AGENTS.md'), os.path.join(self.bin, 'jg-brief.sh')]
        code_files, test_files = [], []
        for top in ('bin', 'core'):
            for dp, _, fs in os.walk(os.path.join(root, top)):
                for f in fs:
                    p = os.path.join(dp, f)
                    (test_files if '/tests/' in p + '/' and top == 'core' else code_files).append(p)
        for dp, _, fs in os.walk(os.path.join(root, 'tests')):
            test_files += [os.path.join(dp, f) for f in fs]
        self.agent_text = {p: read(p) for p in agent_files}
        self.code_text = {p: read(p) for p in code_files}
        self.test_text = {p: read(p) for p in test_files}
        self.public_operations = set()
        contract_dir = os.path.join(root, 'core', 'agent-cli', 'contract')
        if os.path.isdir(contract_dir):
            for name in os.listdir(contract_dir):
                if not name.endswith('.json'):
                    continue
                fragment = json.loads(read(os.path.join(contract_dir, name)))
                self.public_operations.update(
                    (entry['script'][4:], entry['operation']) for entry in fragment['entries']
                    if entry['script'].startswith('bin/'))

    def script_path(self, name):
        return os.path.join(self.bin, name)

    def sourced_only(self, name):
        pat = re.compile(r'(?:^|\s)(?:\.|source)\s+["\']?[^\s"\']*' + re.escape(name))
        return any(pat.search(t) for t in self.code_text.values() if name in t)


def load_usage(path):
    """Executed-script counts of a private log: `count<TAB>...<TAB>...<TAB>script`; a missing file is no counts."""
    runs = collections.Counter()
    if path:
        for line in read(path).splitlines():
            parts = line.split('\t')
            if len(parts) == 4 and parts[0].isdigit():
                runs[parts[3]] = int(parts[0])
    return runs


# ------------------------------------------------------------------ discovery

def help_actions(name, head):
    acts = []
    pat = re.compile(r'(?:^|[\s`(])(?:bin/)?' + re.escape(name) + r'((?:\s+\S+){0,6})')
    for line in head:
        for m in pat.finditer(line):
            words = []
            for tok in m.group(1).split():
                tok = tok.strip('`,;')
                if tok.startswith('<') or tok.startswith('['):
                    if words:
                        break
                    continue
                if re.fullmatch(r'[a-z][a-z0-9-]*', tok):
                    words.append(tok)
                    if len(words) == 2:
                        break
                    continue
                if re.fullmatch(r'--?[a-z][a-z0-9-]*', tok) and not words:
                    words.append(tok)
                break
            acts.append('-' if not words else (words[0] if words[0].startswith('-') else ' '.join(words)))
    return acts


def dispatch(text):
    """Top-level case statements on a verb: {action: (aliases, arm body)}. A statement counts when its subject is a verb
    variable or it has two or more plain-word arms. Arms grouped as `a|b)` are aliases, unless the arm body uses the
    subject itself (`"cmd_$c"`), when each word is its own action."""
    lines = text.splitlines()
    found = {}
    i = 0
    while i < len(lines):
        m0 = SUBJECT.match(lines[i])
        if m0:
            var = m0.group(1)
            j = i + 1
            arms = []
            while j < len(lines) and not re.match(r'^esac\b', lines[j]):
                m = ARM.match(lines[j])
                if m and lines[j].startswith('  ') and not lines[j].startswith('     '):
                    arms.append([m.group(1).split('|'), [lines[j][m.end():]]])
                elif arms:
                    arms[-1][1].append(lines[j])
                j += 1
            words = [a for a in arms if not a[0][0].startswith('-')]
            if VERBVAR.match(var) or len(words) >= 2:
                for pats, body in arms:
                    body = '\n'.join(body)
                    if re.search(r'\$\{?' + re.escape(var) + r'\b', body) and var not in ('1', '1:-', '1-'):
                        for pat in pats:
                            found.setdefault(pat, ([], body))
                    else:
                        found.setdefault(pats[0], (pats[1:], body))
            i = j
        i += 1
    return found


def functions(text):
    starts = [(m.group(1), m.start()) for m in FUNC.finditer(text)]
    return {fn: text[s:(starts[k + 1][1] if k + 1 < len(starts) else len(text))] for k, (fn, s) in enumerate(starts)}


def effect(action, body, funcs, whole, stem=''):
    scope = body
    if body is None:
        scope = whole
    else:
        named = {'cmd_' + action.replace('-', '_'), 'do_' + action.replace('-', '_'), action.replace('-', '_') + '_cmd'}
        seen = set()
        for _hop in range(2):  # the arm's own functions, then the functions they call
            add = [fn for fn in funcs if fn not in seen and (fn in named or re.search(r'(^|[^\w-])' + re.escape(fn) + r'\b', scope))]
            for fn in add:
                seen.add(fn)
                scope += '\n' + funcs[fn]
    code = '\n'.join(re.sub(r'\s#\s.*$', '', l) for l in scope.splitlines() if not l.lstrip().startswith('#'))
    if WRITE.search(code):
        return 'change'
    if action == '-':
        return 'read' if STEM_READ.search(stem) else 'change?'
    name = action.lstrip('-').split(' ')[-1]
    return 'read' if READ_NAME.match(name) else 'change?'


def script_actions(name, text):
    """{action: set of sources} for one script, with each action's dispatch arm and aliases."""
    disp = dispatch(text)
    dwords = {k for k in disp if not k.startswith('-')}
    acts = collections.OrderedDict()
    for a in help_actions(name, header(text)):
        first = a.split(' ')[0]
        if a in ('--help', '-h'):
            continue
        if ' ' in a:
            second = a.split(' ')[1]
            if second not in dwords:
                a = first  # a second word is part of the action only when it is itself a dispatch word
        acts.setdefault(a, set()).add('help')
    for d in disp:
        if d in ('-h', '--help', 'help', '*') or (d.startswith('-') and dwords):
            continue
        hit = next((a for a in acts if a.split(' ')[-1] == d or a.split(' ')[0] == d), None)
        acts.setdefault(hit or d, set()).add('dispatch')
    if [a for a in acts if not a.startswith('-')]:  # a flag that stands where a verb would is an action only alone
        for a in [a for a in acts if a.startswith('-') and a != '-']:
            acts.pop(a)
    if not [a for a in acts if not a.startswith('-') or a == '-']:
        acts['-'] = {'help'}
    if '-' in acts and [a for a in acts if a != '-' and not a.startswith('-')]:
        acts.pop('-')
    return acts, disp


def discover(tree, runs):
    rows = []
    for n in tree.scripts:
        p = tree.script_path(n)
        text = read(p)
        agent = sum(v.count(n) for k, v in tree.agent_text.items() if k != p)
        code_callers = sorted(os.path.relpath(k, tree.root) for k, v in tree.code_text.items() if k != p and n in v)
        tests = sum(1 for v in tree.test_text.values() if n in v)
        kind = 'lib' if n.endswith('-lib.sh') or (tree.sourced_only(n) and agent == 0) else 'exe'
        stem = n[3:-3] if n.startswith('jg-') else n[:-3]
        area, noun = next(((a, w) for a, w, rx in AREAS if re.search(rx, stem)), ('other', 'misc'))
        if kind == 'lib':
            cls = 'lib'
        elif agent > 0:
            cls = 'public'
        elif code_callers:
            cls = 'internal'
        elif tests:
            cls = 'test-only'
        else:
            cls = 'orphan'
        acts, disp = script_actions(n, text)
        funcs = functions(text)
        for a, src in acts.items():
            operation_class = 'public' if (n, a) in tree.public_operations else cls
            last = a.split(' ')[-1]
            body = disp[last][1] if last in disp else (disp[a.split(' ')[0]][1] if a.split(' ')[0] in disp else None)
            if a == '-' or not disp:
                body = None
            aliases = ','.join(disp[last][0]) if last in disp else ''
            word = re.escape(last)
            callpat = re.compile(re.escape(n) + r'[^\n]{0,80}?\s' + word + r'\b') if a != '-' else None
            callers = (sum(len(callpat.findall(v)) for k, v in list(tree.agent_text.items()) + list(tree.code_text.items())
                           if k != p and n in v) if callpat else agent + len(code_callers))
            leaf = stem if a == '-' else f'{stem} {a.lstrip("-")}'
            rows.append(dict(script=n, action=a, aliases=aliases or '-', source='+'.join(sorted(src)), kind=kind,
                             agent_refs=agent, code_callers=len(code_callers),
                             first_code_caller=code_callers[0] if code_callers else '-', action_callers=callers,
                             test_files=tests, main_runs_30d=runs[n], **{'class': operation_class},
                             effect=effect(a, body, funcs, text, stem), area=area, command=f'jg {noun} {leaf}', rule=''))
    return rows


# ------------------------------------------------------------------ review rules

def usage_words(script, line):
    """The plain words of a usage-shaped header line: `[Usage:] [bin/]<script> [<arg>|--flag]... <word> [<word>] [<arg>]...`,
    read up to the first run of two spaces (where the description starts); `a | b | c` gives each as an alternative first
    word. None when the line is not usage-shaped (a description, an example, a sentence)."""
    body = re.sub(r'^#\s*(?:Usage:\s*)?', '', line)
    cmd = re.split(r'\s{2,}', body.strip())[0]
    prev = None
    while prev != cmd:  # drop bracketed and angled groups, innermost first
        prev = cmd
        cmd = re.sub(r'\[[^\[\]]*\]|<[^<>]*>|\{[^{}]*\}', ' ', cmd)
    toks = cmd.split()
    if not toks or re.sub(r'^bin/', '', toks[0]) != script:
        return None
    rest = [t for t in toks[1:] if not USAGE_ARG.match(t) or t == '|']
    if '|' in rest:
        alts = [t for t in rest if t != '|']
        return [[w] for w in alts] if alts and all(WORD.match(w) for w in alts) else None
    if not rest or len(rest) > 2 or not all(WORD.match(w) for w in rest):
        return None if rest else []
    return [rest]


def has_case_arm(text, word):
    return bool(re.search(r'(?m)^\s*(?:[\w.-]+\s*\|\s*)*' + re.escape(word) + r'\s*(?:\|[^)\n]*)?\)', text)
                or re.search(r'=\s*"?' + re.escape(word) + r'"?\s*\]', text))


def apply_review_rules(tree, rows):
    """(kept rows, dropped [(script, action)], split [(script, action, sub-words)])."""
    out, dropped, split = [], [], []
    texts = {}
    for r in rows:
        s, a = r['script'], r['action']
        if s not in texts:
            text = read(tree.script_path(s))
            shaped = [w for ws in (usage_words(s, l) for l in header(text, 400)) if ws for w in ws]
            texts[s] = (text, shaped)
        text, shaped = texts[s]
        if r['source'] == 'help' and a != '-' and not a.startswith('-'):
            word = a.split(' ')[0]
            if not has_case_arm(text, word) and not any(w[0] == word for w in shaped):
                dropped.append((s, a))
                continue
        subs = []
        if a != '-' and ' ' not in a:
            for w in shaped:
                if w[0] == a and len(w) == 2 and w[1] not in subs:
                    subs.append(w[1])
        if len(subs) >= 2:
            for w in subs:
                out.append(dict(r, action=f'{a} {w}', effect='read' if w in SPLIT_READ_WORDS else 'change',
                                command=r['command'] + ' ' + w, rule=f'split from {a}'))
            split.append((s, a, subs))
            continue
        out.append(r)
    return out, dropped, split


def extract(root, usage=None):
    """(rows, dropped, split) for the tree at <root>."""
    tree = Tree(root)
    return apply_review_rules(tree, discover(tree, load_usage(usage)))


# ------------------------------------------------------------------ cases and report

def check_cases(rows, cases_path):
    """Print one line per case; return 1 when a case is missing, has the wrong class, or is served with the wrong effect."""
    have = {(r['script'], r['action']): r for r in rows}
    rc = 0
    print('# independent cases')
    for line in read(cases_path).splitlines():
        if line.startswith('#') or not line.strip():
            continue
        s, a, c, e = line.split('\t')[:4]
        r = have.get((s, a))
        if not r:
            print(f'MISSING\t{s}\t{a}')
            rc = 1
        elif r['class'] != c or (e == 'change' and r['effect'] == 'read') or (e == 'read' and r['effect'] == 'change'):
            print(f'WRONG\t{s}\t{a}\twant {c}/{e}\tgot {r["class"]}/{r["effect"]}')
            rc = 1
        elif e == 'read' and r['effect'] == 'change?':
            print(f'unreviewed\t{s}\t{a}\twant {c}/{e}\tgot change?: served as a change until the parse check proves it reads only')
        else:
            print(f'ok\t{s}\t{a}\t{c}/{r["effect"]}\t{r["command"]}\tsource={r["source"]}')
    return rc


def report(rows, dropped, split):
    pub = [r for r in rows if r['class'] == 'public']
    print(f'# bin/*.sh actions={len(rows)} in {len({r["script"] for r in rows})} scripts; dropped (a word of a description) {len(dropped)}; '
          f'split into sub-word actions {len(split)}')
    print(f'# public actions={len(pub)} in {len({r["script"] for r in pub})} scripts; effect: '
          + ', '.join(f'{k} {v}' for k, v in collections.Counter(r['effect'] for r in pub).most_common()))
    print('# public actions by source: ' + ', '.join(f'{k} {v}' for k, v in collections.Counter(r['source'] for r in pub).most_common()))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('tree')
    ap.add_argument('out')
    ap.add_argument('--usage', help='executed-script counts of a private log: fills main_runs_30d only')
    ap.add_argument('--cases', help='hand-written cases: script, action, class, effect')
    args = ap.parse_args(argv)
    rows, dropped, split = extract(args.tree, args.usage)
    with open(args.out, 'w') as f:
        f.write('\t'.join(COLUMNS) + '\n')
        for r in rows:
            f.write('\t'.join(str(r[c]) for c in COLUMNS) + '\n')
    report(rows, dropped, split)
    return check_cases(rows, args.cases) if args.cases else 0


if __name__ == '__main__':
    sys.exit(main())

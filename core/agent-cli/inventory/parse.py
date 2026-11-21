#!/usr/bin/env python3
"""parse.py <command> <tree> <operations.tsv> <scratch> [options]

The parse check of the reviewed list of public operations (core/agent-cli/operations.tsv). Each row's `form` is the
script's own usage line for the operation, positional arguments in place (`bin/jg-control.sh <task-id> interrupt`); this
check renders a form with fixture values and runs it through the real script, so a form that does not parse fails.

Every run is on a throwaway home with argument-recording stand-ins on PATH (tmux, herdr, gh, ssh, systemctl, pkill,
curl, the agent CLIs...), in a copy of the tree, with stdin closed. Before each run the home is put back to the same
fixture, which holds data for a read to act on (an answered hold on jg-t1, an open one on jg-t2). The home's file
digest before and after the run, and every call to a stand-in, are what a run reports. Nothing outside <scratch> is
read or written, and no live home is read.

commands (one line per run; exit 1 when any line is a failure):
  usage    every row whose note says form=usage, optional groups dropped, a required (a | b) group's first alternative;
           a refusal with the script's usage text, or an unknown verb, fails the row; help-only rows are listed for their
           owning orders and never run
  options  every optional `--option <value>` group of a form, parsed once absent and once present with a fixture value
  get      every GET row on the fixture with data: it must change no file and call nothing outside
  parity   a row listed POST whose script header calls it read-only and whose run changes nothing and calls nothing
           outside: a read served as a change (the method of a row changes only by review with that run named in its note)
  shapes   every positional row (an argument before or between the operation words): the form parses; the older shape
           (operation words first, arguments after) is refused by the parser
  names    every --option a form names appears in the code of its script, or of a file the script hands its arguments to
  forms    <script>: the usage-line forms of a script, each indented `[...]` or `(...)` continuation line joined
  run      <script> <operation> [--set name=value]... [--extra word]...: one row, with extra arguments after the
           operation words
  all      usage, options, get, parity, shapes, names
"""
import argparse
import csv
import hashlib
import os
import re
import shutil
import subprocess
import sys

TIMEOUT = 8
STAND_INS = ('tmux', 'herdr', 'gh', 'gh-axi', 'ssh', 'scp', 'systemctl', 'pkill', 'killall', 'curl', 'wget', 'claude', 'codex',
             'opencode', 'pi', 'no-mistakes', 'sign-off-axi', 'lavish-axi', 'notify-send', 'chrome-devtools-axi', 'docker',
             'treehouse', 'sudo', 'reboot', 'shutdown', 'loginctl', 'xdg-open', 'open', 'rsync', 'cursor-agent', 'agy', 'kimi',
             'grok', 'omp', 'muse', 'gemini', 'devin', 'rovo', 'done-done')
# Rows the check lists and never runs: they wire the host, sweep temp folders, start a daemon or run the whole suite, so
# their owning orders run them on a lab home.
NOT_RUN = {('jg-host-wiring.sh', '-'): 'wires host protections and services',
           ('jg-tmp-sweep.sh', 'sweep'): 'removes temp folders',
           ('jg-test-run.sh', '-'): 'runs the whole test suite',
           ('jg-afk-start.sh', '-'): 'starts the supervise daemon',
           ('jg-supervise-daemon.sh', '-'): 'is the supervise daemon'}
# Fixture values for a placeholder only one script gives a meaning to.
SCRIPT_VALUES = {
    ('jg-goal.sh', 'proof argv...'): '/bin/false',
    ('jg-machine-guard.sh', 'name'): 'reuse',
    ('jg-remote-inherit.sh', 'allowlisted-relative-path'): 'config/crew-harness',
    ('jg-vendor-auth-probe.sh', 'probe'): 'grok',
    ('jg-workflow.sh', 'sub'): 'list',
}
FORM_VALUES = {'0-3': '2', '0-4': '2', 'YYYY-MM-DD': '2099-01-01', 'bytes': '0', 'generation': '1',
               'empty-sha256': hashlib.sha256(b'').hexdigest(), 'max-sequence': '1',
               'kind:pointer': 'status:fixture', 'file-or-dash': '-'}
# A usage error, an unknown verb or a form the parser does not know: the form did not parse.
PARSE_ERROR = re.compile(r'(?i)\busage:|\bunknown (?:verb|wait kind|option|command|subcommand|flag|argument|mode|action|operation)\b'
                         r'|unrecognized (?:option|argument)|invalid option|is not a (?:control )?verb|no home at|unexpected argument')
ARG = re.compile(r'^(?:<[^>]*>|\[[^\]]*\]|--?[\w-]+(?:=\S+)?|\{[^}]*\}|[A-Z_][A-Z0-9_]*|\.\.\.|-|\(.*\))$')

NUMBERS = {'epoch', 'count', 'seq', 'sequence', 'n', 'seconds', 'h', 'm', 'e', 'pid', 'duration-ms', 'entered_epoch', 'at', 'busy-gen', 'point', 'k',
           'stop-row', 'version', 'request_id', 'row', 'version'}
SHAPES = [  # (name pattern, kind): the first match gives the fixture value's kind
    (r'(^|-)(file|files)$|\.(json|md|tsv|txt)$|^(path|map|brief|records|corpus|payload|input|output|card|feed|board|decisions)$|result|receipt', 'file'),
    (r'(dir|root|folder|directory)$|^(home|jg-home|worktree|clone-dir|work-dir|lab-root|state-dir|project-dir)$|^home-id$', 'dir'),
    (r'(^|-)(url)$|^pr-url$|^merged-pr-url$|^source-url$', 'url'),
    (r'^(sha|sha256|head|commit|base|judged-head|binding-digest|ref|reference)$', 'sha'),
    (r'(ticket|task|goal|origin|bypass|squad-lead|council|obligation|relation|work|delivered|note|session|mate|change|owner-rule|machine|card-key|key|alert|event-token)(-id)?$|^id$|^(task-id|ticket-id)$', 'id'),
]


def rmtree_force(path):
    """Remove a folder tree a run may have left read-only (a hook install)."""
    def writable(func, p, _exc):
        os.chmod(os.path.dirname(p), 0o700)
        os.chmod(p, 0o700)
        func(p)
    shutil.rmtree(path, onerror=writable)


def tree_copy(src, dst):
    """A copy of the tree's files (tracked and untracked, ignored left out) so a script that writes next to itself
    writes into the copy."""
    git = subprocess.run(['git', '-C', src, 'ls-files', '-co', '--exclude-standard', '-z'], capture_output=True)
    if git.returncode == 0 and git.stdout:
        names = [n for n in git.stdout.decode().split('\0') if n and os.path.isfile(os.path.join(src, n))]
    else:
        names = [os.path.relpath(os.path.join(dp, f), src) for dp, dns, fs in os.walk(src)
                 for f in fs if '.git' not in dp.split(os.sep)]
    for n in names:
        d = os.path.join(dst, n)
        os.makedirs(os.path.dirname(d), exist_ok=True)
        shutil.copy2(os.path.join(src, n), d, follow_symlinks=False)


class Lab:
    """A throwaway world: a tree copy, a home with fixture data, stand-ins on PATH. `run` puts the home back first."""

    def __init__(self, tree, scratch):
        self.scratch = os.path.abspath(scratch)
        if os.path.exists(self.scratch):
            rmtree_force(self.scratch)
        os.makedirs(self.scratch)
        self.tree = os.path.join(self.scratch, 'tree')
        tree_copy(os.path.abspath(tree), self.tree)
        self.run_dir = os.path.join(self.scratch, 'run')
        self.snap = os.path.join(self.scratch, 'snap')
        self.home = os.path.join(self.run_dir, 'home')
        self.stub = os.path.join(self.scratch, 'stub')
        self.calls = os.path.join(self.scratch, 'calls.log')
        os.makedirs(self.stub)
        for prog in STAND_INS:
            p = os.path.join(self.stub, prog)
            with open(p, 'w') as f:
                f.write(f'#!/bin/sh\nprintf "%s\\t%s\\n" "{prog}" "$*" >> "{self.calls}"\nexit 0\n')
            os.chmod(p, 0o755)
        self.env = {'PATH': self.stub + ':/usr/bin:/bin', 'HOME': os.path.join(self.run_dir, 'dothome'),
                    'TMPDIR': os.path.join(self.run_dir, 'tmp'), 'JG_HOME': self.home,
                    'JG_STATE_OVERRIDE': self.home + '/state', 'JG_DATA_OVERRIDE': self.home + '/data',
                    'JG_CONFIG_OVERRIDE': self.home + '/config', 'JG_PROJECTS_OVERRIDE': self.home + '/projects',
                    'XDG_CONFIG_HOME': os.path.join(self.run_dir, 'dothome', 'config'), 'XDG_DATA_HOME': os.path.join(self.run_dir, 'dothome', 'data'),
                    'XDG_CACHE_HOME': os.path.join(self.run_dir, 'dothome', 'cache'), 'XDG_STATE_HOME': os.path.join(self.run_dir, 'dothome', 'state'),
                    'LANG': 'C.UTF-8', 'JG_SPAWN_NO_GUARD': '1', 'JG_TEST_SEAM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
                    'GIT_CONFIG_SYSTEM': '/dev/null', 'GIT_AUTHOR_NAME': 'fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.com',
                    'GIT_COMMITTER_NAME': 'fixture', 'GIT_COMMITTER_EMAIL': 'fixture@example.com'}
        self.values = {}
        self._build_world()
        shutil.copytree(self.run_dir, self.snap, symlinks=True)

    def _sh(self, *argv, stdin=''):
        return subprocess.run(list(argv), capture_output=True, text=True, input=stdin, env=self.env, cwd=self.run_dir, timeout=60)

    def _build_world(self):
        h = self.home
        for d in ('config', 'data', 'state', 'projects', 'tmp', 'dothome'):
            os.makedirs(os.path.join(self.run_dir, d) if d in ('tmp', 'dothome') else os.path.join(h, d), exist_ok=True)
        open(os.path.join(h, 'config', 'backlog-intake-loose'), 'w').close()
        backlog = os.path.join(self.tree, 'bin', 'jg-backlog.sh')
        hold = os.path.join(self.tree, 'bin', 'jg-captain-hold.sh')
        for tid, title in (('jg-t1', '[feature] Fixture ticket'), ('jg-t2', '[feature] Second fixture')):
            self._sh(backlog, 'add', tid, title, '--priority', '2', '--kind', 'ship', '--repo', 'demo', '--body', 'fixture')
        # data for a read to act on: jg-t1 holds an answered question (a closed gate), jg-t2 an open one
        self._sh(hold, 'hold', 'jg-t1', '--reason', 'Ship the fixture now?')
        out = self._sh(backlog, 'questions', '--ticket', 'jg-t1', '--json').stdout
        m = re.search(r'"id":\s*"([^"]+)"', out)
        if m:
            self._sh(hold, 'answers', '--source', 'board fixture', stdin=f'{m.group(1)}\tyes\tyes\n')
        self._sh(hold, 'hold', 'jg-t2', '--reason', 'Start the second fixture?')
        proj0 = os.path.join(self.run_dir, 'proj')
        with open(os.path.join(h, 'state', 'jg-t1.meta'), 'w') as f:
            f.write(f'worktree={proj0}\nproject={proj0}\nkind=ship\nmode=local-only\nharness=claude\nbranch=fm/jg-t1\n')
        status = os.path.join(h, 'state', 'jg-t1.status')
        with open(status, 'w') as f:
            f.write('working [at=1795000000]: fixture\n')
        proj = os.path.join(self.run_dir, 'proj')
        os.makedirs(proj)
        git = ['git', '-C', proj]
        subprocess.run(['git', 'init', '-q', proj], check=True, env=self.env)
        subprocess.run(git + ['commit', '-q', '--allow-empty', '-m', 'fixture'], check=True, env=self.env)
        sha = subprocess.run(git + ['rev-parse', 'HEAD'], capture_output=True, text=True, env=self.env).stdout.strip()
        fixture_file = os.path.join(self.run_dir, 'fixture.json')
        with open(fixture_file, 'w') as f:
            f.write('{}\n')
        with open(os.path.join(self.run_dir, 'decision.txt'), 'w') as f:
            f.write('yes\n')
        os.makedirs(os.path.join(self.run_dir, 'fixture-dir'), exist_ok=True)
        self.values = {'id': 'jg-t1', 'file': fixture_file, 'dir': os.path.join(self.run_dir, 'fixture-dir'),
                       'url': 'https://github.com/o/r/pull/1', 'sha': sha, 'number': '1', 'text': 'fixture',
                       'task-id': 'jg-t1', 'task': 'jg-t1', 'home': h, 'jg-home': h, 'project-dir': proj, 'project': 'demo',
                       'worktree': proj, 'status-file': status, 'path': os.path.join(self.run_dir, 'decision.txt'),
                       'kind': 'stale', 'who': 'worker', 'reason': 'decision', 'line': 'waiting on review', 'level': 'low',
                       'provenance': 'fixture', 'name': 'x', 'harness': 'claude', 'model': 'default', 'effort': 'default',
                       'state-dir': os.path.join(h, 'state'), 'session': 'fixture', 'machine': 'fixture', 'word': 'fixture'}

    def value(self, name, overrides, script=None):
        if name in overrides:
            return overrides[name]
        if (script, name) in SCRIPT_VALUES:
            return SCRIPT_VALUES[(script, name)]
        if name in FORM_VALUES:
            return FORM_VALUES[name]
        if ',' in name:  # <n,...> a list of numbers
            return self.values['number']
        if name in self.values:
            return self.values[name]
        if '|' in name:  # <a|b|c>: the first alternative
            return name.split('|')[0].strip()
        if name in NUMBERS:
            return self.values['number']
        for rx, kind in SHAPES:
            if re.search(rx, name):
                return self.values[kind]
        return self.values['text']

    def reset(self):
        rmtree_force(self.run_dir)
        shutil.copytree(self.snap, self.run_dir, symlinks=True)
        open(self.calls, 'w').close()

    def digest(self):
        h = hashlib.sha256()
        for dp, dns, fs in sorted(os.walk(self.run_dir)):
            dns.sort()
            for f in sorted(fs):
                p = os.path.join(dp, f)
                h.update(p.encode())
                try:
                    with open(p, 'rb') as fh:
                        h.update(fh.read())
                except OSError:
                    pass
        for dp, dns, fs in sorted(os.walk(self.tree)):  # the tree copy: names, sizes and times only
            dns.sort()
            for f in sorted(fs):
                try:
                    st = os.stat(os.path.join(dp, f))
                    h.update(f'{dp}/{f}{st.st_size}{st.st_mtime_ns}'.encode())
                except OSError:
                    pass
        return h.hexdigest()[:12]

    def run(self, argv):
        """argv[0] is a path relative to the tree (`bin/jg-x.sh`). -> (exit, first line, text, changed, calls)."""
        self.reset()
        before = self.digest()
        out_path = os.path.join(self.scratch, 'run.out')
        with open(out_path, 'w') as out:  # a file, not a pipe: a process the run leaves behind cannot hold the check up
            proc = subprocess.Popen([os.path.join(self.tree, argv[0])] + argv[1:], stdin=subprocess.DEVNULL, stdout=out,
                                    stderr=subprocess.STDOUT, env=self.env, cwd=self.run_dir, start_new_session=True)
            try:
                rc = proc.wait(timeout=TIMEOUT)
            except subprocess.TimeoutExpired:
                rc = 'timeout'
            kill_session(proc.pid)
            if rc == 'timeout':
                proc.wait()
        with open(out_path, errors='replace') as f:
            text = f.read()
        after = self.digest()
        with open(self.calls) as f:
            calls = f.read().strip()
        first = (text.strip().splitlines() or [''])[0][:110]
        return rc, first, text, before != after, calls


def kill_session(sid):
    """Kill every process of the session this check started for a run (a script may start a background process in a
    group of its own); never a process outside that session."""
    for entry in os.listdir('/proc'):
        if not entry.isdigit():
            continue
        try:
            with open(f'/proc/{entry}/stat') as f:
                fields = f.read().rsplit(')', 1)[1].split()
            if int(fields[3]) == sid and int(entry) != os.getpid():  # fields: state, ppid, pgrp, session
                os.kill(int(entry), 9)
        except (OSError, ValueError, IndexError):
            continue


# ------------------------------------------------------------------ forms

def header(path):
    out = []
    with open(path, errors='replace') as f:
        lines = f.read().splitlines()[1:400]
    for line in lines:
        if not line.startswith('#'):
            break
        out.append(line)
    return out


def usage_body(line):
    return re.split(r'\s{2,}', re.sub(r'^#\s*(?:Usage:\s*)?', '', line).strip())[0]


def plain_words(script, cmd):
    """(plain words in order) of a usage command when it starts with the script, else None."""
    flat = cmd
    prev = None
    while prev != flat:
        prev = flat
        flat = re.sub(r'\[[^\[\]]*\]|<[^<>]*>|\{[^{}]*\}|\([^()]*\)', ' ', flat)
    toks = flat.split()
    if not toks or re.sub(r'^bin/', '', toks[0]) != script:
        return None
    return [t for t in toks[1:] if not ARG.match(t)]


def top_split(cmd):
    """cmd split on ` | ` outside brackets: `x row <slug> | parts <title>` gives the alternatives after the script."""
    parts, depth, cur = [], 0, ''
    for i, ch in enumerate(cmd):
        depth += ch in '[<({'
        depth -= ch in ']>)}'
        if ch == '|' and depth == 0 and cmd[i - 1:i] == ' ' and cmd[i + 1:i + 2] == ' ':
            parts.append(cur.strip())
            cur = ''
        else:
            cur += ch
    parts.append(cur.strip())
    return parts


def forms(script_path):
    """Every usage-shaped header line of the script: [(operation words, form)], alternatives expanded (`a|b|c` and
    `x <a> | y <b>`), and every indented continuation line that carries a required group (`(--note ... | ...)`) or an
    optional one (`[--effort <level>]`) joined to the line it continues, in order."""
    script = os.path.basename(script_path)
    out = []
    head = header(script_path)
    for k, line in enumerate(head):
        cmd = usage_body(line)
        ws = plain_words(script, cmd)
        if ws is None:
            continue
        for nxt in head[k + 1:]:
            m = re.match(r'^#\s{8,}((?:\(.*\)|\[.*\])(?:\s+(?:\(.*\)|\[.*\]))*)\s*$', nxt)
            if not m:
                break
            cmd += ' ' + m.group(1)
        cmd = re.sub(r'^(bin/)?' + re.escape(script), 'bin/' + script, cmd)
        alts = top_split(cmd[len('bin/' + script):].strip())
        if len(alts) > 1 and all(re.match(r'^[a-z][a-z0-9-]*\b', a) for a in alts):
            for a in alts:
                aw = plain_words(script, script + ' ' + a)
                if aw is not None:
                    out.append((aw, 'bin/' + script + ' ' + a))
            continue
        alt = re.search(r'(?<![\w<\[-])([a-z][a-z0-9-]*(?:\s*\|\s*[a-z][a-z0-9-]*)+)(?![\w>\]])', cmd)
        if alt and not re.search(r'[<\[(][^>\])]*' + re.escape(alt.group(1)), cmd):
            for w in re.split(r'\s*\|\s*', alt.group(1)):
                out.append(([w], cmd.replace(alt.group(1), w, 1)))
            continue
        out.append((ws, cmd))
    return out


def read_words(script_path):
    """Operation words the script's own header calls read-only: a sentence that opens with the word in backticks and says
    "read-only", or a usage line for the word whose description starts "Read-only"."""
    script = os.path.basename(script_path)
    head = header(script_path)
    text = re.sub(r'\n#\s*', ' ', '\n'.join(head))
    reads = set()
    for sent in re.split(r'(?<=[.;:])\s', text):
        if re.search(r'\bread-only\b', sent, re.I):
            m = re.match(r'^#?\s*`([a-z][a-z0-9-]*)`', sent.strip())
            if m:
                reads.add(m.group(1))
    for line in head:
        m = re.match(r'^#\s*(?:Usage:\s*)?(?:bin/)?' + re.escape(script) + r'\s+([a-z][a-z0-9-]*)\s{2,}Read-only', line)
        if m:
            reads.add(m.group(1))
    return reads


def drop_optional(form, keep=None):
    """The form with its optional [...] groups dropped (the group `keep`, unbracketed, stays) and a required (a | b) group
    reduced to its first alternative."""
    mark = '\x00KEEP\x00'
    if keep:
        form = form.replace(keep, mark, 1)
    prev = None
    while prev != form:
        prev = form
        form = re.sub(r'\[[^\[\]]*\]', '', form)
    form = re.sub(r'\(([^()|]*?)\s*\|[^()]*\)', r'\1', form)
    return form.replace(mark, keep[1:-1] if keep else '')


def tokens(form):
    """Whitespace tokens, except that a `<...>` placeholder with a space in it stays one token."""
    return re.findall(r'<[^>]*>(?:\.\.\.)?|\S+', form)


def render(lab, form, overrides=None, script=None, keep=None):
    """(argv, None) for a form rendered with fixture values, or (None, why)."""
    out = []
    for tok in tokens(drop_optional(form, keep)):
        m = re.match(r'^<([^>]+)>(\.\.\.)?$', tok)
        if m:
            out.append(lab.value(m.group(1).strip(), overrides or {}, script))
        elif re.fullmatch(r'[A-Z][A-Z0-9_-]*', tok):
            out.append(lab.value(tok if tok in FORM_VALUES else tok.lower(), overrides or {}, script))
        elif tok in ('|', '...') or tok.endswith('...'):
            continue
        elif re.search(r'[<>(){}|\[\]]', tok):
            return None, f'a group the renderer cannot place: {tok}'
        else:
            out.append(tok)
    return out, None


def optional_groups(form):
    """The optional groups of a form that name one option: `[--effort <level>]`, `[--dry-run]`; top level only."""
    groups, depth, start = [], 0, None
    for i, ch in enumerate(form):
        if ch == '[':
            if depth == 0:
                start = i
            depth += 1
        elif ch == ']' and depth:
            depth -= 1
            if depth == 0:
                g = form[start:i + 1]
                if re.match(r'^\[--[a-z][\w-]*(?:[ =](?:<[^>]+>|[A-Z][A-Z0-9_-]*))?\]$', g) and g != '[--help]':
                    groups.append(g)
    return groups


# ------------------------------------------------------------------ labs run side by side

class Pool:
    """A few labs, each with a world of its own, so rows run side by side without sharing a file."""

    def __init__(self, tree, scratch, jobs):
        from concurrent.futures import ThreadPoolExecutor
        import queue
        self.jobs = jobs
        scratch = os.path.abspath(scratch)
        if os.path.exists(scratch):
            rmtree_force(scratch)
        os.makedirs(scratch)
        with ThreadPoolExecutor(jobs) as ex:
            self.labs = list(ex.map(lambda i: Lab(tree, os.path.join(scratch, f'lab{i}')), range(jobs)))
        self.free = queue.Queue()
        for lab in self.labs:
            self.free.put(lab)
        self.tree = self.labs[0].tree

    def _call(self, fn):
        lab = self.free.get()
        try:
            return fn(lab)
        finally:
            self.free.put(lab)

    def map(self, fns):
        """The results of fn(lab) for each fn, in order."""
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(self.jobs) as ex:
            return list(ex.map(self._call, fns))


# ------------------------------------------------------------------ rows and verdicts

def load_rows(path):
    with open(path, newline='') as f:
        return list(csv.DictReader(f, delimiter='\t'))


def label(row):
    return row['script'] + ('' if row['operation'] == '-' else ' ' + row['operation'])


def verdict(rc, first, text, changed, calls, expect_read=False):
    """(word, failure?) for one run."""
    if rc == 'timeout':
        return 'timeout', False
    if rc != 0 and PARSE_ERROR.search(text):
        return 'parse-error', True
    if changed:
        return 'changed', expect_read
    if calls:
        return 'outside-call', expect_read
    return ('ok' if rc == 0 else 'refused'), False


def line(kind, word, row_label, argv, rc, first, calls='', changed=False):
    short = ' '.join(a if len(a) < 40 else '...' for a in argv[1:])
    extra = ('; files changed' if changed else '') + (f'; outside calls: {calls.replace(chr(10), " / ")[:80]}' if calls else '')
    return f'{kind}\t{word}\t{row_label}\t{short}\texit {rc}; "{first}"{extra}'


def usage_rows(rows):
    return [r for r in rows if 'form=usage' in r['note'] and (r['script'], r['operation']) not in NOT_RUN]


def attempt(lab, row, overrides=None, keep=None):
    """Render the row's form on this lab and run it: (argv, why, result)."""
    argv, why = render(lab, row['form'], overrides, row['script'], keep)
    if argv is not None and (row['script'], row['operation']) == ('jg-live-lab.sh', 'up'):
        # Use an existing fixture directory so the real parser runs without starting a lab.
        argv.append(lab.value('dir', {}))
    return argv, why, (lab.run(argv) if argv is not None else None)


class Known:
    """The ledger of rows known to fail: lines of `mode<TAB>script<TAB>operation<TAB>reason`. A failing row on the ledger is
    reported `known-defect` and does not fail the check; a ledger row that no longer fails is stale and fails it."""

    def __init__(self, path):
        self.rows, self.hit = {}, set()
        if path:
            with open(path) as f:
                for l in f:
                    if l.strip() and not l.startswith('#'):
                        mode, script, op, reason = (l.rstrip('\n').split('\t') + ['', '', '', ''])[:4]
                        self.rows[(mode, script, op)] = reason

    def apply(self, mode, row, word, bad):
        key = (mode, row['script'], row['operation'])
        if bad and key in self.rows:
            self.hit.add(key)
            return 'known-defect', False
        return word, bad

    def stale(self, mode):
        for key in sorted(k for k in self.rows if k[0] == mode and k not in self.hit):
            print(f'{mode}\tSTALE-KNOWN\t{key[1]} {key[2]}\t\ton the ledger but it no longer fails: remove it')
            yield 1


def cmd_usage(pool, rows, args):
    known = Known(args.known)
    todo = []
    for r in rows:
        if 'form=usage' not in r['note']:
            print(f'form\thelp-only\t{label(r)}\t\tlisted for its owning order; not run, never served as GET')
        elif (r['script'], r['operation']) in NOT_RUN:
            print(f'form\tnot-run\t{label(r)}\t\tlisted for its owning order: {NOT_RUN[(r["script"], r["operation"])]}')
        else:
            todo.append(r)
    failed = 0
    for r, (argv, why, res) in zip(todo, pool.map([lambda lab, r=r: attempt(lab, r) for r in todo])):
        if res is None:
            print(f'form\tnot-run\t{label(r)}\t\t{why}')
            continue
        word, bad = known.apply('form', r, *verdict(*res))
        failed += bad
        print(line('form', word, label(r), argv, res[0], res[1], res[4], res[3]))
    return failed + sum(known.stale('form'))


def cmd_options(pool, rows, args):
    """Each optional `--option <value>` group of a form parsed once absent and once present, in the place the form puts it."""
    todo = [r for r in usage_rows(rows) if optional_groups(r['form'])]

    def one(lab, r):
        base = attempt(lab, r)
        out = [('absent', g, base) for g in optional_groups(r['form'])]
        out += [('present', g, attempt(lab, r, keep=g)) for g in optional_groups(r['form'])]
        return out

    failed = 0
    for r, results in zip(todo, pool.map([lambda lab, r=r: one(lab, r) for r in todo])):
        base_res = results[0][2][2]
        row_fails = base_res is not None and verdict(*base_res)[1]  # a form that fails absent is the usage check's finding
        for tag, group, (argv, why, res) in results:
            name = re.match(r'^\[(--[a-z][\w-]*)', group).group(1)
            if res is None:
                print(f'option\tnot-run\t{label(r)} {name} {tag}\t\t{why}')
                continue
            word, bad = verdict(*res)
            failed += bad and not row_fails
            print(line('option', word, f'{label(r)} {name} {tag}', argv, res[0], res[1], res[4], res[3]))
    return failed


def cmd_get(pool, rows, args):
    known = Known(args.known)
    todo = []
    for r in rows:
        if r['method'] != 'GET' or (r['script'], r['operation']) in NOT_RUN:
            continue
        if 'form=usage' not in r['note']:
            print(f'get\thelp-only\t{label(r)}\t\tlisted GET by its name only; its owning order proves it with a run')
        else:
            todo.append(r)
    failed = 0
    for r, (argv, why, res) in zip(todo, pool.map([lambda lab, r=r: attempt(lab, r) for r in todo])):
        if res is None:
            print(f'get\tnot-run\t{label(r)}\t\t{why}')
            continue
        word, bad = known.apply('get', r, *verdict(*res, expect_read=True))
        failed += bad
        print(line('get', word, label(r), argv, res[0], res[1], res[4], res[3]))
    return failed + sum(known.stale('get'))


def cmd_parity(pool, rows, args):
    """A row listed POST that its script's header calls read-only and a run shows to be a read."""
    todo = []
    cache = {}
    for r in rows:
        if r['method'] != 'POST' or r['operation'] == '-' or 'form=usage' not in r['note'] or (r['script'], r['operation']) in NOT_RUN:
            continue
        if r['script'] not in cache:
            cache[r['script']] = read_words(os.path.join(pool.tree, 'bin', r['script']))
        if r['operation'].split(' ')[0] in cache[r['script']]:
            todo.append(r)
    failed = 0
    for r, (argv, why, res) in zip(todo, pool.map([lambda lab, r=r: attempt(lab, r) for r in todo])):
        if res is None:
            print(f'parity\tnot-run\t{label(r)}\t\t{why}')
        elif res[0] == 0 and not res[3] and not res[4]:
            failed += 1
            print(line('parity', 'POST-read', label(r), argv, res[0], res[1]) + '; the row is POST: review it to GET naming this run')
        else:
            print(line('parity', 'POST-kept', label(r), argv, res[0], res[1], res[4], res[3]))
    return failed


def positional(row):
    toks = row['form'].split()[1:]
    words = row['operation'].split(' ') if row['operation'] != '-' else []
    idx = [toks.index(w) for w in words if w in toks]
    return bool(words) and len(idx) == len(words) and any(t.startswith('<') for t in toks[:max(idx)])


def cmd_shapes(pool, rows, args):
    """The form of a positional row parses; its older shape (operation words first) is refused by the parser."""
    todo = [r for r in rows if positional(r) and (r['script'], r['operation']) not in NOT_RUN]

    def both(lab, r):
        argv, why, res = attempt(lab, r)
        if argv is None:
            return argv, why, res, None, None
        words = r['operation'].split(' ')
        old = [argv[0]] + words + [a for a in argv[1:] if a not in words]
        return argv, why, res, old, lab.run(old)

    failed = 0
    for r, (argv, why, res, old, old_res) in zip(todo, pool.map([lambda lab, r=r: both(lab, r) for r in todo])):
        if argv is None:
            print(f'shape\tnot-run\t{label(r)}\t\t{why}')
            continue
        word, bad = verdict(*res)
        failed += bad
        print(line('shape', word, f'{label(r)} form', argv, res[0], res[1], res[4], res[3]))
        rejected = old_res[0] not in (0, 'timeout')
        failed += not rejected
        print(line('shape', 'rejected' if rejected else 'ACCEPTED', f'{label(r)} older', old, old_res[0], old_res[1], old_res[4], old_res[3]))
    return failed


def code_index(tree):
    return {f: os.path.join(dp, f) for top in ('bin', 'core') for dp, _, fs in os.walk(os.path.join(tree, top))
            for f in fs if f.endswith(('.sh', '.py'))}


def code_of(tree, files, script, cache):
    """The code (comments left out) of a script and of every bin/ or core/ file it names: exec, source or call."""
    if script not in cache:
        with open(os.path.join(tree, 'bin', script), errors='replace') as f:
            src = f.read()
        named = {n for n in re.findall(r'([\w.-]+\.(?:sh|py))\b', re.sub(r'^#.*$', '', src, flags=re.M)) if n in files and n != script}
        parts = []
        for p in [os.path.join(tree, 'bin', script)] + sorted(files[n] for n in named):
            with open(p, errors='replace') as f:
                parts.append(re.sub(r'^\s*#.*$', '', f.read(), flags=re.M))
        cache[script] = '\n'.join(parts)
    return cache[script]


def cmd_names(tree, rows, args):
    files, cache, failed, total = code_index(tree), {}, 0, 0
    for r in rows:
        body = code_of(tree, files, r['script'], cache)
        for opt in sorted(set(re.findall(r'(?<![\w-])(--[a-z][\w-]*)', r['form']))):
            total += 1
            if not re.search(r'(?<![\w-])' + re.escape(opt) + r'(?![\w-])', body):
                failed += 1
                print(f'name\tabsent\t{label(r)}\t{opt}\tnamed by the form, not in the code of {r["script"]} or a file it names')
    print(f'name\tsummary\trows {len(rows)}; options named {total}; absent from the code {failed}')
    return failed


def cmd_forms(tree, rows, args):
    for words, form in forms(os.path.join(tree, 'bin', args.script)):
        print(f'forms\t{" ".join(words) or "-"}\t{form}')
    return 0


def cmd_run(pool, rows, args):
    row = next((r for r in rows if r['script'] == args.script and r['operation'] == args.operation), None)
    if row is None:
        print(f'run\tno-row\t{args.script} {args.operation}', file=sys.stderr)
        return 1
    lab = pool.labs[0]
    argv, why = render(lab, row['form'], dict(s.split('=', 1) for s in args.set), row['script'])
    if argv is None:
        print(f'run\tnot-run\t{label(row)}\t\t{why}')
        return 1
    words = row['operation'].split(' ') if row['operation'] != '-' else []
    pos = argv.index(words[-1], 1) + 1 if words and words[-1] in argv[1:] else 1
    for extra in args.extra or [None]:
        run_argv = argv[:pos] + (extra.split() if extra else []) + argv[pos:]
        res = lab.run(run_argv)
        word, _ = verdict(*res)
        print(line('run', word, label(row), run_argv, res[0], res[1], res[4], res[3]))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('command', choices=['usage', 'options', 'get', 'parity', 'shapes', 'names', 'forms', 'run', 'all'])
    ap.add_argument('tree')
    ap.add_argument('operations')
    ap.add_argument('scratch')
    ap.add_argument('--only', action='append', default=[], help='a script name: run only its rows')
    ap.add_argument('--known', help='ledger of rows known to fail: mode<TAB>script<TAB>operation<TAB>reason per line')
    ap.add_argument('--jobs', type=int, default=min(4, os.cpu_count() or 1), help='labs run side by side')
    ap.add_argument('--script')
    ap.add_argument('--operation')
    ap.add_argument('--set', action='append', default=[])
    ap.add_argument('--extra', action='append')
    args = ap.parse_args(argv)
    rows = load_rows(args.operations)
    if args.only:
        rows = [r for r in rows if r['script'] in args.only]
    tree = os.path.abspath(args.tree)
    needs_lab = args.command not in ('forms', 'names')
    pool = Pool(tree, args.scratch, 1 if args.command == 'run' else args.jobs) if needs_lab else None
    commands = {'usage': cmd_usage, 'options': cmd_options, 'get': cmd_get, 'parity': cmd_parity, 'shapes': cmd_shapes, 'run': cmd_run}
    todo = ['usage', 'options', 'get', 'parity', 'shapes', 'names'] if args.command == 'all' else [args.command]
    failed = 0
    for c in todo:
        if c in ('names', 'forms'):
            failed += {'names': cmd_names, 'forms': cmd_forms}[c](pool.tree if pool else tree, rows, args)
        else:
            failed += commands[c](pool, rows, args)
        sys.stdout.flush()
    print(f'# parse check: {failed} failing line(s)')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())

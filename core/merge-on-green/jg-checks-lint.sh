#!/usr/bin/env python3
# Merge gate for worker claims (flow playbook R4, captain 5 Oct: artifacts, not claims).
# Usage: JG_HOME=<home> jg-checks-lint.sh <PR URL | local report file> <evidence folder>
#        then, after reading PASS, merge in a later separate call (bin/jg-pr-merge.sh).
# Needs under "## Checks": outcome:, repro:, proof:, evidence:. proof names a command or path; repro is
# not n/a on a fix PR; evidence files exist, are non-empty, are newer than the lane's first launch
# (data/<task>/ birth), and at least one has a hash no other PR used (or is named for this PR's head: a file name or subfolder in a shared stack folder holding the head sha, 7+ hex chars), and no two are identical. "evidence: not proven: <cause>"
# passes (file the proof gap as a task). How proof or repro is worded is never checked (owner, 1 Nov): no skill
# name, no "systematic-debugging" marker. Bot PRs pass. 1,000+ added non-generated lines
# are ADVICE only, never a refusal and never a FAIL row (owner, 1 Nov: "don't fail anything, let it go"): the run
# prints the size and says it is over the guidance, then checks the rest and exits on those rules alone
# (deletions, moved lines and a fork PR's merged-in upstream lines do not count;
# a cross-repo move names its source in the PR body: "moved-from: <owner>/<repo>@<ref> <dst-prefix>=<src-prefix>", same owner only).
# A file git resolves as a rename at 50% similarity or more (the pull-files API's renamed + previous_filename, or
# that body mapping) is counted as moved: its added lines are excused up to the lines it still shares with its
# previous content, and only the added lines past that budget stay new code (a 408-file import keeps its path rewrites).
# A PR over gh's 100-file view cap and over its 300-file diff cap is still measured: every page of the
# pull-files API counts the added lines, and the diff comes from the compare API (else a local checkout).
# An API or diff failure keeps the full count, so it can never turn a big PR into a PASS.
# A non-conforming evidence list (a stray comma, a name written twice, a path instead of a name, a doubled or
# missing evidence/ prefix) fails naming the exact line and the name to write instead.
# One gh call per run (plus one per 100 files past the 100-file view cap, the compare/upstream diffs and one or two per moved file). Each run appends a row to $JG_HOME/data/checks-gate.log, and the newest row for a head is
# that head's verdict (readers take the last row, never any older pass). A run for a task of this home also publishes its own verdict
# as the task's completion receipt (core/receipts/bin/jg-run-receipt.sh), so a lane that fixes its evidence and re-lints
# to PASS republishes PASS over its earlier FAIL for the same candidate with no hand-posted record; bin/jg-pr-merge.sh and
# jg-merge-local.sh read that receipt (bin/jg-dod-lib.sh jg_dod_receipt_accept), so a still-failing head keeps refusing. Rows are never removed.
import os, re, sys, json, time, hashlib, subprocess, tempfile
from collections import Counter

if len(sys.argv) < 3 or not os.environ.get('JG_HOME'):
    sys.exit('usage: JG_HOME=<home> jg-checks-lint.sh <PR URL | report file> <evidence folder>')
src, ev = sys.argv[1], sys.argv[2]
home = os.environ['JG_HOME']; LOG = f'{home}/data/checks-gate.log'; HASHES = f'{home}/data/checks-gate.hashes'
GEN = re.compile(r'(^|/)(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|Cargo\.lock|go\.sum|[^/]*\.lock)$'+ r'|(^|/)packages/accounts/src/pi/|(^|/)packages/accounts/src/routes\.json$|(^|/)vendor/|(^|/)dist/|(^|/)(LICENSE|LICENSES|NOTICE|COPYING)[^/]*$')  # third-party, legal text and committed build output (dist/) are not reviewable code

task, ROOT = '', os.path.dirname(os.path.dirname(os.path.realpath(__file__)))  # task is set below
def load_rules():
    """The thresholds and patterns of the merge gate: policy/gate/rules.json of the checkout that holds this lint
    (a source run), else of this home (the installed copy sits in the data directory, beside no policy tree)."""
    for base in (os.path.dirname(ROOT), home):
        try:
            return base, json.load(open(f'{base}/policy/gate/rules.json'))['rules']['checks_lint']
        except (OSError, ValueError, KeyError):
            continue
    sys.exit('checks-lint: policy/gate/rules.json not found beside this lint or in ' + home)
POLICY_BASE, RULES = load_rules()
SIZE_GUIDANCE = RULES['size_guidance']  # the size the policy advises on
def gh_api(*a):  # errors=replace: the move rule also fetches binary files, which must not crash the count
    return subprocess.run(['gh', 'api', *a], capture_output=True, text=True, errors='replace', timeout=60)

def all_files(nwo):
    """Every changed file of a PR whose gh-pr-view list (100 max) is full: paginated pull-files API, else None."""
    out, page = [], 1
    while True:
        r = gh_api(f'repos/{nwo[1]}/pulls/{nwo[2]}/files?per_page=100&page={page}')
        try:
            batch = json.loads(r.stdout) if r.returncode == 0 else None
        except ValueError:
            batch = None
        if not isinstance(batch, list):
            return None
        out += [{'path': f.get('path') or f.get('filename', ''), 'additions': f.get('additions', 0),
                 'status': f.get('status', ''), 'previous_filename': f.get('previous_filename')} for f in batch]
        if len(batch) < 100 or len(out) >= 3000:  # short page, or GitHub's own 3000-file cap
            return out
        page += 1

def diff_entries(diff):
    """Added and deleted non-generated lines per path of a unified diff; '' holds lines before any file header."""
    ents = {'': {'add': Counter(), 'rm': Counter(), 'whole': False}}
    cur, gen = ents[''], False
    for l in diff.splitlines():
        if l.startswith('+++ '):
            path = l[6:] if l.startswith('+++ b/') else l[4:]
            gen = bool(GEN.search(path))
            cur = ents.setdefault(path, {'add': Counter(), 'rm': Counter(), 'whole': False})
        elif gen or l.startswith('--- '):
            continue
        elif l.startswith('@@'):
            cur['whole'] = cur['whole'] or l.startswith('@@ -0,0 ')  # whole file added: the new content is right here
        elif len(l) > 1 and l[0] in '+-' and l[1:].strip():
            cur['add' if l[0] == '+' else 'rm'][l[1:].strip()] += 1
    return ents

def net(ents):  # added minus deleted non-generated lines of a parsed diff
    add, rm = Counter(), Counter()
    for e in ents.values():
        add += e['add']; rm += e['rm']
    return add - rm

def contents(repo, path, ref):
    """One file's text, or '' when the API cannot serve it (a binary sibling must not crash the count)."""
    r = gh_api('-H', 'Accept: application/vnd.github.raw', f'repos/{repo}/contents/{path}?ref={ref}')
    return r.stdout if r.returncode == 0 else ''

def moved_pairs(nwo, files, body, base, head):
    """Files git resolves as renames: path -> (repo, previous path, previous ref, new ref). Same owner only."""
    if not nwo:
        return {}
    mv = re.search(r'^\s*moved-from\s*:\s*([\w.-]+)/([\w.-]+)@(\S+)\s+(.+)$', body, re.M)
    rules = [r.split('=', 1) for r in mv[4].split() if '=' in r] if mv and mv[1] == nwo[1].split('/')[0] else []
    named = files if any('status' in f for f in files) else (all_files(nwo) or [])  # gh pr view carries no rename
    pairs = {}
    for f in named:
        p = f.get('path') or ''
        if not p or GEN.search(p):
            continue
        if f.get('status') == 'renamed' and f.get('previous_filename'):  # same repo: git already says it is a move
            pairs[p] = (nwo[1], f['previous_filename'], base, head)
        else:
            for dst, sp in rules:  # cross-repo move: the body names the source file
                if p.startswith(dst):
                    pairs[p] = (f'{mv[1]}/{mv[2]}', sp + p[len(dst):], mv[3], head)
                    break
    return pairs

def cancel_moved(n, ents, pairs):
    """A moved file's added lines are moved, not new code: cancel up to the lines it still shares with its
    previous content (the similarity budget) and keep counting whatever the rewrite added past that budget."""
    for path, (repo, prev, ref, newref) in pairs.items():
        e = ents.get(path) or {}
        if not e.get('add'):
            continue
        old = Counter(l.strip() for l in contents(repo, prev, ref).splitlines() if l.strip())
        new = e['add'] if e['whole'] else Counter(l.strip() for l in contents(repo, path, newref).splitlines() if l.strip())
        matched = sum((old & new).values())
        if not matched or 100 * matched // max(sum(old.values()), sum(new.values())) < 50:
            continue  # no previous content, or below the 50% rename threshold: this is a rewrite, not a move
        budget = matched
        for line, c in e['add'].items():
            take = min(n.get(line, 0), c, budget)
            n[line] -= take; budget -= take
    return n

def pr_diff(nwo, base, head, dirs):
    """Whole-PR diff: compare API (gh pr diff refuses above 300 files), else a checkout holding both commits."""
    if nwo and base and head not in ('', '-'):
        r = gh_api('-H', 'Accept: application/vnd.github.diff', f'repos/{nwo[1]}/compare/{base}...{head}')
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout
        for d in dirs:
            g = subprocess.run(['git', '-C', d, 'diff', '--no-color', f'{base}...{head}'], capture_output=True, text=True, timeout=120)
            if g.returncode == 0 and g.stdout.strip():
                return g.stdout
    return ''

def lane_task(home, src, ev, fallback=''):
    """Lane id from state/<task>.meta (pr=) or $JG_HOME/data/<task>, not the PR branch name."""
    if isinstance(src, str) and src.startswith('http') and os.path.isdir(f'{home}/state'):
        for name in sorted(os.listdir(f'{home}/state')):
            if not name.endswith('.meta'):
                continue
            try:
                for line in open(f'{home}/state/{name}', errors='replace'):
                    if line.startswith('pr=') and line[3:].strip() == src:
                        return name[:-5]
            except OSError:
                continue
    try:
        ev_abs, data = os.path.abspath(ev), os.path.abspath(f'{home}/data')
    except OSError:
        return fallback
    if ev_abs.startswith(data + os.sep):
        rel = ev_abs[len(data) + 1:]
        if rel and os.sep not in rel:
            return rel
    return fallback

def publish(ok, why):
    """Publish this run's verdict as the task's completion receipt, so the merge path reads the newest verdict
    (header): a PASS overwrites the earlier FAIL for the same candidate, and a standing PASS for that same
    candidate keeps its fuller evidence rather than being replaced by this one line."""
    meta = f'{home}/state/{task}.meta'
    if not task or not os.path.isfile(meta):
        return
    wt = ([l[9:].strip() for l in open(meta) if l.startswith('worktree=')] or [''])[-1]
    repo = wt if os.path.isdir(wt) else home
    try:
        cand = subprocess.run(['git', '-C', repo, 'rev-parse', '--verify', 'HEAD^{commit}'], capture_output=True, text=True, timeout=60).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        cand = ''
    prior = None
    if ok:  # a standing PASS for this same candidate keeps its fuller evidence; a FAIL is superseded
        try:
            prior = json.load(open(f'{home}/state/{task}.run-receipt.json'))
        except (OSError, ValueError):
            prior = None
        if isinstance(prior, dict) and cand and prior.get('verdict') == 'PASS' and prior.get('head') == cand:
            print('checks-lint: receipt: this candidate already holds a PASS receipt')
            return
    with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False) as t:
        t.write(f'checks-lint {"PASS" if ok else "FAIL"} {src} head {head}: {why}\n')
    # The receipt must name the pull request this run judged; passing it is more reliable than the publisher's own
    # lookup, which cannot resolve a branch from a detached candidate tree.
    penv = {**os.environ, 'JG_HOME': home}
    if re.match(r'https?://', src):
        penv['JG_RECEIPT_PR'] = src
    try:
        r = subprocess.run([next((c for c in (f"{os.environ.get('JG_CORE_DIR') or ROOT}/receipts/bin/jg-run-receipt.sh", f"{home}/core/receipts/bin/jg-run-receipt.sh") if os.access(c, os.X_OK)), f"{ROOT}/receipts/bin/jg-run-receipt.sh"), task, 'PASS' if ok else 'FAIL', t.name, repo],
                           env=penv, capture_output=True, text=True, timeout=60)
        if r.returncode == 0:
            superseded = isinstance(prior, dict) and prior.get('verdict') == 'FAIL'
            print('checks-lint: receipt PASS published' + (', superseding the earlier FAIL receipt' if superseded else '')
                  if ok else 'checks-lint: receipt FAIL published: the merge is refused until a newer PASS receipt')
        else:
            print(f'checks-lint: receipt not {"published" if ok else "revoked"}: ' + (r.stderr.strip() or '?')[-200:])
    except subprocess.TimeoutExpired:
        print('checks-lint: receipt not ' + ('published' if ok else 'revoked') + ': jg-run-receipt.sh timed out')
    finally:
        os.unlink(t.name)


def done(ok, why, head='-'):
    with open(LOG, 'a') as f:
        f.write(f'{time.strftime("%FT%TZ", time.gmtime())}\t{src}\t{head}\t{"pass" if ok else "fail"}\t{why}\n')
    print(f'checks-lint: {"PASS" if ok else "FAIL"}: {why}')
    publish(ok, why)
    sys.exit(0 if ok else 1)

size = 0
if os.path.isfile(src):  # local-only lane: the report file its done line names
    body, title, head, task, author, files = open(src, errors='replace').read(), '', '-', os.path.basename(os.path.dirname(os.path.abspath(src))), '', []
    task = lane_task(home, src, ev, task)
else:
    r = subprocess.run(['gh', 'pr', 'view', src, '--json', 'author,body,title,files,headRefOid,headRefName,baseRefOid'],
                       capture_output=True, text=True, timeout=60)
    if r.returncode: done(False, 'gh pr view failed: ' + (r.stderr.strip().splitlines() or ['?'])[-1][:160])
    pr = json.loads(r.stdout)
    body, title, head = pr.get('body') or '', pr.get('title') or '', pr.get('headRefOid', '-')
    author, files = (pr.get('author') or {}).get('login', ''), pr.get('files') or []
    task = lane_task(home, src, ev, pr.get('headRefName', '').rsplit('/', 1)[-1])
    nwo = re.match(r'https://github\.com/([^/]+/[^/]+)/pull/(\d+)', src)
    if nwo and len(files) >= 100:  # view list is capped at 100, so a bigger PR needs every page (Juggernaut PR 133: 408 files)
        files = all_files(nwo) or files
    # Added lines only: deletions are cheap to review and 'delete before you add' must not be penalised.
    size = sum(f.get('additions', 0) for f in files if not GEN.search(f.get('path', '')))
    if size >= SIZE_GUIDANCE:  # moved lines are not new code (7 Oct, PR 18 helper move): an added line that matches a deleted one cancels
        meta = f'{home}/state/{task}.meta'
        wt = ([l[9:].strip() for l in open(meta) if l.startswith('worktree=')] or [''])[-1] if task and os.path.isfile(meta) else ''
        diff = pr_diff(nwo, pr.get('baseRefOid'), head, [d for d in (wt, os.getcwd()) if os.path.isdir(d)])
        if diff:  # no diff from any source keeps the full count: a failure never lowers it
            ents = diff_entries(diff)
            n = net(ents); size = sum(n.values())
            # Upstream catch-up (15 Oct, fork PR 74): lines the fork's parent repo already shipped are not authored
            # here, so subtract the upstream delta the PR merges in (PR base ... merged upstream tip). A plain fork PR
            # merges no new upstream commit, so its delta is empty. Any API failure keeps the full count.
            p = gh_api(f'repos/{nwo[1]}', '--jq', '.parent | select(.) | .owner.login + ":" + .default_branch') if size >= SIZE_GUIDANCE and nwo else None
            u = gh_api(f'repos/{nwo[1]}/compare/{p.stdout.strip()}...{head}', '--jq', '.merge_base_commit.sha') if p and p.returncode == 0 and p.stdout.strip() else None
            dl = gh_api('-H', 'Accept: application/vnd.github.diff', f'repos/{nwo[1]}/compare/{pr.get("baseRefOid")}...{u.stdout.strip()}') if u and u.returncode == 0 and u.stdout.strip() else None
            if dl and dl.returncode == 0: n -= net(diff_entries(dl.stdout)); size = sum(n.values())
            # Moved files (cross-repo move 16 Oct, features PR 9; rename with rewrites): cancel only the added lines
            # of the moved file itself, up to its similarity budget, so a path rewrite rides along with its file
            # and every authored line still counts.
            pairs = moved_pairs(nwo, files, body, pr.get('baseRefOid'), head) if size >= SIZE_GUIDANCE else {}
            if pairs: size = sum(cancel_moved(n, ents, pairs).values())

m = ([None] + list(re.finditer(r'^##\s*Checks\s*$(.*?)(?=^##\s|\Z)', body, re.M | re.S)))[-1]  # newest block: workers append, never replace
checks = None
if m:
    block = re.sub(r'```\w*', '', m.group(1))
    keys = '|'.join(RULES['required_fields'])
    checks = {'fields': {k: v.strip() for k, v in re.findall(rf'^\s*({keys})\s*:\s*(.*)$', block, re.M)}}

def ev_fix(n, p):
    """What to write instead of one evidence name that did not resolve: the evidence list takes names relative
    to the evidence folder, so a path, a doubled or missing evidence/ prefix is the slip."""
    base = os.path.basename(n)
    if n.startswith('evidence/'):
        rest = n[len('evidence/'):]
        tries = [(rest, f'drop the duplicated "evidence/" prefix and write {rest}')]
    else:
        tries = [('evidence/' + n, f'the file sits under evidence/, so write evidence/{n}')]
        if base != n:
            tries.append((base, f'write just its name in the evidence folder: {base}'))
    for cand, fix in tries:
        alt = os.path.join(ev, cand)
        if os.path.isfile(alt) and os.path.getsize(alt):
            return fix
    return f'write each name relative to the evidence folder {ev}'

# The facts of the evidence line: each word, and for each file name its path, whether it is there and non-empty,
# whether it predates the lane, its hash, and whether another pull request had not used it first.
toks = [n.strip(' `"\'') for n in re.split(r'[,\s]+', checks['fields'].get('evidence', ''))] if checks and checks['fields'].get('evidence') else []
born = 0
if os.path.isdir(f'{home}/data/{task}'):
    out = subprocess.run(['stat', '-c', '%W', f'{home}/data/{task}'], capture_output=True, text=True).stdout.strip()
    born = int(out) if out.isdigit() else 0
seen = {}
if os.path.exists(HASHES):
    for l in open(HASHES):
        p = l.split()
        if len(p) == 2: seen[p[0]] = p[1]
efiles = {}
for n in toks:
    if not n or not re.search(RULES['evidence_name_pattern'], n):
        continue
    p = n if os.path.isabs(n) else os.path.join(ev, n)
    present = os.path.isfile(p) and os.path.getsize(p) > 0
    hsh = hashlib.sha256(open(p, 'rb').read()).hexdigest() if present else ''
    o = seen.get(hsh)  # same task's earlier lint (local body or PR) is not reuse
    # A stack's shared evidence folder holds one proof per head: a file named for this PR's head, or inside a
    # subfolder named for it, belongs to this head even when a sibling PR's lint hashed it first. A file named
    # for another head is not this head's proof, so it keeps the ordinary reuse rule.
    rel = os.path.relpath(p, ev) if os.path.abspath(p).startswith(os.path.abspath(ev) + os.sep) else n
    own_head = head not in ('', '-') and any(head.startswith(h) for h in re.findall(r'(?<![0-9a-f])[0-9a-f]{7,40}(?![0-9a-f])', rel))
    efiles[n] = {'path': p, 'present': present, 'older': bool(present and born and os.path.getmtime(p) < born),
                 'sha256': hsh, 'fresh': present and (own_head or o is None or o in (src, task) or bool(task and f'/{task}/' in o)),
                 'fix': '' if present else ev_fix(n, p)}
facts = {'author': author, 'title': title, 'size': {'added': size},
         'checks': checks, 'evidence': {'folder': ev, 'tokens': toks, 'files': efiles}}
# The Rego rule decides. A gate that cannot be evaluated refuses: it never looks like a pass.
evaluator = os.environ.get('JG_POLICY_EVAL') or f'{POLICY_BASE}/bin/jg-guard-host.sh'
try:
    r = subprocess.run([evaluator, 'eval', 'gate.checks_lint'], input=json.dumps(facts), capture_output=True, text=True,
                       timeout=120, env={**os.environ, 'JG_GUARD_HOST_ROOT': POLICY_BASE})
    decision = json.loads(r.stdout) if r.returncode == 0 else None
except (OSError, ValueError, subprocess.SubprocessError):
    r, decision = None, None
if not isinstance(decision, dict):
    detail = ((r.stderr.strip().splitlines() or ['?'])[-1] if r else 'the evaluator did not run')[:200]
    done(False, f'the merge-gate policy could not be evaluated ({detail}); install OPA and Go, then run this again', head)
for line in decision.get('advice', []):
    print(f'checks-lint: {line}')
if decision['ok'] and decision['kind'] == 'evidence':
    with open(HASHES, 'a') as f:
        for n in toks:
            h = efiles.get(n, {}).get('sha256')
            if h and h not in seen: f.write(f'{h} {task or src}\n')
done(decision['ok'], decision['why'], head)

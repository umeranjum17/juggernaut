#!/usr/bin/env python3
"""Score the standards pack on the two fixture projects from the linters' JSON output: per rule, did its fault file (an
ordinary project path) raise the expected rule id, and did its allowed file stay clean? Extra diagnostics are listed,
never counted as catches.

Usage: score.py <raw-dir> [--check]
  <raw-dir> holds {a,b}-eslint.json and a-eslint-noresolver.json (the gate), and may hold {a,b}-biome.json,
  {a,b}-biome-project.json and {a,b}-oxlint.json (the speed-option comparison in README.md).
  --check prints 'faults 10/10, allowed 8/8, inert check ok' and exits 0 only when the ESLint preset catches every
  fault, keeps every allowed use clean, and the no-resolver control misses the folder rule (R6a and R6b) and nothing else.
Ported from lint-lab-4-score.py (sha b04f56b16427)."""
import collections
import json
import os
import sys

P = 'src/features/profile/'
# (project, file) -> (rule, eslint id, biome rule, oxlint fragment)
EXPECT = {
    ('a', P + 'load-raw.ts'): ('R1 raw fetch outside the api client', 'no-restricted-globals', 'noRestrictedGlobals', 'no-restricted-globals'),
    ('a', P + 'load-window.ts'): ('R1b window.fetch outside the api client', 'no-restricted-properties', 'NONE', 'NONE'),
    ('b', P + 'ping.tsx'): ('R2 useEffect import (opt-in ban)', 'no-restricted-imports', 'noRestrictedImports', 'no-restricted-imports'),
    ('b', P + 'tick.tsx'): ('R2b React.useEffect through the namespace (opt-in ban)', 'no-restricted-syntax', 'NONE', 'NONE'),
    ('a', P + 'full-name.tsx'): ('R3 derived state in an effect', 'react-you-might-not-need-an-effect/no-derived-state', 'NONE', 'NONE'),
    ('a', P + 'size.ts'): ('R4 explicit any', '@typescript-eslint/no-explicit-any', 'noExplicitAny', 'no-explicit-any'),
    ('a', P + 'start.ts'): ('R5 floating promise', '@typescript-eslint/no-floating-promises', 'noFloatingPromises', 'no-floating-promises'),
    ('a', P + 'title.ts'): ('R6a features import app', 'import-x/no-restricted-paths', 'NONE', 'no-restricted-paths'),
    ('a', 'src/shared/format-title.ts'): ('R6b shared imports features', 'import-x/no-restricted-paths', 'NONE', 'no-restricted-paths'),
    ('a', P + 'clock-now.tsx'): ('R7 setState directly in an effect', 'react-hooks/set-state-in-effect', 'NONE', 'set-state-in-effect'),
}
ALLOWED = [('a', 'src/shared/api/client.ts'), ('b', P + 'count.tsx'), ('a', P + 'greeting.tsx'), ('a', P + 'safe-size.ts'),
           ('a', P + 'start-awaited.ts'), ('a', P + 'loader.ts'), ('a', P + 'clock.tsx'), ('a', 'src/app/config.ts')]
TOOLS = {  # tool -> (raw files for project a and b, column of EXPECT holding its rule id)
    'eslint': (('a-eslint.json', 'b-eslint.json'), 1),
    'eslint-no-resolver': (('a-eslint-noresolver.json', None), 1),
    'biome': (('a-biome.json', 'b-biome.json'), 2),
    'biome-project-domain': (('a-biome-project.json', 'b-biome-project.json'), 2),
    'oxlint': (('a-oxlint.json', 'b-oxlint.json'), 3),
}


def rel(p):
    p = p or '?'
    for marker in ('/project-a/', '/project-b/'):
        if marker in p:
            return p.split(marker, 1)[1]
    return p.lstrip('./')


def load(raw, name):
    try:
        with open(os.path.join(raw, name), encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        return {'error': str(e)}


def diagnostics(tool, proj, raw, name):
    """-> {(project, file): [rule id, ...]}; a missing or unreadable raw file raises, so a broken run is never a pass."""
    out = collections.defaultdict(list)
    d = load(raw, name)
    if isinstance(d, dict) and 'error' in d:
        raise SystemExit(f'score.py: cannot read {name}: {d["error"]}')
    if tool.startswith('eslint'):
        for f in d:
            for m in f['messages']:
                out[(proj, rel(f['filePath']))].append(m.get('ruleId') or 'parse')
    elif tool.startswith('biome'):
        for x in d.get('diagnostics', []):
            path = (x.get('location') or {}).get('path') or {}
            out[(proj, rel(path.get('file') if isinstance(path, dict) else path))].append(x.get('category') or '?')
    else:
        for x in d.get('diagnostics', []):
            out[(proj, rel(x.get('filename')))].append(x.get('code') or '?')
    return out


def collect(raw):
    res = {}
    for tool, ((fa, fb), _) in TOOLS.items():
        if not os.path.exists(os.path.join(raw, fa)):
            continue
        r = diagnostics(tool, 'a', raw, fa)
        if fb:
            r.update(diagnostics(tool, 'b', raw, fb))
        res[tool] = r
    return res


def score(tool, r):
    """-> (caught, expected, clean, allowed, missed rule ids, extra diagnostics, noise on allowed files)."""
    col = TOOLS[tool][1]
    only_a = tool == 'eslint-no-resolver'
    expect = {k: v for k, v in EXPECT.items() if not only_a or k[0] == 'a'}
    allowed = [k for k in ALLOWED if not only_a or k[0] == 'a']
    caught, missed, extra = 0, [], []
    for k, exp in expect.items():
        want, got = exp[col], r.get(k, [])
        hit = want != 'NONE' and any(want in g for g in got)
        caught += hit
        if not hit:
            missed.append(exp[0].split()[0])
        extra += [g for g in got if not (want != 'NONE' and want in g)]
    noise = [f'{os.path.basename(k[1])}: {", ".join(r[k])}' for k in allowed if r.get(k)]
    return caught, len(expect), len(allowed) - len(noise), len(allowed), missed, extra, noise


def main(argv):
    args = [a for a in argv if not a.startswith('--')]
    if len(args) != 1:
        raise SystemExit(__doc__)
    res = collect(args[0])
    if 'eslint' not in res or 'eslint-no-resolver' not in res:
        raise SystemExit('score.py: the ESLint raw files are missing from ' + args[0])
    print('# raw diagnostics per file (project a = base preset, project b = base preset + useEffect ban)')
    for tool, r in res.items():
        for k in sorted(set(EXPECT) | set(ALLOWED) | set(r)):
            if r.get(k):
                print(f'{tool}\t{k[0]}:{k[1]}\t{", ".join(r[k])}')
    print('# scores')
    print('linter\tfaults caught\tallowed uses clean\tmissed rules\textra diagnostics on fault files\tnoise on allowed files')
    table = {tool: score(tool, r) for tool, r in res.items()}
    for tool, (caught, n, clean, na, missed, extra, noise) in table.items():
        print(f'{tool}\t{caught}/{n}\t{clean}/{na}\t{" ".join(missed) or "-"}\t'
              f'{len(extra)}: {", ".join(sorted(set(extra))) or "-"}\t{"; ".join(noise) or "-"}')
    if '--check' not in argv:
        return 0
    caught, n, clean, na, _, _, _ = table['eslint']
    c_caught, c_n, c_clean, c_na, c_missed, _, _ = table['eslint-no-resolver']
    inert = sorted(c_missed) == ['R6a', 'R6b'] and c_caught == c_n - 2 and c_clean == c_na
    print(f'faults {caught}/{n}, allowed {clean}/{na}, inert check {"ok" if inert else "FAILED"}')
    return 0 if (caught, clean) == (n, na) and inert else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

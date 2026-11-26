#!/usr/bin/env bash
# Integration coverage for the outside-channel command contract.
set -eu
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
fragment=$root/core/agent-cli/contract/e6relay1.json
[ -s "$fragment" ] || { echo 'missing e6relay1 contract' >&2; exit 1; }
python3 -I - "$root" "$fragment" <<'PY'
import csv, json, sys
root, fragment = sys.argv[1:]
with open(root + '/core/agent-cli/operations.tsv') as f:
    rows = [r for r in csv.DictReader(f, delimiter='\t') if r['owner'] == 'e6relay1']
with open(fragment) as f:
    contract = json.load(f)
assert len(rows) == 33
assert contract['owner'] == 'e6relay1'
entries = {(e['script'].removeprefix('bin/'), e['operation']): e for e in contract['entries']}
assert len(entries) == len(rows)
for r in rows:
    e = entries[(r['script'], r['operation'])]
    assert e['form'] == r['form'], r
    assert e['path'] == r['path'].split(), r
    assert e['method'] == r['method'], r
    assert e['aliases'] == ([] if r['aliases'] == '-' else r['aliases'].split(',')), r
PY
bash "$root/core/agent-cli/dispatch.sh" check
help=$(bash "$root/core/agent-cli/dispatch.sh" help)
while IFS= read -r path; do
  [[ "$help" == *"jg $path - "* ]] || { echo "missing help: $path" >&2; exit 1; }
done < <(jq -r '.entries[].path | join(" ")' "$fragment")
echo 'e6relay1 contract inventory and help: passed'
# Use the inventory's isolated homes, fixture arguments, and external-command stand-ins.
# Polls and source commands are checked for argument binding only: they can block or contact another machine.
python3 -I - "$root" <<'PY'
import hashlib, importlib.util, json, os, shutil, subprocess, sys, tempfile
root = sys.argv[1]
spec = importlib.util.spec_from_file_location('parser', root + '/core/agent-cli/inventory/parse.py')
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
contract = json.load(open(root + '/core/agent-cli/contract/e6relay1.json'))
tmp = tempfile.mkdtemp(prefix='e6relay1-', dir=os.environ.get('TMPDIR'))
try:
    lab = p.Lab(root, tmp + '/lab')
    lab.env['JG_CONTRIBUTIONS_NOW'] = '2026-01-01T00:00:00Z'
    def files():
        found = {}
        for dirname in ('config', 'state', 'data'):
            for base, dirs, names in os.walk(os.path.join(lab.home, dirname)):
                dirs.sort()
                for name in sorted(names):
                    path = os.path.join(base, name)
                    with open(path, 'rb') as f:
                        found[os.path.relpath(path, lab.home)] = hashlib.sha256(f.read()).hexdigest()
        return found
    for entry in contract['entries']:
        op = entry['operation']; script = entry['script']
        argv, why = p.render(lab, entry['form'], script=os.path.basename(script))
        assert not why, (entry['form'], why)
        for group in p.optional_groups(entry['form']):
            option_argv, why = p.render(lab, entry['form'], script=os.path.basename(script), keep=group)
            assert not why, (entry['form'], group, why)
            option_run = lab.run(option_argv)
            assert not p.PARSE_ERROR.search(option_run[2]), (entry['form'], group, option_run[2])
        # Operations which can run a worker, wait for one, or access a remote endpoint:
        # test binding with deliberately incomplete arguments, never execute the action.
        dangerous = op in ('arm', 'poll', 'source', 'retire') and not (script.endswith('contributions.sh') and op == 'retire')
        locked = op in ('arm-locked', 'retire-quiesce-locked', 'retire-finalize-locked')
        if dangerous or locked:
            # Dispatcher's unknown option refusal proves the route and parser without starting the action.
            rc, _, text, _, _ = lab.run(['bin/jg'] + entry['path'] + ['--invalid-fixture-option'])
            assert rc == 2 and 'unknown option' in text, (entry['form'], rc, text)
            continue
        direct = lab.run(argv)
        direct_files = files()
        args = argv[2:]
        if script.endswith('jg-contributions.sh') and op == 'retire':
            args = args[:2] + args[3:]  # captain is a literal supplied by the dispatcher
        routed = lab.run(['bin/jg'] + entry['path'] + args)
        routed_files = files()
        expected = entry['exits'].get(str(direct[0]), 0 if direct[0] == 0 else 1)
        assert routed[0] == expected, (entry['form'], direct[:3], routed[:3])
        assert routed_files == direct_files, (entry['form'], direct_files, routed_files)
        assert routed[4] == direct[4], (entry['form'], direct[4], routed[4])
        assert 'usage:' not in direct[2].lower(), (entry['form'], direct[2])
    # These actions require their direct parent to own the lock; the dispatcher adds a process.
    # Prove the real script with a shell that owns the fixture lock, as directed by the lead.
    for op in ('arm-locked', 'retire-quiesce-locked', 'retire-finalize-locked'):
        lab.reset()
        lock = os.path.join(lab.home, 'state', '.remote-reply-lifecycle-jg-none.lock')
        os.mkdir(lock)
        with open(os.path.join(lock, 'pid'), 'w') as f:
            f.write('999999999\n')
        refused = subprocess.run([lab.tree + '/bin/jg-procevent-remote-reply.sh', op, 'jg-none'],
                                 env=lab.env, cwd=lab.run_dir, capture_output=True, text=True, timeout=15)
        assert refused.returncode != 0 and 'lock is not held by the caller' in refused.stderr, (op, refused.stderr)
        lab.reset()
        command = r'''mkdir -p "$JG_STATE_OVERRIDE/.remote-reply-lifecycle-jg-none.lock"
printf '%s\n' "$$" > "$JG_STATE_OVERRIDE/.remote-reply-lifecycle-jg-none.lock/pid"
"$1" "$2" jg-none
result=$?
exit "$result"'''
        result = subprocess.run(['bash', '-c', command, 'fixture', lab.tree + '/bin/jg-procevent-remote-reply.sh', op],
                                env=lab.env, cwd=lab.run_dir, capture_output=True, text=True, timeout=15)
        assert 'lock is not held by the caller' not in result.stderr, (op, result.stderr)
        if op != 'arm-locked':
            assert result.returncode == 0, (op, result.stderr)
    print('e6relay1 isolated command parity and direct locked actions: passed')
finally:
    shutil.rmtree(tmp)
PY

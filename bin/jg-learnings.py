#!/usr/bin/env python3
"""Per-home Beads learning document; no file fallback or editable rendered view.

Usage: JG_HOME=<home> python3 bin/jg-learnings.py read|sha|measure
       ... write <expected-sha256> <UTF8-file>
       ... backup <external-backup-dir>
       ... restore <external-backup-dir> <new-store>/.beads
Dormant storage API: no existing consumer uses it until the guarded migration lands.
The whole document occupies one pinned, versioned row, preserving every byte,
including preamble, duplicate titles, markers and a final non-newline tail.
Writes require the hash of the document read; stale edits are refused.
Restore never selects or overwrites a store; Main selects the proved replacement.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
LABEL = 'juggernaut-learning'


def bd(*args, store=None, body=None):
    p = subprocess.run([str(HERE / 'jg-beads.sh'), *map(str, args)], input=body,
                       capture_output=True, env={**os.environ, 'BEADS_DIR': str(store or STORE)})
    if p.returncode:
        raise ValueError(p.stderr.decode() or p.stdout.decode())
    return p.stdout


def sha(body):
    return hashlib.sha256(body).hexdigest()


def put(path, value):
    tmp = path.with_name(path.name + '.new')
    with tmp.open('w') as out:
        json.dump(value, out); out.flush(); os.fsync(out.fileno())
    os.replace(tmp, path)


def read(pointer=None, store=None):
    pointer = pointer or json.loads(POINTER.read_text())
    row = json.loads(bd('show', pointer['id'], '--json', store=store))[0]
    if row.get('metadata', {}).get('learning_home') != str(HOME) or LABEL not in row.get('labels', []):
        raise ValueError('learning row owner or label mismatch')
    if row['status'] != 'pinned':
        raise ValueError('learning row is not pinned')
    return (row.get('description') or '').encode('utf8')


def backup(path, pointer):
    path = Path(path).resolve()
    parent = STORE.parent.resolve()
    if path.is_relative_to(parent) or parent.is_relative_to(path):
        raise ValueError('backup must be outside the store parent')
    body = read(pointer)
    bd('backup', 'init', path)
    bd('backup', 'sync')
    put(path / 'learning-manifest.json', dict(pointer, home=str(HOME), sha256=sha(body)))


def main():
    global HOME, STORE, POINTER
    HOME = Path(os.environ['JG_HOME']).resolve()
    config = Path(os.environ.get('JG_CONFIG_OVERRIDE', HOME / 'config'))
    STORE = Path((config / 'beads-dir').read_text().strip())
    if not STORE.is_absolute() or STORE.name != '.beads':
        raise ValueError('config/beads-dir must name an absolute .beads store')
    POINTER = config / 'learnings-beads'
    cmd, *args = sys.argv[1:]
    # Every accepted read and edit shares the store's own serialization boundary.
    with (STORE.parent / '.learning.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if cmd == 'restore':
            path, target = map(lambda p: Path(p).resolve(), args)
            if target.exists() or not target.parent.is_dir() or any(target.parent.iterdir()):
                raise ValueError('restore needs a new store in an empty existing parent')
            manifest = json.loads((path / 'learning-manifest.json').read_text())
            if manifest['home'] != str(HOME):
                raise ValueError('backup belongs to a different home')
            bd('init', '--prefix', 'jg', store=target)
            bd('backup', 'restore', path, '--force', store=target)
            bd('check', store=target)
            if sha(read(manifest, target)) != manifest['sha256']:
                raise ValueError('restored learning bytes do not match backup')
            print('Restored and verified; active store unchanged'); return
        body = read()
        if cmd == 'read':
            sys.stdout.buffer.write(body)
        elif cmd == 'sha':
            print(sha(body))
        elif cmd == 'measure':
            print(len(body))
        elif cmd == 'write':
            expected, source = args
            if sha(body) != expected:
                raise ValueError('stale learning edit; read and reconcile before writing')
            new = Path(source).read_bytes(); new.decode('utf8')
            pointer = json.loads(POINTER.read_text())
            bd('update', pointer['id'], '--if-status', 'pinned', '--body-file', '-',
               '--allow-empty-description', body=new)
            if read() != new:
                raise ValueError('learning write readback differs')
        elif cmd == 'backup':
            backup(args[0], json.loads(POINTER.read_text()))
        else:
            raise ValueError('unknown learning command: ' + cmd)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, IndexError, TypeError) as error:
        print(f'jg-learnings: {error}', file=sys.stderr)
        sys.exit(2)

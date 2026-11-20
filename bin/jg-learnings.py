#!/usr/bin/env python3
"""Per-home learning document in the tickets tables; no file fallback or editable rendered view.

Usage: JG_HOME=<home> python3 bin/jg-learnings.py read|sha|measure
       ... write <expected-sha256> <UTF8-file>
Dormant storage API: no existing consumer uses it until the guarded migration lands.
The whole document occupies one pinned, versioned row, preserving every byte,
including preamble, duplicate titles, markers and a final non-newline tail.
Writes require the hash of the document read; stale edits are refused.
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


def bd(*args, body=None):
    p = subprocess.run(['python3', '-I', str(HERE.parent / 'core/item-store/adapters/bd_compat.py'), *map(str, args)], input=body,
                       capture_output=True, env={**os.environ, 'JG_HOME': str(HOME)})
    if p.returncode:
        raise ValueError(p.stderr.decode() or p.stdout.decode())
    return p.stdout


def sha(body):
    return hashlib.sha256(body).hexdigest()


def read(pointer=None):
    pointer = pointer or json.loads(POINTER.read_text())
    row = json.loads(bd('show', pointer['id'], '--json'))[0]
    if row.get('metadata', {}).get('learning_home') != str(HOME) or LABEL not in row.get('labels', []):
        raise ValueError('learning row owner or label mismatch')
    if row['status'] != 'pinned':
        raise ValueError('learning row is not pinned')
    return (row.get('description') or '').encode('utf8')


def main():
    global HOME, POINTER
    HOME = Path(os.environ['JG_HOME']).resolve()
    config = Path(os.environ.get('JG_CONFIG_OVERRIDE', HOME / 'config'))
    POINTER = config / 'learnings-beads'
    cmd, *args = sys.argv[1:]
    # Every accepted read and edit shares one serialization boundary: the home's state folder.
    with (HOME / 'state' / '.learning.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
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
        else:
            raise ValueError('unknown learning command: ' + cmd)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, IndexError, TypeError) as error:
        print(f'jg-learnings: {error}', file=sys.stderr)
        sys.exit(2)

#!/usr/bin/env bash
# Migrate the explicitly supported legacy fields in one Juggernaut home.
set -euo pipefail
exec python3 - "$@" <<'PY'
import argparse
import os
import pathlib
import re
import shutil
import sys
import tarfile
import tempfile

# Each rule names one record path and one field. Unlisted legacy data is unknown.
RULES = (
    (re.compile(r"state/model-gate\.check-trust"), re.compile(rb"^fm-custom-check-v1$", re.M), b"jg-custom-check-v1"),
    (re.compile(r"config/crew"), re.compile(rb"^(FM_MODEL=)([^\r\n]*)$", re.M), rb"JG_MODEL=\2"),
    (re.compile(r"state/[^/]+\.status"), re.compile(rb"^fm-open-decision:" , re.M), b"jg-open-decision:"),
    (re.compile(r"data/records"), re.compile(rb"^projects/firstmate-addons$", re.M), b"projects/juggernaut-addons"),
    # The shared captain-preference header phrases the inheritance check requires.
    (re.compile(r"data/captain-shared\.md"), re.compile(rb"read-only in secondmate homes"), b"read-only in squad_lead homes"),
    (re.compile(r"data/captain-shared\.md"), re.compile(rb"main firstmate"), b"main juggernaut"),
)
# Renames: the lead-home markers (with the parent marker's schema line) and the per-lead pin directories.
MARKERS = ((".fm-secondmate-home", ".jg-squad-lead-home"), (".fm-secondmate-parent", ".jg-squad-lead-parent"))
MARKER_SCHEMA = (re.compile(rb"^schema=fm-secondmate-parent\.v1$", re.M), b"schema=jg-squad-lead-parent.v1")
PIN_DIRS = ("config/secondmates", "config/squad_leads")
LEGACY = re.compile(rb"FIRSTMATE_OP:|FIRSTMATE|firstmate-addons|firstmate|secondmate|crewmate|second mate|first mate|FM_|fm-|fm_")
KNOWN_NONRECORDS = (re.compile(r"state/model-gate\.check\.sh"),)
# An old script path, environment name, function name, features path or operational-input marker
# still resolves through the compatibility layer, so it needs no rewrite.
COMPAT_RESOLVED = re.compile(rb"\bbin/fm-[a-z0-9-]+\.sh|\bfm-[a-z0-9-]+\.sh|\bFM_[A-Z0-9_]+|\bfm_[a-z0-9_]+|FIRSTMATE_OP:|firstmate-addons|(?m:^kind=secondmate$)|(?m:^(?:window|endpoint|session|tab|pane)=fm-\S*)|[\w./@+~-]*/[\w./@+~-]*(?:firstmate|secondmate|fm-)[\w./@+~-]*")
# The last alternative is an absolute or relative host path; it names where a home sits, which no migration can change.
# Free text and per-task records: a legacy word here is prose or history, never a name the code reads.
FREE_TEXT = (
    re.compile(r"data/.*\.(md|txt|log|hashes|json)"),
    re.compile(r"data/[^/]+/.*"),
    re.compile(r"config/.*\.md"),
    re.compile(r"state/.*\.(log|out|err|txt|md|json)"),
    re.compile(r"state/\.[^/]*branch-outcome-index"),
    # Per-task and per-message state: history that no reader keys on by name.
    re.compile(r"state/(terminal-outcomes|operational-inbox|branch-session)/.*"),
    re.compile(r"state/[^/]+\.inbox/.*"),
    re.compile(r"state/\.[^/]*(inherited-config-reread|custom-check)[^/]*"),
    re.compile(r"state/\.(watch\.lock\.owner|wake-queue|branch-)[^/]*.*"),
    # Per-task side records: prior briefs and metas, poll registrations, operator-written check scripts and their trust hash.
    re.compile(r"state/[^/]+\.(brief-prior|meta-prior|pr-poll-[a-z-]+|check\.sh|check-trust)"),
    re.compile(r"state/[^/]+\.control-relaunch\.(brief|meta)-prior"),
    re.compile(r"state/(decision-bindings|procevent)/.*"),
    re.compile(r"state/[^/]+\.lock"),
    # Runtime prompts, mirrors, summaries and outcome logs: generated text rewritten by the running code.
    re.compile(r"state/\.(home-summary\.json\.[^/]*|host-mirror\.jsonl|supervision-host-[a-z]+)"),
    re.compile(r"state/(branch-outcomes\.jsonl|[^/]+\.merge-authority)"),
    # Captain-authored host hooks and routing files hold absolute host paths and prose, not product names.
    re.compile(r"config/(crew-dispatch\.json|fleet-board|launch-env-hook|merge-gate|owner-rules-canary|post-merge)"),
)

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--home', required=True, help='the single home to migrate')
p.add_argument('--slice', default='records', help='journal slice name (default: records)')
g = p.add_mutually_exclusive_group(required=True)
for mode in ('check', 'apply', 'verify', 'rollback'):
    g.add_argument('--' + mode, action='store_true')
a = p.parse_args()
home = pathlib.Path(a.home).resolve()
if not home.is_dir():
    p.error('--home must be an existing directory')
for name in ('config', 'state', 'data'):
    if not (home / name).is_dir():
        p.error(f'home is missing {name}/')
if not a.slice or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in a.slice):
    p.error('--slice must contain only letters, digits, _ or -')
mig = home / 'state/.jg-migration'
journal = mig / f'{a.slice}.journal'


def transform(path, raw):
    rel = path.relative_to(home).as_posix()
    supported = [(pattern, field, replacement) for pattern, field, replacement in RULES if pattern.fullmatch(rel)]
    updated = raw
    if not supported and any(pattern.fullmatch(rel) for pattern in KNOWN_NONRECORDS):
        return updated
    for _, field, replacement in supported:
        updated = field.sub(replacement, updated)
    if any(pattern.fullmatch(rel) for pattern in FREE_TEXT):
        return updated
    if re.fullmatch(r"state/[^/]+\.status", rel):
        # Prose in a status event is history; only a legacy event key at the start of a line is read by name.
        if re.search(rb"^(fm-|FM_)[a-z0-9_-]*:", updated, re.M):
            raise ValueError(f'unclassified legacy content: {rel}')
        return updated
    if LEGACY.search(COMPAT_RESOLVED.sub(b"", updated)):
        raise ValueError(f'unclassified legacy content: {rel}')
    return updated


def files():
    found = []
    unknown = []
    for part in ('config', 'state', 'data'):
        base = home / part
        for root, dirs, names in os.walk(base, followlinks=False):
            dirs[:] = sorted(d for d in dirs if d != '.jg-migration')
            for name in sorted(names):
                path = pathlib.Path(root) / name
                rel = path.relative_to(home).as_posix()
                if path.is_symlink():
                    if any(pattern.fullmatch(rel) for pattern in FREE_TEXT):
                        continue
                    if LEGACY.search(os.readlink(path).encode()):
                        unknown.append(f'unclassified legacy symbolic link: {rel}')
                    continue
                if not path.is_file():
                    unknown.append(f'unclassifiable record: {rel}')
                    continue
                raw = path.read_bytes()
                try:
                    raw.decode('utf-8')
                except UnicodeDecodeError:
                    if LEGACY.search(raw):
                        unknown.append(f'unclassified legacy binary record: {rel}')
                    continue
                try:
                    updated = transform(path, raw)
                except ValueError as e:
                    unknown.append(str(e))
                    continue
                if updated != raw:
                    found.append((path, raw, updated))
    if unknown:
        raise ValueError('\nunknown: '.join(unknown))
    return found

def moves():
    found = []
    for old, new in MARKERS:
        src, dst = home / old, home / new
        if src.is_symlink() or not src.is_file():
            continue
        if dst.exists() or dst.is_symlink():
            raise ValueError(f'rename target exists: {new}')
        found.append((src, dst, MARKER_SCHEMA[0].sub(MARKER_SCHEMA[1], src.read_bytes())))
    old_dir, new_dir = (home / d for d in PIN_DIRS)
    if old_dir.is_dir() and not old_dir.is_symlink():
        for src in sorted(old_dir.iterdir()):
            dst = new_dir / src.name
            if dst.exists() or dst.is_symlink():
                raise ValueError(f'rename target exists: {dst.relative_to(home)}')
            if src.is_dir() and not src.is_symlink():
                found.append((src, dst, None))
    return found

try:
    changes = files()
    renames = moves()
except (OSError, ValueError) as e:
    print(f'unknown: {e}', file=sys.stderr)
    sys.exit(3)

if a.check:
    for path, _, _ in changes:
        print(path.relative_to(home))
    for src, dst, _ in renames:
        print(f'{src.relative_to(home)} -> {dst.relative_to(home)}')
    if not changes and not renames:
        print('no rewrites required')
    sys.exit(0)
if a.verify:
    if changes or renames:
        print('not migrated: ' + ', '.join(str(x[0].relative_to(home)) for x in changes + renames), file=sys.stderr)
        sys.exit(1)
    print('verified: no supported legacy names remain')
    sys.exit(0)
if a.apply:
    if journal.exists():
        if not changes and not renames:
            print('already applied')
            sys.exit(0)
        print('existing journal does not match current home', file=sys.stderr)
        sys.exit(3)
    mig.mkdir(parents=True, exist_ok=True)
    with tarfile.open(journal, 'w:gz') as archive:
        for part in ('config', 'state', 'data'):
            archive.add(home / part, arcname=part, recursive=True,
                        filter=lambda info: None if '.jg-migration' in pathlib.PurePosixPath(info.name).parts else info)
        for old, _ in MARKERS:
            if (home / old).is_file():
                archive.add(home / old, arcname=old)
    for path, _, updated in changes:
        fd, temp = tempfile.mkstemp(dir=path.parent, prefix='.jg-migrate-')
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(updated)
                stream.flush()
                os.fsync(stream.fileno())
            shutil.copystat(path, temp, follow_symlinks=False)
            os.replace(temp, path)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)
    for src, dst, updated in renames:
        if updated is None:
            dst.parent.mkdir(parents=True, exist_ok=True)
            os.rename(src, dst)
        else:
            dst.write_bytes(updated)
            shutil.copystat(src, dst)
            src.unlink()
    try:
        (home / PIN_DIRS[0]).rmdir()
    except OSError:
        pass
    print(f'applied {len(changes) + len(renames)} rewrites; journal: {journal.relative_to(home)}')
    sys.exit(0)
if a.rollback:
    if not journal.is_file():
        print('migration journal not found', file=sys.stderr)
        sys.exit(1)
    with tarfile.open(journal, 'r:gz') as archive:
        archive.extractall(home, filter='data')
    # The apply refuses an existing target, so a target beside a restored source is the migrated copy.
    for old, new in MARKERS:
        if (home / old).is_file() and (home / new).is_file():
            (home / new).unlink()
    old_dir, new_dir = (home / d for d in PIN_DIRS)
    if old_dir.is_dir() and new_dir.is_dir():
        for src in old_dir.iterdir():
            if (new_dir / src.name).is_dir():
                shutil.rmtree(new_dir / src.name)
        try:
            new_dir.rmdir()
        except OSError:
            pass
    journal.unlink()
    try:
        mig.rmdir()
    except OSError:
        pass
    print('rollback restored the journaled home')
PY

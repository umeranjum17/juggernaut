#!/usr/bin/env bash
# jg-launch-settings.sh - the Claude settings keys that keep a fleet session thin.
#
# Usage: jg-launch-settings.sh <ship|scout|squad_lead> [--include <file>]...
#
# Prints one JSON fragment, without braces, for bin/jg-spawn.sh to put in the launch's
# --settings value (a worker's inline JSON and a lead's state/<id>.claude-settings.json
# both take it, so the two roles share this one builder):
#   "ultracode":false                   the workflow text off
#   "autoMemoryEnabled":false           no harness memory index, so a lead restart loads no other home's memory
#   "skillOverrides":{"<name>":"off"}   each skill that exists and is not in the role's keep-list
# The account's user-level settings stay loaded (the delete, read and kill guards are hooks of
# them); only these keys are set per launch.
#
# A skill exists when it is a folder with a SKILL.md under $HOME/.agents/skills or
# $HOME/.claude/skills, a skill of an installed plugin ($HOME/.claude/plugins/installed_plugins.json,
# named <plugin>:<skill>), or one of this repository's own skills. A skill the account syncs from the
# cloud has no folder to read and is not listed here.
# The keep-list is the role's rows of defaults/worker-rules.tsv (`skill:` rows, and `keep:` rows for the
# personal skills a brief names) plus every existing skill whose name a --include file holds as a word.
# The role map is ship=builder, scout=scout, squad_lead=squad_lead.
set -u
export LC_ALL=C
ROOT="${JG_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MAP="${JG_WORKER_RULES_MAP:-$ROOT/defaults/worker-rules.tsv}"
die() { echo "error: jg-launch-settings: $*" >&2; exit 1; }

case "${1:-}" in
  ship) role=builder ;;
  scout) role=scout ;;
  squad_lead) role=squad_lead ;;
  -h | --help | '') sed -n '2,22p' "$0"; exit 0 ;;
  *) die "kind must be ship, scout or squad_lead" ;;
esac
shift
includes=()
while [ $# -gt 0 ]; do
  case "$1" in
    --include) [ $# -ge 2 ] || die "--include needs a file"; includes+=("$2"); shift 2 ;;
    *) die "unknown argument '$1'" ;;
  esac
done
[ -r "$MAP" ] || die "no role map at $MAP"

exec python3 -I - "$role" "$MAP" "$ROOT" "${HOME:-}" "${includes[@]}" <<'PY'
import json, os, re, sys

role, map_path, root, home = sys.argv[1:5]
includes = sys.argv[5:]

keep, known = set(), set()
for line in open(map_path):
    if not line.strip() or line.startswith('#'):
        continue
    ident, _, roles = line.rstrip('\n').partition('\t')
    kind, _, names = ident.partition(':')
    if kind not in ('skill', 'keep'):
        continue
    for name in names.split():
        known.add(name)
        if 'all' in roles.split(',') or role in roles.split(','):
            keep.add(name)

def folders(path):
    try:
        return {d for d in os.listdir(path) if os.path.isfile(os.path.join(path, d, 'SKILL.md'))}
    except OSError:
        return set()

exist = set()
for base in (os.path.join(home, '.agents', 'skills'), os.path.join(home, '.claude', 'skills')):
    exist |= folders(base)
exist |= {n for n in known if os.path.isfile(os.path.join(root, '.agents', 'skills', n, 'SKILL.md'))}
try:
    plugins = json.load(open(os.path.join(home, '.claude', 'plugins', 'installed_plugins.json'))).get('plugins', {})
    for key, installs in plugins.items():
        for install in installs:
            for skill in folders(os.path.join(install.get('installPath', ''), 'skills')):
                exist.add(key.split('@')[0] + ':' + skill)
except (OSError, ValueError, AttributeError):
    pass

text = ''
for path in includes:
    try:
        text += open(path, errors='replace').read() + '\n'
    except OSError:
        pass
for name in exist:
    if name not in keep and text and re.search(r'(?<![\w-])' + re.escape(name) + r'(?![\w-])', text):
        keep.add(name)

# A name rides inside a shell-quoted JSON value, so only a plain skill name is ever listed.
plain = re.compile(r'^[A-Za-z0-9._:-]+$')
off = {n: 'off' for n in sorted(exist - keep) if plain.match(n)}
body = {'ultracode': False, 'autoMemoryEnabled': False, 'skillOverrides': off}
print(json.dumps(body, separators=(',', ':'))[1:-1])
PY

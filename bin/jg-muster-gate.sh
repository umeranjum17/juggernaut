#!/usr/bin/env bash
# jg-muster-gate.sh - the pack gate: check a project's documents (its "pack") for their depth.
#
# Usage: jg-muster-gate.sh check <project> --depth complete
#        jg-muster-gate.sh check <project> --depth full|light --change <slug> --before <dir>
#        jg-muster-gate.sh --help
#
# check: reads the files of <project>, writes nothing, calls no model and no network, and prints the same lines for
#   the same files. Exit 0 prints `PASS`. Exit 1 prints one `refused: <clause>: <detail>` line for every finding,
#   all of them, and nothing else. Exit 2 is a usage error, or a pack file that cannot be read, named on stderr.
#   complete checks a brand-new project's whole pack. full and light check a feature: <project> is the tree after the
#   feature, <dir> the tree before it, and `docs/changes/<slug>.md` is compared with the real difference between the
#   two, both ways. full or light with no --change and --before is refused, never checked as a project.
#   core/muster/pack_check.py owns every clause; this script only calls it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

case ${1-} in
  -h | --help) usage; exit 0 ;;
  check) shift ;;
  *) usage >&2; exit 2 ;;
esac
command -v python3 >/dev/null 2>&1 || { echo "jg-muster-gate: python3 is not installed" >&2; exit 2; }
exec python3 -I "$JG_ROOT/core/muster/pack_check.py" "$@"

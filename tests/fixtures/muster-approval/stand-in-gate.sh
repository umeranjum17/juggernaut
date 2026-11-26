#!/usr/bin/env bash
# The stand-in for bin/jg-muster-gate.sh in tests/jg-muster-approval.test.sh (JG_MUSTER_GATE points here):
#   stand-in-gate.sh check <project> --depth <complete|full|light> [--change <slug> --before <dir>]
# It runs pack-check.py (the prototype of the real gate, copied here byte for byte) and keeps its exit codes: 0 and
# PASS, or 1 and one `refused:` line per clause. a1 proves the real gate and this order's script together.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ "${1:-}" = check ] || { echo "usage: stand-in-gate.sh check <project> --depth <d> [--change <slug> --before <dir>]" >&2; exit 2; }
shift
exec python3 -I "$here/pack-check.py" gate "$@"

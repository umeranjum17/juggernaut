#!/usr/bin/env bash
# jg-workflow.sh - workflows are configuration: a plain-text file the owner edits names every workflow,
# and any spec of any steps in any order and count parses into ordered stages.
#
# Usage: jg-workflow.sh <sub> [args...]
#   parse <spec|name> [--by owner|main|lead] [--text]   print the stages of a spec or a name
#   list                                                print every name, its spec and where it came from
#   define <name> <spec|off> --by owner|main|lead       write a name into config/workflows
#
# Each subcommand is one file, core/workflows/<sub>.py, so a later slice adds a subcommand by adding a file and
# this router never changes. Names come from defaults/workflows (shipped) and config/workflows (the home's own,
# which wins); routes from defaults/workflow-routes and config/workflow-routes. core/workflows/README.md owns
# the grammar and the one rule that holds for every shape (the owner's plan-approval rule).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() { sed -n '2,/^set -u$/{/^set -u$/!s/^# \{0,1\}//p;}' "${BASH_SOURCE[0]}"; }

case "${1:-}" in
  --help | -h) usage; exit 0 ;;
esac
sub=${1:-}
if [[ ! $sub =~ ^[a-z][a-z-]*$ ]] || [ "$sub" = wflib ] || [ ! -f "$ROOT/core/workflows/$sub.py" ]; then
  usage >&2
  exit 2
fi
shift
export JG_WORKFLOW_ROOT="$ROOT"
export JG_WORKFLOW_CONFIG="${JG_CONFIG_OVERRIDE:-${JG_HOME:-$ROOT}/config}"
exec python3 -I "$ROOT/core/workflows/$sub.py" "$@"

#!/usr/bin/env bash
# Enable the read-only machine view in one home. Usage: view.sh [--dry-run] <jg-home>
set -euo pipefail
dry=0
[ "${1:-}" != --dry-run ] || { dry=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1/config" ] || { echo 'usage: view.sh [--dry-run] <jg-home>' >&2; exit 2; }
if [ "$dry" -eq 1 ]; then
  printf 'would enable machine view in %s\n' "$1"
else
  touch "$1/config/machine-view"
fi

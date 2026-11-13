#!/usr/bin/env bash
# bash -n over every core feature script, run from core/ (the same file walk as core-shellcheck.sh).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../core"
found=0
for f in ./*.sh ./*/* ./*/*/*; do
  [ -f "$f" ] || continue
  head -n 1 "$f" | grep -Eq '^#!.*\b(bash|sh)\b' || continue
  found=$((found + 1))
  echo "== bash -n $f =="
  bash -n "$f"
done
if [ "$found" -eq 0 ]; then
  echo "no core feature script found in any core/<feature>/ directory" >&2
  exit 1
fi

#!/usr/bin/env bash
# jg-state-lint.sh - count the bare state strings in bin/ and core/, then refuse a new one.
#
# Usage: jg-state-lint.sh [--check] [--list] [--root <dir>] [--baseline <file>]
#
# A bare state string is a line that sets or tests a state variable (a name holding stage, state or status)
# against a value of any enum in core/machines/*.states, written as a literal word: stage=landed, [ "$state" = ready ].
# A state word is taken from the enum reader (jg-machine.sh legal/write), never typed in a writer.
# Without --check the lint only reports the count, and --list prints each line (path:line:text). Exit 0.
# With --check it exits 1 when the count is above the baseline (default: <root>/core/machines/bare-states.baseline,
# one number); lowering the number there is how a cleaned-up writer is kept clean. Exit 2 is a usage error.
# Scanned: files under bin/ and core/ except the enum files, the tables, tests and the baseline itself.
set -u
export LC_ALL=C
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/.." && pwd) check=0 list=0 base=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) check=1 ;; --list) list=1 ;;
    --root) [ "$#" -ge 2 ] || exit 2; root=$2; shift ;;
    --baseline) [ "$#" -ge 2 ] || exit 2; base=$2; shift ;;
    *) sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
  esac
  shift
done
[ -d "$root" ] || { echo "jg-state-lint: no such root: $root" >&2; exit 2; }
base=${base:-$root/core/machines/bare-states.baseline}
words=$(cat "$root"/core/machines/*.states 2>/dev/null | awk -F'\t' '!/^#/ && NF >= 3 { print $1 }' | sort -u | paste -sd'|' -)
[ -n "$words" ] || { echo "jg-state-lint: no enum files under $root/core/machines" >&2; exit 2; }
re="(stage|state|status)[A-Za-z_]*[\"'}\\]]*[ ]*(==|!=|=)[ ]*[\"']?($words)[\"']?([^A-Za-z0-9_-]|\$)"
hits=$(cd "$root" && find bin core -type f ! -name '*.states' ! -name '*.tsv' ! -name '*.baseline' ! -name '*.test.sh' ! -path 'core/machines/corpus/*' ! -path '*/tests/*' -print0 2>/dev/null \
  | sort -z | xargs -0 grep -InE -- "$re" 2>/dev/null | grep -v ':[0-9]*:[[:space:]]*#')
count=0; [ -z "$hits" ] || count=$(printf '%s\n' "$hits" | wc -l | tr -d ' ')
[ "$list" -eq 0 ] || { [ -z "$hits" ] || printf '%s\n' "$hits"; }
printf 'bare state strings: %s\n' "$count"
[ "$check" -eq 1 ] || exit 0
limit=$(tr -dc '0-9' <"$base" 2>/dev/null); limit=${limit:-0}
if [ "$count" -gt "$limit" ]; then
  printf 'jg-state-lint: refused: %s bare state strings, baseline %s; take the state word from the enum reader (jg-machine.sh legal|write)\n' "$count" "$limit" >&2
  exit 1
fi

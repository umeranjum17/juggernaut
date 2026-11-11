#!/usr/bin/env bash
# jg-config-doc.sh - list the settings that have a default in the code and no entry in the reference.
#
# A setting is a JG_ name read with a default, `${JG_<NAME>:-...}`, in a tracked file under bin/ or core/.
# It has an entry when docs/configuration.md names it anywhere.
# defaults/config-doc-count holds the stored count: the most settings allowed to have no entry.
# The stored count only goes down: a change that documents settings lowers it to the new count in the same change.
#
# Usage:
#   jg-config-doc.sh [--count] [--rev <commit>] [--root <dir>] [--limit <file>]
#
# With no flag it prints each setting with no entry, one per line, then one summary line on stderr
# that compares the count with the stored count.
# --count prints only the number and never compares it, so it exits 0 whatever the number is.
# --rev reads the code, the reference and the stored count at <commit> instead of the working tree.
# --root names the repository (default: the one this script is in).
# --limit reads the stored count from <file> instead of defaults/config-doc-count.
#
# The command is read-only.
#
# Exit status: 0 when the count is at or below the stored count, 1 when it is above it,
# 2 on a usage error, an unknown commit, or a missing reference or stored count.
set -euo pipefail

ROOT='' rev='' limit_file='' count_only=0
die() { printf 'jg-config-doc: %s\n' "$*" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  case $1 in
    --count) count_only=1; shift ;;
    --rev) rev=${2:?--rev needs a commit}; shift 2 ;;
    --root) ROOT=${2:?--root needs a directory}; shift 2 ;;
    --limit) limit_file=${2:?--limit needs a file}; shift 2 ;;
    -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "$ROOT is not a git repository"
if [ -n "$rev" ]; then
  git -C "$ROOT" rev-parse --verify --quiet "$rev^{commit}" >/dev/null || die "unknown commit $rev"
fi

# <path>: the file's text in the tree being read, or nonzero when it is not there.
read_tree_file() {
  if [ -n "$rev" ]; then
    git -C "$ROOT" show "$rev:$1" 2>/dev/null
  else
    [ -f "$ROOT/$1" ] && cat -- "$ROOT/$1"
  fi
}

reference=docs/configuration.md
doc=$(read_tree_file "$reference") || die "no $reference${rev:+ at $rev}"

# git grep exits 1 when nothing matches, which is a count of 0, not an error.
status=0
defaulted=$(git -C "$ROOT" grep -ohE '\$\{JG_[A-Z0-9_]+:-' ${rev:+"$rev"} -- bin core) || status=$?
[ "$status" -le 1 ] || die "git grep failed in $ROOT${rev:+ at $rev}"

missing=$(LC_ALL=C comm -23 \
  <(printf '%s\n' "$defaulted" | sed -E -n 's/^\$\{(JG_[A-Z0-9_]+):-$/\1/p' | LC_ALL=C sort -u) \
  <(printf '%s\n' "$doc" | { grep -oE 'JG_[A-Z0-9_]+' || true; } | LC_ALL=C sort -u))
count=0
[ -z "$missing" ] || count=$(printf '%s\n' "$missing" | wc -l | tr -d ' ')

if [ "$count_only" -eq 1 ]; then
  printf '%s\n' "$count"
  exit 0
fi

stored_name=defaults/config-doc-count
if [ -n "$limit_file" ]; then
  stored_name=$limit_file
  stored_text=$(cat -- "$limit_file" 2>/dev/null) || die "cannot read stored count $limit_file"
else
  stored_text=$(read_tree_file "$stored_name") || die "no stored count $stored_name${rev:+ at $rev}"
fi
stored=$(printf '%s\n' "$stored_text" | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' | head -n 1 | tr -d '[:space:]')
case $stored in '' | *[!0-9]*) die "stored count in $stored_name is not a number: ${stored:-empty}" ;; esac

[ -z "$missing" ] || printf '%s\n' "$missing"
if [ "$count" -gt "$stored" ]; then
  printf 'jg-config-doc: %s settings have a default and no entry in %s, above the stored count %s in %s: add each new setting to %s\n' \
    "$count" "$reference" "$stored" "$stored_name" "$reference" >&2
  exit 1
fi
if [ "$count" -lt "$stored" ]; then
  printf 'jg-config-doc: %s settings have a default and no entry in %s, below the stored count %s: lower %s to %s\n' \
    "$count" "$reference" "$stored" "$stored_name" "$count" >&2
else
  printf 'jg-config-doc: %s settings have a default and no entry in %s, at the stored count\n' "$count" "$reference" >&2
fi
exit 0

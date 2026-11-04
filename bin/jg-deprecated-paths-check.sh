#!/usr/bin/env bash
# jg-deprecated-paths-check.sh - refuse a change to a path the new stack replaced.
#
# defaults/deprecated-paths lists the replaced paths (docs/deprecated-paths.md owns the evidence).
# An agent must not edit them: delete the path, or change its replacement.
# A change to a listed path is refused unless it
#   - deletes the path,
#   - edits a Markdown file (a doc or the DEPRECATED.md banner), or
#   - changes only banner lines: a comment line that starts with "DEPRECATED:" or "Do not change this file".
# A banner line must be a whole comment line, so code cannot ride along on it.
#
# Usage:
#   jg-deprecated-paths-check.sh --base <ref> [--worktree] [--root <dir>] [--list <file>]
#
# --base <ref> compares <ref> with HEAD, or with the working tree under --worktree.
# The list is read at <ref> and at HEAD, so a change cannot unlist a path and edit it in one step.
# bin/jg-lint.sh runs this check with the base it already uses for its changed-file set.
#
# Exit status: 0 when nothing listed changed, 1 with one line per refused path, 2 on a usage error.
set -eu

ROOT='' base='' worktree=0 list=''
while [ "$#" -gt 0 ]; do
  case $1 in
    --base) base=${2:?--base needs a ref}; shift 2 ;;
    --root) ROOT=${2:?--root needs a directory}; shift 2 ;;
    --list) list=${2:?--list needs a file}; shift 2 ;;
    --worktree) worktree=1; shift ;;
    -h | --help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) printf 'jg-deprecated-paths-check: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
[ -n "$base" ] || { printf 'jg-deprecated-paths-check: --base <ref> is required\n' >&2; exit 2; }
git -C "$ROOT" rev-parse --verify --quiet "$base^{commit}" >/dev/null \
  || { printf 'jg-deprecated-paths-check: unknown ref %s\n' "$base" >&2; exit 2; }
list=${list:-$ROOT/defaults/deprecated-paths}

# Every row of the list at HEAD (or --list) and at the base: "<path> <replacement>".
rows=$( { [ ! -r "$list" ] || cat "$list"; git -C "$ROOT" show "$base:defaults/deprecated-paths" 2>/dev/null || true; } \
  | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' | sort -u)

diff_args=("$base" HEAD)
[ "$worktree" -eq 0 ] || diff_args=("$base")

replacement_of() {  # <path>: the first listed row that covers it, or nothing
  local p=$1 row path
  while IFS= read -r row; do
    path=${row%%[[:space:]]*}
    case $path in
      */) case $p in "$path"*) printf '%s\n' "${row#"$path"}" | sed 's/^[[:space:]]*//'; return 0 ;; esac ;;
      *) [ "$p" = "$path" ] && { printf '%s\n' "${row#"$path"}" | sed 's/^[[:space:]]*//'; return 0; } ;;
    esac
  done <<<"$rows"
  return 1
}

banner_only() {  # <path>: 0 when every changed line of the file is a banner line
  git -C "$ROOT" diff -U0 --no-renames "${diff_args[@]}" -- "$1" \
    | awk '/^(\+\+\+|---)/ || /^[^+-]/ { next }
           !/^[+-][[:space:]]*(#|\/\/|--|\/\*|\*|<!--)[[:space:]]*(DEPRECATED:|Do not change this file)/ { bad = 1 }
           END { exit bad }'
}

found=0
while IFS= read -r -d '' status && IFS= read -r -d '' p; do
  [ "$status" != D ] || continue
  repl=$(replacement_of "$p") || continue
  case $p in *.md) continue ;; esac
  if [ "$status" = M ] && banner_only "$p"; then continue; fi
  printf 'deprecated path: %s (%s): replaced by %s; see docs/deprecated-paths.md. Delete it or change the replacement.\n' \
    "$p" "$([ "$status" = A ] && echo added || echo changed)" "$repl"
  found=1
done < <(git -C "$ROOT" diff --name-status -z --no-renames "${diff_args[@]}")
exit "$found"

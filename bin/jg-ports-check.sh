#!/usr/bin/env bash
# jg-ports-check.sh - keep every outside dependency behind one port and one adapter.
#
# defaults/ports-adapters lists each dependency with its port module and adapter file;
# docs/ports-and-adapters.md owns the rule. Two checks:
#
#   code   a source file (.ts .js .mjs .go .sh) that imports or runs a listed client is refused
#          unless it is that dependency's adapter or sits in defaults/ports-adapters-legacy.
#          The legacy list is read at the base ref, so a change cannot grandfather itself.
#   plan   a plan or PR text that mentions a listed dependency is refused unless it names the
#          port module and an adapter file from the same row.
#
# Usage:
#   jg-ports-check.sh --base <ref> [--worktree] [--root <dir>]   check the files changed since <ref>
#   jg-ports-check.sh --all [--root <dir>]                       check every tracked file
#   jg-ports-check.sh --plan <file> [--root <dir>]               check a plan or PR text
#   jg-ports-check.sh --list-legacy [--root <dir>]               print the files an --all run would need as legacy
#
# bin/jg-lint.sh runs the code check on every changed-file run.
# Exit status: 0 clean, 1 with one line per refusal, 2 on a usage error.
set -eu

ROOT='' mode='' base='' worktree=0 plan=''
while [ "$#" -gt 0 ]; do
  case $1 in
    --base) mode=base; base=${2:?--base needs a ref}; shift 2 ;;
    --worktree) worktree=1; shift ;;
    --all) mode=all; shift ;;
    --plan) mode=plan; plan=${2:?--plan needs a file}; shift 2 ;;
    --list-legacy) mode=legacy; shift ;;
    --root) ROOT=${2:?--root needs a directory}; shift 2 ;;
    -h | --help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) printf 'jg-ports-check: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
[ -n "$mode" ] || { printf 'jg-ports-check: give --base, --all, --plan or --list-legacy\n' >&2; exit 2; }
manifest=$ROOT/defaults/ports-adapters
[ -r "$manifest" ] || { printf 'jg-ports-check: %s is missing\n' "${manifest#"$ROOT"/}" >&2; exit 2; }

trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
# rows: one "name<TAB>terms<TAB>client<TAB>port<TAB>adapters" line per dependency.
rows=$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$manifest" | awk -F ' [|] ' 'NF != 5 { bad = 1; print "BAD\t" $0; next } { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 }')
case $rows in *BAD*) printf 'jg-ports-check: defaults/ports-adapters has a row without five fields\n' >&2; exit 2 ;; esac

fail=0
refuse() { printf 'ports: %s\n' "$*"; fail=1; }

if [ "$mode" = plan ]; then
  [ -r "$plan" ] || { printf 'jg-ports-check: cannot read %s\n' "$plan" >&2; exit 2; }
  while IFS=$'\t' read -r name terms _ port adapters; do
    grep -Eqi -- "$terms" "$plan" || continue
    grep -qF -- "$port" "$plan" || refuse "the plan uses $name but does not name its port module $port (defaults/ports-adapters)"
    named=0
    IFS=',' read -r -a adapter_list <<<"$adapters"
    for a in "${adapter_list[@]}"; do a=$(printf '%s' "$a" | trim); grep -qF -- "$a" "$plan" && named=1; done
    [ "$named" -eq 1 ] || refuse "the plan uses $name but does not name its adapter ($adapters)"
  done <<<"$rows"
  exit "$fail"
fi

is_adapter() {  # <path> <adapters>: 0 when the path is one of the adapter files or inside an adapter directory
  local p=$1 a list
  IFS=',' read -r -a list <<<"$2"
  for a in "${list[@]}"; do
    a=$(printf '%s' "$a" | trim)
    case $a in */) case $p in "$a"*) return 0 ;; esac ;; *) [ "$p" = "$a" ] && return 0 ;; esac
  done
  return 1
}

legacy_rows() {  # the legacy list at the base (or at HEAD when the base has none)
  local text=''
  if [ "$mode" = base ]; then text=$(git -C "$ROOT" show "$base:defaults/ports-adapters-legacy" 2>/dev/null || true); fi
  if [ -z "$text" ] && [ -r "$ROOT/defaults/ports-adapters-legacy" ]; then
    # Only the very change that introduces the list may read it from HEAD.
    if [ "$mode" != base ] || ! git -C "$ROOT" cat-file -e "$base:defaults/ports-adapters-legacy" 2>/dev/null; then
      text=$(cat "$ROOT/defaults/ports-adapters-legacy")
    fi
  fi
  printf '%s\n' "$text" | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' | awk '{print $1 "\t" $2}'
}
legacy=$([ "$mode" = legacy ] || legacy_rows)

case $mode in
  base)
    git -C "$ROOT" rev-parse --verify --quiet "$base^{commit}" >/dev/null \
      || { printf 'jg-ports-check: unknown ref %s\n' "$base" >&2; exit 2; }
    diff_args=("$base" HEAD); [ "$worktree" -eq 0 ] || diff_args=("$base")
    files=$(git -C "$ROOT" diff --name-only --diff-filter=AMR "${diff_args[@]}") ;;
  *) files=$(git -C "$ROOT" ls-files) ;;
esac

while IFS= read -r f; do
  case $f in
    *.ts | *.js | *.mjs | *.go | *.sh) ;;
    *) continue ;;
  esac
  case $f in tests/* | */testdata/* | *_test.go | bin/jg-ports-check.sh | defaults/*) continue ;; esac
  [ -f "$ROOT/$f" ] || continue
  while IFS=$'\t' read -r name _ client _ adapters; do
    is_adapter "$f" "$adapters" && continue
    grep -Ev '^[[:space:]]*(#|//|\*)' "$ROOT/$f" | grep -Eq -- "$client" || continue
    if [ "$mode" = legacy ]; then printf '%s %s\n' "$f" "$name"; continue; fi
    if printf '%s\n' "$legacy" | grep -qxF -- "$(printf '%s\t%s' "$f" "$name")"; then continue; fi
    refuse "$f uses $name outside its adapter ($adapters); import it through the port, or add the code to the adapter (docs/ports-and-adapters.md)"
  done <<<"$rows"
done <<<"$files"
exit "$fail"

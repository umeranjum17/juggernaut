#!/usr/bin/env bash
# The design-option board check: a shell check on recorded files; nothing here calls a model.
# Usage: jg-design-gate.sh board <first-draft-receipt> <options-folder-or-file>...
#
# `board` takes a first-draft run record and the design options about to be posted to the board for the
# captain's pick, and refuses before they are shown when an option has no make or refine record. The record
# is resolved, never taken on its word: it must prove a first-draft make or refine and list every option, so a
# judge-only record (made nothing) and hand-authored option HTML are refused by name.
# A real unresolved product choice is held at its decision (bin/jg-captain-hold.sh), which blocks the linked
# work. There is no size rule, hand-roll approval or receipt line that refuses a merge or a done (pcp-s7).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2329 # the sourced merge-gate lib calls it (its callers supply it)
jg_dod_meta_value() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }
# shellcheck source=bin/jg-merge-gate-lib.sh
. "$SCRIPT_DIR/jg-merge-gate-lib.sh"

die() { echo "jg-design-gate: $*" >&2; exit 1; }
cmd=${1:-}; [ "$#" -gt 0 ] && shift
case $cmd in
  board)
    [ "$#" -ge 2 ] || die "usage: board <first-draft-receipt> <options-folder-or-file>..."
    ref=$1; shift
    args=(--ref "$ref" --root "$PWD"); opts=()
    for a in "$@"; do
      [ -d "$a" ] || { opts+=("$a"); continue; }
      args+=(--root "$a")
      while IFS= read -r f; do opts+=("$f"); done < <(find "$a" -maxdepth 1 -type f -iname '*.html' | LC_ALL=C sort)
    done
    jg_design_fd_check ${args[@]+"${args[@]}"} -- ${opts[@]+"${opts[@]}"} || exit 1
    printf 'board: %s design option(s) made or refined by first-draft (%s)\n' "${#opts[@]}" "$ref"
    exit 0
    ;;
  *) die "usage: board <first-draft-receipt> <options-folder-or-file>..." ;;
esac

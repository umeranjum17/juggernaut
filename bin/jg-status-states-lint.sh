#!/usr/bin/env bash
# jg-status-states-lint.sh - keep one rule per status state in every brief and charter.
#
# Usage:
#   jg-status-states-lint.sh text <file>...       refuse text that defines a status state differently from the core contract
#   jg-status-states-lint.sh commit [<rev>]       refuse a commit that adds, removes or renames a state word without
#                                                 also changing the brief text (default rev: HEAD)
#   jg-status-states-lint.sh --help
#
# The core contract is defaults/status-states.tsv (its header owns the row format; bin/jg-status-states-lib.sh reads it).
# `text` prints one `<file>:<line>: <kind>: <what>` finding per line and exits 1: a `States:` list that differs, a status line
# written with a word that is not a state, a declared wait without its wait and reason, a wait or reason vocabulary that differs.
# bin/jg-brief.sh and bin/jg-spawn.sh run it over the text they include; the brief's own lines pass by construction.
# `commit` compares the table's state, close, wait and reason words at <rev> with its first parent. When the set changed, the
# commit must also change bin/jg-brief.sh or bin/jg-dod-lib.sh, which hold the brief and charter text; otherwise it names the
# words and exits 1. A root commit, or one that leaves the table alone, passes.
# Exit 0 clean, 1 a finding, 2 a usage error or an unreadable input.
set -u
export LC_ALL=C
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=bin/jg-status-states-lib.sh
. "$ROOT/bin/jg-status-states-lib.sh"
BRIEF_TEXT_FILES='bin/jg-brief.sh bin/jg-dod-lib.sh'
TABLE_REL=defaults/status-states.tsv

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }
bad() { echo "jg-status-states-lint: $*" >&2; exit 2; }

# The sorted `kind:word` set of a table's text.
table_words() {
  awk -F'\t' '/^#/ || NF < 2 { next }
    $1 == "state" || $1 == "close" { print $1 ":" $2; next }
    $1 == "wait" || $1 == "reason" { n = split($2, w, " "); for (i = 1; i <= n; i++) print $1 ":" w[i] }' | sort -u
}

cmd_text() {
  local f rc=0
  [ $# -gt 0 ] || bad "text needs at least one file (see --help)"
  for f in "$@"; do
    jg_states_check_text "$f"
    case $? in 0) ;; 1) rc=1 ;; *) exit 2 ;; esac
  done
  return "$rc"
}

cmd_commit() {
  local rev=${1:-HEAD} parent after before changed files f touched=0
  git -C "$ROOT" rev-parse --verify --quiet "$rev^{commit}" >/dev/null || bad "no such commit $rev"
  parent=$(git -C "$ROOT" rev-parse --verify --quiet "$rev^1^{commit}") || return 0
  after=$(git -C "$ROOT" show "$rev:$TABLE_REL" 2>/dev/null | table_words)
  before=$(git -C "$ROOT" show "$parent:$TABLE_REL" 2>/dev/null | table_words)
  [ "$after" != "$before" ] || return 0
  changed=$(printf '%s\n%s\n' "$before" "$after" | sort | uniq -u | paste -sd' ' -)
  files=$(git -C "$ROOT" diff-tree --no-commit-id --name-only -r "$rev")
  for f in $BRIEF_TEXT_FILES; do
    printf '%s\n' "$files" | grep -qxF -- "$f" && touched=1
  done
  [ "$touched" -eq 0 ] || return 0
  printf 'jg-status-states-lint: commit %s changes the status words (%s) in %s but not the brief text (%s); a worker, lead or Main must be told how to write the word, so update the brief or charter text in the same commit\n' \
    "$(git -C "$ROOT" rev-parse --short "$rev")" "$changed" "$TABLE_REL" "$BRIEF_TEXT_FILES" >&2
  return 1
}

case "${1:-}" in
  text) shift; cmd_text "$@" ;;
  commit) shift; [ $# -le 1 ] || bad "commit takes at most one rev"; cmd_commit "$@" ;;
  -h|--help) usage ;;
  *) bad "unknown command '${1:-}' (see --help)" ;;
esac

#!/usr/bin/env bash
# jg-brief-lint.sh - report what in a brief would mislead the worker who reads it.
#
# Usage:
#   jg-brief-lint.sh [--rules <tsv>] [--skills-dir <dir>]... <brief.md or include file>...
#   jg-brief-lint.sh --help
#
# Each file is checked on its own, against the rule table (default defaults/brief-lint-rules.tsv,
# whose header owns the row format). Each finding is one line, and a clean file prints nothing:
#   <file>:<lines>: conflict <rule>: <lines a> vs <lines b>: <why>      two rules disagree
#   <file>:<lines>: dead-name <name>: no skill or command of that name  a name to use is not there
#   <file>:<line>: over-budget <rule>: <bytes> bytes, budget <bytes>    too large; <line> passes it
# A name is there when a skill folder holds <name>/SKILL.md, or when it is a command (on PATH, or a
# script of that name in this repository's bin/, core/*/ or core/*/bin/), because a worker can run it.
# Skill folders: each --skills-dir, else <repo>/.agents/skills, <repo>/skills and $HOME/.agents/skills
# (the global folder worker briefs name).
# Exit 0 clean, 1 findings, 2 a bad argument, an unreadable file or a bad rule row.
# It only reads and reports: a finding refuses nothing, and the caller decides what one stops.
set -u
export LC_ALL=C
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RULES=$ROOT/defaults/brief-lint-rules.tsv
SKILL_DIRS=()
FILES=()
# A word that can name a skill: lower case, at least one hyphen, nothing else.
NAME_SHAPE='^[a-z][a-z0-9]*(-[a-z0-9]+)+$'

usage() { sed -n '2,18p' "$0"; }
bad() { echo "jg-brief-lint: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --rules) [ $# -ge 2 ] || bad "--rules needs a file"; RULES=$2; shift 2 ;;
    --skills-dir) [ $# -ge 2 ] || bad "--skills-dir needs a folder"; SKILL_DIRS+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; FILES+=("$@"); break ;;
    -*) bad "unknown option '$1' (see --help)" ;;
    *) FILES+=("$1"); shift ;;
  esac
done
[ ${#FILES[@]} -gt 0 ] || bad "name at least one brief or include file (see --help)"
[ ${#SKILL_DIRS[@]} -gt 0 ] || SKILL_DIRS=("$ROOT/.agents/skills" "$ROOT/skills" "${HOME:-/nonexistent}/.agents/skills")
[ -f "$RULES" ] && [ -r "$RULES" ] || bad "cannot read the rule table $RULES"

# The rule table, one array per row kind; a row that does not parse refuses the whole table.
BUDGET_ID='' BUDGET_BYTES=0
C_ID=() C_A=() C_B=() C_WHY=()
N_NAME=() N_BEFORE=() N_AFTER=()
IGNORE=()
valid_ere() { [ "$1" = - ] && return 0; [[ '' =~ $1 ]]; [ $? -ne 2 ]; }
n=0
while IFS= read -r row || [ -n "$row" ]; do
  n=$((n + 1))
  case "$row" in ''|'#'*) continue ;; esac
  IFS=$'\t' read -r -a f <<< "$row"
  where="$RULES:$n"
  case "${f[0]}" in
    budget)
      [ ${#f[@]} -eq 3 ] && [[ ${f[2]} =~ ^[1-9][0-9]*$ ]] || bad "$where: a budget row is: budget<TAB><id><TAB><bytes>"
      [ -z "$BUDGET_ID" ] || bad "$where: a second budget row"
      BUDGET_ID=${f[1]} BUDGET_BYTES=${f[2]} ;;
    conflict)
      [ ${#f[@]} -eq 5 ] || bad "$where: a conflict row is: conflict<TAB><id><TAB><pattern a><TAB><pattern b><TAB><why>"
      [ "${f[2]}" != - ] && [ "${f[3]}" != - ] || bad "$where: a conflict needs both patterns"
      C_ID+=("${f[1]}") C_A+=("${f[2]}") C_B+=("${f[3]}") C_WHY+=("${f[4]}")
      unset 'f[4]' ;;
    name)
      [ ${#f[@]} -eq 5 ] || bad "$where: a name row is: name<TAB><id><TAB><name><TAB><before><TAB><after>"
      N_NAME+=("${f[2]}") N_BEFORE+=("${f[3]}") N_AFTER+=("${f[4]}") ;;
    ignore)
      [ ${#f[@]} -eq 3 ] && [ "${f[2]}" != - ] || bad "$where: an ignore row is: ignore<TAB><id><TAB><before>"
      IGNORE+=("${f[2]}") ;;
    *) bad "$where: unknown row kind '${f[0]}' (budget, conflict, name, ignore)" ;;
  esac
  [ "${f[0]}" = budget ] || for p in "${f[@]:2}"; do valid_ere "$p" || bad "$where: not an extended regular expression: $p"; done
done < "$RULES"

# 0 when <text> matches <ere> at its end (end=1) or at its start (end=0); `-` always matches.
at_edge() {
  [ "$1" = - ] && return 0
  if [ "$3" = 1 ]; then [[ $2 =~ ($1)$ ]]; else [[ $2 =~ ^($1) ]]; fi
}

# Whether the word <tok>, with <before> and <after> its line text, is a skill the text names.
names_skill() {
  local tok=$1 before=$2 after=$3 i p
  for p in "${IGNORE[@]+"${IGNORE[@]}"}"; do at_edge "$p" "$before" 1 && return 1; done
  for i in "${!N_NAME[@]}"; do
    if { [ "${N_NAME[i]}" = - ] || [[ $tok =~ ${N_NAME[i]} ]]; } &&
      at_edge "${N_BEFORE[i]}" "$before" 1 && at_edge "${N_AFTER[i]}" "$after" 0; then
      return 0
    fi
  done
  return 1
}

name_exists() {
  local d
  for d in "${SKILL_DIRS[@]}"; do [ -f "$d/$1/SKILL.md" ] && return 0; done
  for d in "$ROOT/bin" "$ROOT"/core/*/ "$ROOT"/core/*/bin; do
    [ -f "$d/$1" ] || [ -f "$d/$1.sh" ] && return 0
  done
  command -v -- "$1" >/dev/null 2>&1
}

joined() { local IFS=,; echo "$*"; }

# Lint one file; print its findings and return 1 when there is any.
lint() {
  local file=$1 line ln=0 bytes=0 pass_line=0 i rest pre word tok before after found=0
  local -a a_lines b_lines
  local -A dead_lines=() checked=()
  local dead_order=()
  for i in "${!C_ID[@]}"; do a_lines[i]='' b_lines[i]=''; done
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln + 1))
    bytes=$((bytes + ${#line} + 1))
    [ "$pass_line" -eq 0 ] && [ -n "$BUDGET_ID" ] && [ "$bytes" -gt "$BUDGET_BYTES" ] && pass_line=$ln
    for i in "${!C_ID[@]}"; do
      [[ $line =~ ${C_A[i]} ]] && a_lines[i]+=" $ln"
      [[ $line =~ ${C_B[i]} ]] && b_lines[i]+=" $ln"
    done
    [ ${#N_NAME[@]} -gt 0 ] || continue
    # Walk the line one word at a time; a path or file name such as bin/jg-x.sh is one word.
    before='' rest=$line
    while [[ $rest =~ [A-Za-z0-9_./-]+ ]]; do
      word=${BASH_REMATCH[0]}
      pre=${rest%%"$word"*}
      before+=$pre
      rest=${rest#"$pre$word"}
      tok=$word
      while [ "${tok%.}" != "$tok" ]; do tok=${tok%.}; done
      after=${word#"$tok"}$rest
      if [[ $tok =~ $NAME_SHAPE ]] && names_skill "$tok" "$before" "$after"; then
        if [ -z "${checked[$tok]+x}" ]; then
          checked[$tok]=live
          name_exists "$tok" || { checked[$tok]=dead; dead_order+=("$tok"); }
        fi
        [ "${checked[$tok]}" = dead ] && dead_lines[$tok]+=" $ln"
      fi
      before+=$word
    done
  done < "$file"
  # The file's size on disk, so a missing final newline is not counted as a byte.
  bytes=$(wc -c < "$file")
  bytes=${bytes//[[:space:]]/}
  for i in "${!C_ID[@]}"; do
    [ -n "${a_lines[i]}" ] && [ -n "${b_lines[i]}" ] || continue
    local all
    # shellcheck disable=SC2086 # the line lists are space-separated numbers
    all=$(printf '%s\n' ${a_lines[i]} ${b_lines[i]} | sort -n -u)
    # shellcheck disable=SC2086 # the line lists are space-separated numbers
    printf '%s:%s: conflict %s: %s vs %s: %s\n' "$file" "$(joined $all)" "${C_ID[i]}" \
      "$(joined ${a_lines[i]})" "$(joined ${b_lines[i]})" "${C_WHY[i]}"
    found=1
  done
  for tok in "${dead_order[@]+"${dead_order[@]}"}"; do
    # shellcheck disable=SC2086 # the line list is space-separated numbers
    printf '%s:%s: dead-name %s: no skill or command of that name\n' "$file" "$(joined ${dead_lines[$tok]})" "$tok"
    found=1
  done
  if [ -n "$BUDGET_ID" ] && [ "$bytes" -gt "$BUDGET_BYTES" ]; then
    printf '%s:%s: over-budget %s: %s bytes, budget %s\n' "$file" "$pass_line" "$BUDGET_ID" "$bytes" "$BUDGET_BYTES"
    found=1
  fi
  return $found
}

status=0
for file in "${FILES[@]}"; do
  [ -f "$file" ] && [ -r "$file" ] || bad "cannot read $file"
done
for file in "${FILES[@]}"; do
  lint "$file" || status=1
done
exit $status

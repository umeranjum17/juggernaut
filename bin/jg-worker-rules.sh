#!/usr/bin/env bash
# jg-worker-rules.sh - which part of the instruction surface each role reads.
#
# Usage:
#   jg-worker-rules.sh parts   <role>             list the parts a role reads: tokens, bytes, supplying file
#   jg-worker-rules.sh render  <role>             print the role's instruction block
#   jg-worker-rules.sh measure <role> <brief>     tokens before (whole surface) and after (role parts)
#   jg-worker-rules.sh check                      prove the roles' union is the whole surface
#   jg-worker-rules.sh --help
#
# Roles: overwatch squad_lead builder reviewer scout.
# defaults/worker-rules.tsv owns the role-to-part map. The text of a part stays in
# the file that supplies it - an AGENTS.md section or a skill's front matter, the
# part a session loads at start - so no rule is copied and each has one source.
# Token counts are an estimate, one token per four bytes, and say so.
# `measure` compares a recorded prompt's brief plus the whole surface against the
# brief plus the role's parts; the brief is the same text on both sides.
set -u
export LC_ALL=C
ROOT="${JG_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MAP="${JG_WORKER_RULES_MAP:-$ROOT/defaults/worker-rules.tsv}"
ROLES="overwatch squad_lead builder reviewer scout"
die() { echo "error: $*" >&2; exit 1; }
tok() { echo $(( ($1 + 3) / 4 )); }

# Every part as "<id>|<roles>|<file>", one per section and one per skill.
rows() {
  local id roles name
  while IFS=$'\t' read -r id roles; do
    case "$id" in ''|'#'*) continue ;; esac
    case "$id" in
      skill:*) for name in ${id#skill:}; do echo "skill:$name|$roles|.agents/skills/$name/SKILL.md"; done ;;
      *) echo "$id|$roles|AGENTS.md" ;;
    esac
  done < "$MAP"
}
# Text of one part. A section runs from its `## ` heading to the next; the
# preamble is everything before the first. A skill's part is its front matter.
text() {
  case "$1" in
    agents-preamble) awk '/^## /{exit} {print}' "$ROOT/AGENTS.md" ;;
    agents:*) awk -v h="## ${1#agents:}" '/^## /{p = ($0 == h)} p' "$ROOT/AGENTS.md" ;;
    skill:*) awk '/^---$/{c++; print; next} c==1{print} c>=2{exit}' "$ROOT/.agents/skills/${1#skill:}/SKILL.md" ;;
  esac
}
in_role() { case ",$1," in *",$2,"*|*",all,"*) return 0 ;; esac; return 1; }
valid_role() { case " $ROLES " in *" $1 "*) return 0 ;; esac; return 1; }
role_rows() { rows | while IFS='|' read -r id roles file; do in_role "$roles" "$1" && echo "$id|$file"; done; }

cmd=${1:-}
case "$cmd" in
  parts|render|measure)
    role=${2:-}; valid_role "$role" || die "role must be one of: $ROLES"
    ;;
  check) ;;
  -h|--help|'') sed -n '2,17p' "$0"; exit 0 ;;
  *) die "unknown command '$cmd' (parts, render, measure, check)" ;;
esac

case "$cmd" in
  parts)
    total=0
    while IFS='|' read -r id file; do
      b=$(text "$id" | wc -c); total=$((total + b))
      printf '%6d tokens %7d bytes  %s  (%s)\n' "$(tok "$b")" "$b" "$id" "$file"
    done < <(role_rows "$role")
    printf '%6d tokens %7d bytes  TOTAL %s\n' "$(tok "$total")" "$total" "$role"
    ;;
  render)
    while IFS='|' read -r id _; do text "$id"; done < <(role_rows "$role")
    ;;
  measure)
    brief=${3:-}; [ -f "$brief" ] || die "measure needs the recorded brief file"
    bb=$(wc -c < "$brief")
    whole=$(wc -c < "$ROOT/AGENTS.md")
    for s in "$ROOT"/.agents/skills/*/SKILL.md; do whole=$((whole + $(text "skill:$(basename "$(dirname "$s")")" | wc -c))); done
    mine=$("$0" render "$role" | wc -c)
    printf 'role=%s (1 token ~ 4 bytes, an estimate)\n' "$role"
    printf 'brief            %6d tokens %7d bytes  %s\n' "$(tok "$bb")" "$bb" "$brief"
    printf 'surface before   %6d tokens %7d bytes  AGENTS.md + every skill front matter\n' "$(tok "$whole")" "$whole"
    printf 'surface after    %6d tokens %7d bytes  defaults/worker-rules.tsv parts for %s\n' "$(tok "$mine")" "$mine" "$role"
    printf 'block before     %6d tokens\nblock after      %6d tokens\n' "$(tok $((bb + whole)))" "$(tok $((bb + mine)))"
    ;;
  check)
    bad=0
    # Each section heading and each skill is named by exactly one row.
    want=$( { echo agents-preamble; grep '^## ' "$ROOT/AGENTS.md" | sed 's/^## /agents:/'
      for d in "$ROOT"/.agents/skills/*/SKILL.md; do echo "skill:$(basename "$(dirname "$d")")"; done; } | sort)
    have=$(rows | cut -d'|' -f1 | sort)
    dup=$(echo "$have" | uniq -d); [ -z "$dup" ] || { echo "named twice: $dup"; bad=1; }
    gone=$(comm -23 <(echo "$want") <(echo "$have" | uniq)); [ -z "$gone" ] || { echo "no role reads: $gone"; bad=1; }
    extra=$(comm -13 <(echo "$want") <(echo "$have" | uniq)); [ -z "$extra" ] || { echo "names no source: $extra"; bad=1; }
    # Every row names real roles; every role reads something.
    while IFS='|' read -r id roles _; do
      for r in $(echo "$roles" | tr ',' ' '); do [ "$r" = all ] || valid_role "$r" || { echo "unknown role '$r' in $id"; bad=1; }; done
    done < <(rows)
    for r in $ROLES; do [ -n "$(role_rows "$r")" ] || { echo "role $r reads nothing"; bad=1; }; done
    # The union of the roles' parts is the whole surface, byte for byte.
    union=0
    while IFS='|' read -r id roles _; do
      read_by=0; for r in $ROLES; do in_role "$roles" "$r" && read_by=1; done
      [ "$read_by" = 1 ] && union=$((union + $(text "$id" | wc -c)))
    done < <(rows)
    whole=$(wc -c < "$ROOT/AGENTS.md")
    for s in "$ROOT"/.agents/skills/*/SKILL.md; do whole=$((whole + $(text "skill:$(basename "$(dirname "$s")")" | wc -c))); done
    [ "$union" = "$whole" ] || { echo "union is $union bytes, surface is $whole bytes"; bad=1; }
    [ "$bad" = 0 ] || exit 1
    echo "ok: roles' union = surface ($union bytes), every section and skill read by a named role once"
    ;;
esac

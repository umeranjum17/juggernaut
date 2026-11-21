#!/usr/bin/env bash
# jg-role-pack.sh <all|main|lead|worker|critic> - print the instruction pack for a role.
# Source: docs/roles/rules.tsv (id, section, roles, enforced_by, text). A pack holds, in table order and
# grouped by section, every rule whose roles include the role (or `all`) and whose enforced_by is empty.
# A rule that code enforces goes into no pack; the pack ends with how many such rules were left out.
set -u
role=${1:-}
case "$role" in all|main|lead|worker|critic) ;; *) echo "usage: jg-role-pack.sh <all|main|lead|worker|critic>" >&2; exit 2 ;; esac
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tsv=$root/docs/roles/rules.tsv
[ -r "$tsv" ] || { echo "jg-role-pack: cannot read $tsv" >&2; exit 1; }
awk -F'\t' -v role="$role" '
  NR == 1 { next }
  {
    n = split($3, rs, ",")
    hit = 0
    for (i = 1; i <= n; i++) if (rs[i] == role || rs[i] == "all") hit = 1
    if (!hit) next
    if ($4 != "") { enforced++; next }
    if ($2 != last) { if (last != "") print ""; print "## " $2; last = $2 }
    print "- " $5
  }
  END { print ""; printf "%d rules for this role are enforced by code and not listed.\n", enforced + 0 }
' "$tsv"

#!/usr/bin/env bash
# jg-critic-role.sh - the one migration that gives a legacy critic artifact its critic role.
#
# Usage:
#   jg-critic-role.sh check     list the legacy critic artifacts; exit 1 when there is one, 0 when none
#   jg-critic-role.sh migrate   give each legacy critic artifact its role, once; prints one line per task
#
# A critic task is known to bin/jg-recon-gate.sh by its layout: data/<task>/critic.md names the task itself on its `Critic:` line and
# there is no report.md. Critics briefed before that layout wrote their rounds to report.md, so the gate judged them as a researcher's
# report, refused cleanup, and no later change could give them the role. A legacy critic artifact is a data/<task>/ directory that has
# no critic.md and whose report.md begins with `Critic: <task>` (the task itself) and holds a `Round <n>: new gaps <k>` line. migrate
# renames that report.md to critic.md, in place and without overwriting. A researcher is never touched: its report.md begins with a
# title, a critic.md that names another critic stays as written, and a directory that holds both files is left alone. Running it again
# changes nothing. The data directory is JG_DATA_OVERRIDE, else <JG_HOME>/data. Exit: 0 done, 1 check found one, 2 usage.
set -u
export LC_ALL=C
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JG_HOME=${JG_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}

usage() { sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# legacy_ids: the task ids whose report.md is a critic's own rounds under the researcher's filename.
legacy_ids() {
  local dir id first
  for dir in "$DATA"/*/; do
    dir=${dir%/}; id=${dir##*/}
    [ -f "$dir/report.md" ] && [ ! -e "$dir/critic.md" ] || continue
    first=$(sed -n '/[^[:space:]]/{p;q;}' "$dir/report.md" | sed -n 's/^Critic:[[:space:]]*//p' | tr -d '[:space:]')
    [ -n "$first" ] && [ "$(printf '%s' "$first" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')" ] || continue
    grep -Eq '^Round[[:space:]]+[0-9]+:[[:space:]]*new gaps[[:space:]]+[0-9]+' "$dir/report.md" || continue
    printf '%s\n' "$id"
  done
}

[ "$#" -eq 1 ] || usage
[ -d "$DATA" ] || { echo "jg-critic-role: no data directory at $DATA" >&2; exit 2; }
case "$1" in
  check)
    ids=$(legacy_ids)
    [ -z "$ids" ] || { printf '%s\n' "$ids" | sed 's/$/: report.md is a legacy critic artifact/'; exit 1; }
    echo "no legacy critic artifact"
    ;;
  migrate)
    moved=0
    for id in $(legacy_ids); do
      mv -n -- "$DATA/$id/report.md" "$DATA/$id/critic.md" && [ ! -e "$DATA/$id/report.md" ] \
        || { echo "jg-critic-role: could not rename $DATA/$id/report.md" >&2; exit 1; }
      echo "critic role: $id: report.md -> critic.md"
      moved=$((moved + 1))
    done
    [ "$moved" -gt 0 ] || echo "no legacy critic artifact"
    ;;
  *) usage ;;
esac

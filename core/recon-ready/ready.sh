#!/usr/bin/env bash
# recon-ready watcher check: a Recon that passes its gate raises one alert that names its report and the next items.
# Usage: ready.sh check <jg-home>
#
# For each state/<task>.meta of kind scout whose data/<task>/report.md exists and whose last status line is a
# `done` or a `needs-decision` (the two lines a finished Recon writes), the check runs bin/jg-recon-gate.sh <task>.
# On PASS (an exempt quick Recon counts) it prints one wake line and records state/recon-ready/<task> holding the
# sha256 of the report it announced, so the same report is never announced twice; a revised report is a new one.
# The line names the report, the first Answer line, the first rows of the implementation plan (section 8, the
# next items) and the count of open decisions (section 10). A Recon whose gate refuses prints nothing: the
# refusal is the worker's to fix, and the gate runs again on the next sweep.
# The record is also what core/wait-timers reads: a Recon with this record arms no owner timer.
# Nothing is printed when nothing happened. Seams for tests: JG_RECON_READY_GATE (the gate command).
set -u
export LC_ALL=C
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: ready.sh check <jg-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
STATE=${JG_STATE_OVERRIDE:-$FMH/state}
DATA=${JG_DATA_OVERRIDE:-$FMH/data}
GATE=${JG_RECON_READY_GATE:-$FMH/bin/jg-recon-gate.sh}
OUT=$STATE/recon-ready
umask 077

meta_get() { # <meta-file> <key> -> last value
  local line value=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) value=${line#*=} ;; esac
  done < "$1"
  printf '%s' "$value"
}

# section <report> <n>: the body of "## <n>. ..." up to the next "## " heading.
section() {
  awk -v n="$2" '
    /^## / { on = ($0 ~ "^## " n "\\.") ; next }
    on { print }
  ' "$1"
}

next_items() { # <report>: up to three table rows of section 8, slice names only, joined by "; "
  section "$1" 8 | awk -F'|' '
    /^\|/ && $2 !~ /^[ -]*$/ && tolower($2) !~ /slice/ && n < 3 { gsub(/^ +| +$/, "", $2); items = items (n ? "; " : "") $2; n++ }
    END { print items }'
}

open_decisions() { # <report>: rows of the open decisions table, else numbered or bulleted lines
  section "$1" 10 | awk -F'|' '
    /^\|/ && $2 !~ /^[ -]*$/ && tolower($2) !~ /question/ { n++ }
    /^[-*0-9]/ && !/^\|/ { m++ }
    END { print (n ? n : m + 0) }'
}

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  task=${meta##*/}; task=${task%.meta}
  [ "$(meta_get "$meta" kind)" = scout ] || continue
  report=$DATA/$task/report.md
  [ -f "$report" ] || continue
  last=$(tail -n 1 "$STATE/$task.status" 2>/dev/null) || continue
  case "$last" in done*|needs-decision*) ;; *) continue ;; esac
  sha=$(sha256sum "$report" | cut -d' ' -f1)
  [ "$(cat "$OUT/$task" 2>/dev/null)" != "$sha" ] || continue
  gate=$(JG_HOME=$FMH timeout 20 "$GATE" "$task" 2>&1) || continue
  case "$gate" in *PASS*|*exempt*) ;; *) continue ;; esac
  answer=$(section "$report" 1 | sed '/^[[:space:]]*$/d' | head -n 1 | cut -c1-200)
  items=$(next_items "$report")
  mkdir -p "$OUT" 2>/dev/null || exit 0
  printf '%s\n' "$sha" > "$OUT/$task.tmp.$$" && mv "$OUT/$task.tmp.$$" "$OUT/$task"
  printf 'recon-ready: %s report is ready at data/%s/report.md; answer: %s; next items: %s; open decisions: %s\n' \
    "$task" "$task" "${answer:-none written}" "${items:-none listed}" "$(open_decisions "$report")"
done
exit 0

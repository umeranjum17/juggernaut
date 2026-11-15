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
# Follow-up stated ahead: a Recon's ticket body may say `on-report: triage-build <harness> <model> <effort>`.
# For a Recon whose report passed its gate, `jg-backlog.sh on-report <ticket>` prints the route only when the
# ticket rests on a record of the captain's yes; then, with no open decision blocking the ticket
# (`jg-captain-hold.sh blocking`) and none listed in the report, this check files the report's first slice under
# the ticket (`born-from: recon`, parent the ticket) and approves it for dispatch on that route
# (`jg-backlog.sh approve-dispatch`). core/auto-dispatch then starts it under the lane target and the quota gates,
# which stay in force. state/on-report/<task> records the slice so the follow-up runs once; a failed step prints
# one line and is tried again on the next sweep. The follow-up is its own pass, so a held call that clears runs it.
# Nothing is printed when nothing happened. Seams for tests: JG_RECON_READY_GATE (the gate command),
# JG_RECON_READY_BACKLOG and JG_RECON_READY_HOLD (the backlog and captain-hold commands).
set -u
export LC_ALL=C
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: ready.sh check <jg-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
STATE=${JG_STATE_OVERRIDE:-$FMH/state}
DATA=${JG_DATA_OVERRIDE:-$FMH/data}
GATE=${JG_RECON_READY_GATE:-$FMH/bin/jg-recon-gate.sh}
OUT=$STATE/recon-ready
FOLLOW=$STATE/on-report
BACKLOG=${JG_RECON_READY_BACKLOG:-$FMH/bin/jg-backlog.sh}
HOLD=${JG_RECON_READY_HOLD:-$FMH/bin/jg-captain-hold.sh}
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

first_item() { next_items "$1" | cut -d';' -f1 | sed 's/^ *//'; }

# follow_up <task> <report>: the follow-up stated ahead, once, for a report this check has announced.
follow_up() {
  local task=$1 report=$2 ticket route name slice out harness model effort
  [ ! -e "$FOLLOW/$task" ] || return 0
  ticket=$(meta_get "$STATE/$task.meta" ticket); ticket=${ticket:-$task}
  route=$(JG_HOME=$FMH "$BACKLOG" on-report "$ticket" 2>/dev/null) || return 0
  JG_HOME=$FMH "$HOLD" blocking "$ticket" >/dev/null 2>&1 && return 0
  [ "$(open_decisions "$report")" = 0 ] || return 0
  name=$(first_item "$report")
  [ -n "$name" ] || { printf 'on-report: %s has no first slice in section 8 of its report\n' "$ticket"; return 0; }
  out=$(JG_HOME=$FMH "$BACKLOG" add --parent "$ticket" "[feature] $name" \
    --body "First slice of the report at data/$task/report.md: $name"$'\n'"born-from: recon"$'\n'"parent: $ticket" 2>&1) \
    || { printf 'on-report: %s: the first slice was not filed: %s\n' "$ticket" "$(printf '%s' "$out" | head -n 1 | cut -c1-200)"; return 0; }
  slice=$(printf '%s\n' "$out" | grep -Eo "$ticket\.[0-9]+" | head -n 1)
  [ -n "$slice" ] || { printf 'on-report: %s: the filed slice id was not readable, so it was not approved\n' "$ticket"; return 0; }
  read -r harness model effort <<< "$route"
  JG_HOME=$FMH "$BACKLOG" approve-dispatch "$slice" --harness "$harness" --model "$model" --effort "$effort" >/dev/null 2>&1 \
    || { printf 'on-report: %s: slice %s is filed but its approval failed\n' "$ticket" "$slice"; return 0; }
  mkdir -p "$FOLLOW" 2>/dev/null && printf '%s\n' "$slice" > "$FOLLOW/$task"
  printf 'on-report: %s follow-up ran: slice %s filed and approved for dispatch on %s\n' "$ticket" "$slice" "$route"
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
  if [ "$(cat "$OUT/$task" 2>/dev/null)" = "$sha" ]; then follow_up "$task" "$report"; continue; fi
  gate=$(JG_HOME=$FMH timeout 20 "$GATE" "$task" 2>&1) || continue
  case "$gate" in *PASS*|*exempt*) ;; *) continue ;; esac
  answer=$(section "$report" 1 | sed '/^[[:space:]]*$/d' | head -n 1 | cut -c1-200)
  items=$(next_items "$report")
  mkdir -p "$OUT" 2>/dev/null || exit 0
  printf '%s\n' "$sha" > "$OUT/$task.tmp.$$" && mv "$OUT/$task.tmp.$$" "$OUT/$task"
  printf 'recon-ready: %s report is ready at data/%s/report.md; answer: %s; next items: %s; open decisions: %s\n' \
    "$task" "$task" "${answer:-none written}" "${items:-none listed}" "$(open_decisions "$report")"
  follow_up "$task" "$report"
done
exit 0

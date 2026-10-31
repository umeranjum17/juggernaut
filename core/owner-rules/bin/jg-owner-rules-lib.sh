#!/usr/bin/env bash
# jg-owner-rules-lib.sh - brief-time owner rules for a lane. Source only.
#
# brief-inherit's jg_brief_inherit_shared sources this and calls
#   jg_owner_rules_check <data-dir> <task-id> <mode> <kind>
# when owner-rules/wiring.sh wrote config/owner-rules. It reads the home's backlog entry whose id
# is the task id and exits 1, before jg-brief.sh writes anything, when the lane breaks a rule.
# The no-mistakes risk reason is not checked here: bin/jg-brief.sh owns it with --risk, so one
# rule has one owner.

# Design flag: a body line "design: required|none" on the backlog entry. required adds the brief record to
# BRIEF_INCLUDE_BODY (jg-brief.sh prints it under "Home brief additions"); a design-like line that is not exact
# is refused; no line on design-sounding work only prints a note. Never blocks otherwise.
jg_owner_rules_design() {
  local id=$1 entry=$2 body lines exact
  body=$(printf '%s\n' "$entry" | tail -n +2)
  lines=$(printf '%s\n' "$body" | grep -Eic '^[[:space:]]*(design|desing|desgin|designs|design[ _-]discovery)[[:space:]]*:') || true
  exact=$(printf '%s\n' "$body" | grep -Ec '^[[:space:]]*design:[[:space:]]*(required|none)[[:space:]]*$') || true
  if [ "$lines" -ne "$exact" ] || [ "$exact" -gt 1 ]; then
    echo "owner-rules: design: must be required or none (backlog item for $id)" >&2
    exit 1
  fi
  if [ "$exact" -eq 0 ]; then
    if printf '%s\n' "$entry" | grep -Eiq '\b(redesign|landing page|new screen|mock-?up|prototype|first draft)\b'; then
      echo "owner-rules: note: this reads like design work; add \"design: required\" or \"design: none\" to the backlog item for $id" >&2
    fi
  elif printf '%s\n' "$body" | grep -Eq '^[[:space:]]*design:[[:space:]]*required[[:space:]]*$'; then
    BRIEF_INCLUDE_BODY="Design discovery: required${BRIEF_INCLUDE_BODY:+$'\n'}${BRIEF_INCLUDE_BODY:-}"
  fi
}

jg_owner_rules_check() {
  # $3 (the delivery mode) is part of the caller contract; the risk reason it
  # used to read is bin/jg-brief.sh --risk now, so this check never needs it.
  local data=$1 id=$2 kind=$4 entry title parent exists
  [ "$kind" != squad_lead ] || return 0
  # Entry = the "- [.] <id> - <title>" line and its indented body, up to the next item or heading.
  entry=$(awk -v id="$id" '
    /^- \[.\] / { on = (substr($0, 7, length(id) + 1) == id " ") } /^## / { on = 0 } on' "$data/backlog.md" 2>/dev/null)
  title=$(printf '%s\n' "$entry" | head -n 1)
  title=${title#*"$id"}
  title=${title# - }
  if [[ $title != '[captain-ask]'* ]] && ! printf '%s\n' "$entry" | grep -Eq '(^|[^[:alnum:]])Main[0-9]+'; then
    echo "owner-rules: no owner ask: name the [captain-ask] item or the MainNNN order this lane serves (add it to the backlog item for $id)" >&2
    exit 1
  fi
  if [ "$kind" != scout ] && [[ $title != '[captain-ask]'* ]]; then
    parent=$(printf '%s\n' "$entry" | awk '/^[[:space:]]*parent:[[:space:]]*/ { sub(/^[[:space:]]*parent:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit }')
    exists=0
    if [ "$parent" = upkeep ]; then
      exists=1
    elif [ -n "$parent" ]; then
      exists=$(awk -v id="$parent" '/^- \[[^]]\] / { row = substr($0, 7); split(row, fields, /[[:space:]]+/); if (fields[1] == id) found = 1 } END { print found + 0 }' "$data/backlog.md" 2>/dev/null)
    fi
    if [ "$exists" -ne 1 ]; then
      echo "owner-rules: no valid parent: add parent: <backlog item id> or parent: upkeep to the backlog item for $id" >&2
      exit 1
    fi
  fi
  jg_owner_rules_design "$id" "$entry"
}

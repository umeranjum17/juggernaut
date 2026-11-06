#!/usr/bin/env bash
# jg-owner-rules-lib.sh - brief-time owner rules for a lane. Source only.
#
# brief-inherit's jg_brief_inherit_shared sources this and calls
#   jg_owner_rules_check <data-dir> <task-id> <mode> <kind>
# when owner-rules/wiring.sh wrote config/owner-rules. It reads the home's backlog entry whose id
# is the task id and exits 1, before jg-brief.sh writes anything, when the lane breaks a rule.
# The no-mistakes risk reason is not checked here: bin/jg-brief.sh owns it with --risk, so one
# rule has one owner.
# The rules are policy/gate/brief_rules.rego and policy/gate/rules.json: this reads the item into facts, asks the
# one evaluator, and prints the message for the reason it gives. An evaluator that cannot run refuses like a rule does.

jg_owner_rules_check() {
  # $3 (the delivery mode) is part of the caller contract; the risk reason it
  # used to read is bin/jg-brief.sh --risk now, so this check never needs it.
  local data=$1 id=$2 kind=$4 entry title ids verdict bin config backlog=
  bin=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)/bin
  config=${JG_CONFIG_OVERRIDE:-${JG_HOME:-${data%/*}}/config}
  # shellcheck source=bin/jg-tasks-axi-lib.sh
  # shellcheck disable=SC1091
  . "$bin/jg-tasks-axi-lib.sh"
  if jg_backlog_present "$config" "$data/backlog.md" && ! backlog=$(jg_backlog_text "$config" "$data/backlog.md" 2>/dev/null); then
    echo "owner-rules: cannot read the backlog for $id" >&2
    exit 1
  fi
  # Entry = the "- [.] <id> - <title>" line and its indented body, up to the next item or heading.
  entry=$(awk -v id="$id" '
    /^- \[.\] / { on = (substr($0, 7, length(id) + 1) == id " ") } /^## / { on = 0 } on' <<<"$backlog")
  title=$(printf '%s\n' "$entry" | head -n 1)
  title=${title#*"$id"}
  title=${title# - }
  ids=$(awk '/^- \[[^]]\] / { row = substr($0, 7); split(row, fields, /[[:space:]]+/); print fields[1] }' <<<"$backlog")
  if ! verdict=$(jq -n --arg id "$id" --arg kind "$kind" --arg title "$title" \
    --argjson lines "$(printf '%s\n' "$entry" | jq -Rsc 'split("\n")[:-1]')" --argjson ids "$(printf '%s\n' "$ids" | jq -Rsc 'split("\n") | map(select(. != ""))')" \
    '{id: $id, kind: $kind, title: $title, entry_lines: $lines, ids: $ids}' | "$bin/jg-guard-host.sh" eval gate.brief_rules 2>&1); then
    echo "owner-rules: cannot evaluate the brief rules for $id: ${verdict:-no answer}" >&2
    exit 1
  fi
  case $(jq -r '.why' <<<"$verdict") in
    no_ask) echo "owner-rules: no owner ask: name the [captain-ask] item or the MainNNN order this lane serves (add it to the backlog item for $id)" >&2; exit 1 ;;
    no_parent) echo "owner-rules: no valid parent: add parent: <backlog item id> or parent: upkeep to the backlog item for $id" >&2; exit 1 ;;
    bad_design) echo "owner-rules: design: must be required or none (backlog item for $id)" >&2; exit 1 ;;
  esac
  if [ "$(jq -r '.note // false' <<<"$verdict")" = true ]; then
    echo "owner-rules: note: this reads like design work; add \"design: required\" or \"design: none\" to the backlog item for $id" >&2
  fi
  local include
  include=$(jq -r '.include // ""' <<<"$verdict")
  [ -z "$include" ] || BRIEF_INCLUDE_BODY="$include${BRIEF_INCLUDE_BODY:+$'\n'}${BRIEF_INCLUDE_BODY:-}"
}

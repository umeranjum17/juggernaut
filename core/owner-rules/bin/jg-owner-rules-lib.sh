#!/usr/bin/env bash
# jg-owner-rules-lib.sh - brief-time owner rules for a lane. Source only.
#
# brief-inherit's jg_brief_inherit_shared sources this and calls
#   jg_owner_rules_check <data-dir> <task-id> <mode> <kind>
# when owner-rules/wiring.sh wrote config/owner-rules. It reads the home's backlog entry whose id
# is the task id and exits 1, before jg-brief.sh writes anything, when the lane breaks a rule.
# The no-mistakes risk reason is not checked here: bin/jg-brief.sh owns it with --risk, so one
# rule has one owner.
# The row's parent is read from the store (`show --json`): the target of its parent-child edge, or upkeep for that
# label, with the row's labels, so a row that has the edge needs no parent: line in its body.
# The rules are policy/gate/brief_rules.rego and policy/gate/rules.json: this reads the item into facts, asks the
# one evaluator, and prints the message for the reason it gives. An evaluator that cannot run refuses like a rule does.

jg_owner_rules_check() {
  # $3 (the delivery mode) is part of the caller contract; the risk reason it
  # used to read is bin/jg-brief.sh --risk now, so this check never needs it.
  local data=$1 id=$2 kind=$4 entry title ids verdict bin config backlog='' store row='[]' facts
  bin=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)/bin
  config=${JG_CONFIG_OVERRIDE:-${JG_HOME:-${data%/*}}/config}
  # shellcheck source=bin/jg-backlog-lib.sh
  # shellcheck disable=SC1091
  . "$bin/jg-backlog-lib.sh"
  if ! backlog=$(jg_backlog_text "$config" 2>/dev/null); then
    echo "owner-rules: cannot read the backlog for $id" >&2
    exit 1
  fi
  if store=$(jg_backlog_beads_store "$config" 2>/dev/null); then
    row=$(BEADS_DIR=$store "$bin/jg-beads.sh" show "$id" --json 2>/dev/null) || row='[]'
  fi
  facts=$(jq -c '(if type == "array" then .[0] else . end) // {}
    | {labels: (.labels // []), parent: ((.dependencies // [] | map(select(.dependency_type == "parent-child"))[0].id)
        // (if (.labels // [] | index("upkeep")) then "upkeep" else "" end))}' <<<"$row" 2>/dev/null) || facts='{"labels":[],"parent":""}'
  # Entry = the "- [.] <id> - <title>" line and its indented body, up to the next item or heading.
  entry=$(awk -v id="$id" '
    /^- \[.\] / { on = (substr($0, 7, length(id) + 1) == id " ") } /^## / { on = 0 } on' <<<"$backlog")
  title=$(printf '%s\n' "$entry" | head -n 1)
  title=${title#*"$id"}
  title=${title# - }
  ids=$(awk '/^- \[[^]]\] / { row = substr($0, 7); split(row, fields, /[[:space:]]+/); print fields[1] }' <<<"$backlog")
  # Backlog arrays travel on stdin: even one argv element is size-limited on a large home.
  if ! verdict=$(
    set -o pipefail
    {
      printf '%s\n' "$entry" | jq -Rsc 'split("\n")[:-1]'
      printf '%s\n' "$ids" | jq -Rsc 'split("\n") | map(select(. != ""))'
    } | jq -s --arg id "$id" --arg kind "$kind" --arg title "$title" --argjson facts "$facts" \
      '{id: $id, kind: $kind, title: $title, entry_lines: .[0], ids: .[1]} + $facts' | "$bin/jg-guard-host.sh" eval gate.brief_rules 2>&1
  ); then
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

#!/usr/bin/env bash
# jg-plan-gate.sh - the gate of a dependency that one store cannot see, and a plan's approval on each slice.
#
# Usage: jg-plan-gate.sh add <row> --waits-for <home>:<row-id>
#        jg-plan-gate.sh add <row> --tool <name> --min <version>
#        jg-plan-gate.sh close
#        jg-plan-gate.sh approve <plan.json> --harness <h> --model <m> --effort <e>
#        jg-plan-gate.sh --help
#
# add: a row that waits for a row of another home, or for a tool version, gets a Beads gate in this
#   home's store (the row leaves `ready` until the gate closes). The gate is the whole record: its title
#   names the condition, `plan-gate: home <home> row <id>` or `plan-gate: tool <name> >= <version>`.
#   <home> is `main` or a Squad Lead id; it is read through Main's registry (data/squad_leads.md), from any home.
#   Refused, nothing written: a row that is not in this store, an unknown home, a home that is this one, a remote
#   Squad Lead, a malformed condition, and a gate for the same condition that is open already.
# close: the tick's pass (core/plan-gate/check.sh). For each open gate of this kind it reads the condition and
#   resolves the gate when it holds: the other home's row is closed, or the tool reports at least that version.
#   In Main's home it also passes over every local Squad Lead home, so a lead's row that waits for a row of Main
#   is closed by Main's tick. A condition that cannot be read (a home with no store, a tool not installed) leaves
#   the gate open and is named on stderr. Prints one line for each gate it closed and nothing else.
# approve: the owner's yes to a plan file, written on each slice of that file as the dispatch approval record
#   (`bin/jg-backlog.sh approve-dispatch`, the record core/auto-dispatch reads), in the home that owns the slice.
#   Only a slice of the file is approved: a slice added to the plan's row later has no record. Only Main
#   approves; a Squad Lead home refuses. A slice not filed yet in its owner's store refuses the whole approval,
#   with nothing written (every owner is read before the first record).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
# shellcheck source=bin/jg-compat.sh disable=SC1091
. "$SCRIPT_DIR/jg-compat.sh"
# shellcheck source=bin/jg-backlog-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-backlog-lib.sh"
# shellcheck source=bin/jg-squad-lead-registry-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-squad-lead-registry-lib.sh"
# shellcheck source=bin/jg-squad-lead-parent-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-squad-lead-parent-lib.sh"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
fail() { printf 'jg-plan-gate: %s\n' "$*" >&2; exit 2; }
warn() { printf 'jg-plan-gate: %s\n' "$*" >&2; }

# The name of a home: `main`, or the id its marker holds.
home_name() { local m; m=$(jg_compat_marker "$1"); if [ -r "$m" ]; then tr -d '[:space:]' < "$m"; else printf 'main'; fi; }

# Main's home as seen from <home>: itself, or the parent its parent record names.
main_home() {  # <home>
  if [ ! -e "$(jg_compat_marker "$1")" ]; then printf '%s\n' "$1"; return 0; fi
  jg_squad_lead_parent_record_parse "$(jg_compat_parent_marker "$1")" && [ "$JG_SQUAD_LEAD_PARENT_ROUTE" = local ] || return 1
  printf '%s\n' "$JG_SQUAD_LEAD_PARENT_HOME"
}

# The directory of the home named <name>, seen from <from>; refuses with the reason on stderr.
home_dir() {  # <name> <from-home>
  local name=$1 main
  main=$(main_home "$2") || { warn "the home $2 has no readable local parent: its gates cannot name another home"; return 1; }
  [ "$name" != main ] || { printf '%s\n' "$main"; return 0; }
  case $name in *[!A-Za-z0-9._-]*) warn "$name is not a home name"; return 1 ;; esac
  squad_lead_registry_line_for_id "$(jg_compat_pick "$main/data/squad_leads.md")" "$name" \
    || { warn "home $name is neither main nor a Squad Lead registered in $main/data/squad_leads.md"; return 1; }
  [ "$SQUAD_LEAD_REGISTRY_REMOTE" = 0 ] || { warn "home $name is a remote Squad Lead: its rows cannot be read from here"; return 1; }
  [ -d "$SQUAD_LEAD_REGISTRY_HOME" ] || { warn "the home of $name does not exist: $SQUAD_LEAD_REGISTRY_HOME"; return 1; }
  printf '%s\n' "$SQUAD_LEAD_REGISTRY_HOME"
}

# bd in a home's own store, with that home's own config.
bd_in() {  # <home> <bd args...>
  local store h=$1
  shift
  store=$(jg_backlog_beads_store "$h/config") || return 2
  BEADS_DIR=$store "$SCRIPT_DIR/jg-beads.sh" "$@" 2>/dev/null
}

cmd_add() {
  local row='' waits='' tool='' min='' title out
  while [ $# -gt 0 ]; do
    case $1 in
      --waits-for) [ $# -ge 2 ] || fail "--waits-for needs <home>:<row-id>"; waits=$2; shift ;;
      --tool) [ $# -ge 2 ] || fail "--tool needs a name"; tool=$2; shift ;;
      --min) [ $# -ge 2 ] || fail "--min needs a version"; min=$2; shift ;;
      -*) fail "add: unknown flag $1" ;;
      *) [ -z "$row" ] || fail "add takes one row"; row=$1 ;;
    esac
    shift
  done
  [ -n "$row" ] || fail "usage: add <row> --waits-for <home>:<row-id> | --tool <name> --min <version>"
  if [ -n "$waits" ]; then
    [ -z "$tool$min" ] || fail "give --waits-for or --tool --min, not both"
    case $waits in *:*) ;; *) fail "--waits-for needs <home>:<row-id>, got $waits" ;; esac
    local other=${waits%%:*} oid=${waits#*:}
    case $oid in ''|*[!A-Za-z0-9._-]*) fail "$oid is not a row id" ;; esac
    [ "$other" != "$(home_name "$JG_HOME")" ] || fail "$other is this home: a row of this store is an edge, not a gate"
    home_dir "$other" "$JG_HOME" >/dev/null || fail "no gate written"
    title="plan-gate: home $other row $oid"
  else
    [ -n "$tool" ] && [ -n "$min" ] || fail "a tool gate needs --tool <name> and --min <version>"
    case $tool in ''|*[!A-Za-z0-9._-]*) fail "$tool is not a tool name" ;; esac
    printf '%s\n' "$min" | grep -Eq '^[0-9]+(\.[0-9]+)*$' || fail "--min $min is not a version like 0.6.27"
    title="plan-gate: tool $tool >= $min"
  fi
  bd_in "$JG_HOME" show "$row" --json >/dev/null || fail "no row $row in this home's store"
  bd_in "$JG_HOME" gate list --json | jq -e --arg t "$title" 'any(.[]; .title == $t)' >/dev/null 2>&1 \
    && fail "$row already waits on: ${title#plan-gate: }"
  out=$(bd_in "$JG_HOME" gate create --blocks "$row" --title "$title" --reason "${title#plan-gate: }") || fail "bd refused the gate: $out"
  printf 'gated %s on %s\n' "$row" "${title#plan-gate: }"
}

# 0 when the condition of the gate title holds now; 1 when it does not; 2 when it cannot be read (reason on stderr).
condition_holds() {  # <title> <home the gate is in>
  local t=${2:-} spec=${1#plan-gate: } other oid dir status tool min have
  case $spec in
    "home "*" row "*)
      other=${spec#home }; other=${other%% row *}; oid=${spec##* row }
      dir=$(home_dir "$other" "$t") || return 2
      status=$(bd_in "$dir" show "$oid" --json | jq -r '.[0].status // empty') || status=
      [ -n "$status" ] || { warn "cannot read row $oid in home $other"; return 2; }
      [ "$status" = closed ] ;;
    "tool "*" >= "*)
      tool=${spec#tool }; tool=${tool%% >= *}; min=${spec##* >= }
      command -v "$tool" >/dev/null 2>&1 || { warn "tool $tool is not installed"; return 2; }
      have=$("$tool" --version 2>&1 | grep -Eo '[0-9]+(\.[0-9]+)+' | head -n 1)
      [ -n "$have" ] || { warn "tool $tool prints no version"; return 2; }
      [ "$(printf '%s\n%s\n' "$min" "$have" | sort -V | head -n 1)" = "$min" ] ;;
    *) warn "unreadable gate condition: $spec"; return 2 ;;
  esac
}

close_in() {  # <home>: resolve this home's gates whose condition holds
  local h=$1 gate id title
  gate=$(bd_in "$h" gate list --json) || { warn "cannot list the gates of $h"; return 0; }
  while IFS=$'\t' read -r id title; do
    [ -n "$id" ] || continue
    if condition_holds "$title" "$h"; then
      bd_in "$h" gate resolve "$id" --reason "${title#plan-gate: } holds" >/dev/null && printf 'closed %s in %s: %s\n' "$id" "$(home_name "$h")" "${title#plan-gate: }"
    fi
  done < <(printf '%s\n' "$gate" | jq -r '.[] | select(.status == "open" and (.title | startswith("plan-gate: "))) | [.id, .title] | @tsv' 2>/dev/null)
}

cmd_close() {
  [ $# -eq 0 ] || fail "close takes no argument"
  close_in "$JG_HOME"
  [ ! -e "$(jg_compat_marker "$JG_HOME")" ] || return 0
  local id reg
  reg=$(jg_compat_pick "$DATA/squad_leads.md")
  [ -r "$reg" ] || return 0
  while read -r id; do
    squad_lead_registry_line_for_id "$reg" "$id" || continue
    [ "$SQUAD_LEAD_REGISTRY_REMOTE" = 0 ] && [ -d "$SQUAD_LEAD_REGISTRY_HOME" ] || continue
    close_in "$SQUAD_LEAD_REGISTRY_HOME"
  done < <(sed -n 's/^- \([A-Za-z0-9._-]*\) - .*/\1/p' "$reg")
}

cmd_approve() {
  local plan='' harness='' model='' effort='' owner dir epic rows slice id
  [ ! -e "$(jg_compat_marker "$JG_HOME")" ] || fail "this is a Squad Lead home: only Main approves a plan"
  while [ $# -gt 0 ]; do
    case $1 in
      --harness) [ $# -ge 2 ] || fail "--harness needs a value"; harness=$2; shift ;;
      --model) [ $# -ge 2 ] || fail "--model needs a value"; model=$2; shift ;;
      --effort) [ $# -ge 2 ] || fail "--effort needs a value"; effort=$2; shift ;;
      -*) fail "approve: unknown flag $1" ;;
      *) [ -z "$plan" ] || fail "approve takes one plan file"; plan=$1 ;;
    esac
    shift
  done
  [ -n "$plan" ] && [ -n "$harness" ] && [ -n "$model" ] && [ -n "$effort" ] \
    || fail "usage: approve <plan.json> --harness <h> --model <m> --effort <e>"
  [ -r "$plan" ] || fail "cannot read $plan"
  jq -e '(.slices // []) | length > 0' "$plan" >/dev/null 2>&1 || fail "$plan is not a plan file with slices"
  epic=$(jq -r '.plan // empty' "$plan"); [ -n "$epic" ] || fail "the plan file names no plan row (.plan)"
  # Read every owner first: the rows to approve are the filed rows of the plan's slices.
  local -a todo=()
  while read -r owner; do
    dir=$(home_dir "$owner" "$JG_HOME") || fail "owner $owner: nothing approved"
    rows=$(bd_in "$dir" list --parent "$epic" --all --limit 0 --json) || fail "owner $owner: cannot read the plan's rows; nothing approved"
    while read -r slice; do
      id=$(printf '%s\n' "$rows" | jq -r --arg s "$slice" '[.[] | select(.metadata.plan_slice == $s)][0].id // empty')
      [ -n "$id" ] || fail "slice $slice is not filed in home $owner under $epic: file the plan first; nothing approved"
      todo+=("$dir	$id")
    done < <(jq -r --arg o "$owner" '.slices[] | select(.owner_home == $o) | .id' "$plan")
  done < <(jq -r '[.slices[].owner_home] | unique[]' "$plan")
  local entry
  for entry in "${todo[@]}"; do
    dir=${entry%%$'\t'*}; id=${entry#*$'\t'}
    env -u JG_CONFIG_OVERRIDE -u JG_STATE_OVERRIDE -u JG_DATA_OVERRIDE -u JG_ROOT_OVERRIDE JG_HOME="$dir" \
      "$SCRIPT_DIR/jg-backlog.sh" approve-dispatch "$id" --harness "$harness" --model "$model" --effort "$effort" \
      || fail "approving $id in $dir failed; earlier slices of this plan are approved"
  done
  printf 'approved %s slices of %s\n' "${#todo[@]}" "$epic"
}

case "${1:-}" in
  -h|--help|'') usage ;;
  add) shift; cmd_add "$@" ;;
  close) shift; cmd_close "$@" ;;
  approve) shift; cmd_approve "$@" ;;
  *) fail "unknown command $1 (add, close, approve)" ;;
esac

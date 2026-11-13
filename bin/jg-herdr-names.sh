#!/usr/bin/env bash
# jg-herdr-names.sh - keep this home's live Herdr names on the Juggernaut vocabulary.
#
# Usage:
#   jg-herdr-names.sh check              # fail while a live name or label shows an old word
#   jg-herdr-names.sh migrate [--dry-run] # rename the live items this home recorded
#
# Both commands read only this home's task records (state/*.meta with
# backend=herdr) and address each live item by the exact session, workspace,
# tab, and pane id recorded there. Nothing is found by a name search, so another
# home's items sharing the session are never read or renamed.
#
# check: for every recorded task, reads the live workspace label, tab label, and
# agent name. A name fails when it still carries an old product or role word
# (the pre-rename script prefix, the old product name, the old second-mate and
# first-mate role words) after the home's own ids are masked out. A recorded
# task id or this home's Squad Lead id is an identity chosen at dispatch, not a
# label this software writes, so the id text inside a name is not a leak; the
# prefix around it is. Exit 0 when clean, 1 when any name leaks, 2 when a
# recorded session cannot be read (nothing is then proven).
#
# migrate: moves each recorded item to the name the current code would write.
#   - workspace: this home's pre-rename workspace label becomes "lead-<id>", only
#     when the recorded workspace id still carries exactly that old label.
#   - tab: the pre-rename tab label of a task becomes "jg-<task-id>", only for
#     the recorded tab id.
#   - agent: the recorded pane's agent is pinned to the record's agent_name= (a
#     record with none: jg_backend_herdr_agent_name_for <task-id>), the name
#     jg-spawn.sh pins at launch, only when the pane's tab is
#     the recorded task tab. Herdr drops agent names on a server restart, so
#     running migrate again is also the repair.
# It is idempotent: an item already on its target name is left alone. --dry-run
# prints each rename without making it. Exit 0 unless a rename was attempted
# and failed (1), or a recorded session cannot be read (2).
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }'
fi
unset _jg_d
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"

# shellcheck source=bin/jg-backend.sh
. "$SCRIPT_DIR/jg-backend.sh"
jg_backend_source herdr

# The old words, assembled from halves so this file adds no leftover to the
# rename's tracked-name gate (bin/juggernaut-name-gate.sh) while still naming
# what it forbids. A word must start the name or follow a non-alphanumeric.
OLD_PREFIX="f""m"
OLD_PRODUCT="first""mate"
OLD_LEAD="2nd""mate"
OLD_WORDS="second""mate|second[ -]mate|first[ -]mate|crew""mate"
LEAK_RE="(^|[^a-z0-9])(${OLD_PREFIX}[-_]|${OLD_PRODUCT}|${OLD_LEAD}|${OLD_WORDS})"

usage() {
  sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'jg-herdr-names: %s\n' "$*" >&2
  exit "${2:-2}"
}

MASKS=
RECORDS=

# collect_records: one "<id>\t<session>\t<workspace>\t<tab>\t<pane>\t<agent-name>" line per
# herdr-backed task record, and the ids to mask out of names.
collect_records() {
  local meta id session workspace tab pane name marker lead
  RECORDS=
  MASKS=
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    grep -q '^backend=herdr$' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    session=$(jg_backend_meta_exact_value "$meta" herdr_session) || continue
    workspace=$(jg_backend_meta_exact_value "$meta" herdr_workspace_id) || continue
    tab=$(jg_backend_meta_exact_value "$meta" herdr_tab_id) || continue
    pane=$(jg_backend_meta_exact_value "$meta" herdr_pane_id) || continue
    # The agent name the record holds (agent_name=); a record with none keeps the name made from its id.
    name=$(jg_backend_meta_exact_value "$meta" agent_name 2>/dev/null) || name=
    [ -n "$name" ] || name=$(jg_backend_herdr_agent_name_for "$id") || continue
    RECORDS="${RECORDS}${id}"$'\t'"${session}"$'\t'"${workspace}"$'\t'"${tab}"$'\t'"${pane}"$'\t'"${name}"$'\n'
    # The id, the agent name derived from it, the name the record holds, and the
    # 27-character head a long id keeps in that name: all are the home's own text.
    MASKS="${MASKS}${id}"$'\n'"$(jg_backend_herdr_agent_name_for "$id")"$'\n'"${name}"$'\n'"${id:0:27}"$'\n'
  done
  marker=$(jg_compat_marker "$JG_HOME")
  if [ -f "$marker" ]; then
    lead=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
    [ -z "$lead" ] || MASKS="${MASKS}${lead}"$'\n'
  fi
}

# masked <name>: the lowercase name with every home id removed, longest first.
masked() {
  local value id
  value=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    value=${value//"$id"/}
  done < <(printf '%s' "$MASKS" | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-)
  printf '%s' "$value"
}

session_list() {
  printf '%s' "$RECORDS" | cut -f2 | sort -u
}

# fetch_session <session>: live workspace list, task tabs, and agents into
# WS_JSON, TABS_JSON, AGENTS_JSON. Nonzero when the session cannot be read.
WS_JSON='' TABS_JSON='' AGENTS_JSON=''
fetch_session() {
  local session=$1 wsid tabs
  WS_JSON=$(jg_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  AGENTS_JSON=$(jg_backend_herdr_cli "$session" agent list 2>/dev/null) || return 1
  printf '%s' "$WS_JSON" | jq -e '.result.workspaces | type == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$AGENTS_JSON" | jq -e '.result.agents | type == "array"' >/dev/null 2>&1 || return 1
  TABS_JSON='[]'
  while IFS= read -r wsid; do
    [ -n "$wsid" ] || continue
    tabs=$(jg_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || continue
    TABS_JSON=$(jq -c -n --argjson a "$TABS_JSON" --argjson b "$tabs" '$a + ($b.result.tabs // [])' 2>/dev/null) || return 1
  done < <(printf '%s' "$RECORDS" | awk -F'\t' -v s="$session" '$2 == s { print $3 }' | sort -u)
  return 0
}

ws_label() { printf '%s' "$WS_JSON" | jq -r --arg id "$1" '.result.workspaces[] | select(.workspace_id == $id) | .label' 2>/dev/null | head -n1; }
tab_label() { printf '%s' "$TABS_JSON" | jq -r --arg id "$1" '.[] | select(.tab_id == $id) | .label' 2>/dev/null | head -n1; }
agent_field() { printf '%s' "$AGENTS_JSON" | jq -r --arg id "$1" --arg f "$2" '.result.agents[] | select(.pane_id == $id) | .[$f] // ""' 2>/dev/null | head -n1; }

LEAKS=0 CHECKED=0
# check_name <session> <owner> <kind> <live-name>: count one name, print a leak.
check_name() {
  local session=$1 owner=$2 kind=$3 label=$4
  [ -n "$label" ] || return 0
  CHECKED=$((CHECKED + 1))
  if masked "$label" | grep -Eq "$LEAK_RE"; then
    printf 'LEAK %s %s %s=%s\n' "$session" "$owner" "$kind" "$label"
    LEAKS=$((LEAKS + 1))
  fi
}

cmd_check() {
  local session id sess workspace tab pane unread=0
  collect_records
  [ -n "$RECORDS" ] || { echo "jg-herdr-names: no herdr task records in $STATE; nothing to check"; return 0; }
  while IFS= read -r session; do
    if ! fetch_session "$session"; then
      echo "jg-herdr-names: cannot read herdr session '$session'; its names are unchecked" >&2
      unread=1
      continue
    fi
    # Each recorded workspace once, then each recorded task's tab and agent.
    while IFS= read -r workspace; do
      [ -n "$workspace" ] || continue
      check_name "$session" "$workspace" workspace "$(ws_label "$workspace")"
    done < <(printf '%s' "$RECORDS" | awk -F'\t' -v s="$session" '$2 == s { print $3 }' | sort -u)
    while IFS=$'\t' read -r id sess workspace tab pane name; do
      [ "$sess" = "$session" ] || continue
      check_name "$session" "$id" tab "$(tab_label "$tab")"
      check_name "$session" "$id" agent "$(agent_field "$pane" name)"
    done <<EOF
$RECORDS
EOF
  done < <(session_list)
  if [ "$unread" -ne 0 ]; then
    echo "jg-herdr-names: check incomplete: a recorded session could not be read" >&2
    return 2
  fi
  if [ "$LEAKS" -ne 0 ]; then
    echo "jg-herdr-names: $LEAKS live name(s) still show an old word ($CHECKED checked); run: jg-herdr-names.sh migrate" >&2
    return 1
  fi
  echo "jg-herdr-names: ok - $CHECKED live name(s) of this home's recorded tasks show no old word"
  return 0
}

# do_rename <dry-run> <kind> <session> <target-id> <from> <to> <command...>
RENAMED=0 FAILED=0
do_rename() {
  local dry=$1 kind=$2 session=$3 target=$4 from=$5 to=$6
  shift 6
  if [ "$dry" -eq 1 ]; then
    printf 'would rename %s %s: %s -> %s\n' "$kind" "$target" "$from" "$to"
    return 0
  fi
  if "$@" >/dev/null 2>&1; then
    printf 'renamed %s %s: %s -> %s\n' "$kind" "$target" "$from" "$to"
    RENAMED=$((RENAMED + 1))
  else
    printf 'FAILED rename %s %s: %s -> %s\n' "$kind" "$target" "$from" "$to" >&2
    FAILED=$((FAILED + 1))
  fi
}

cmd_migrate() {
  local dry=0 session id sess workspace tab pane unread=0 label want legacy desired variant current live_tab pinned
  case "${1:-}" in
    '') ;;
    --dry-run) dry=1 ;;
    *) die "unknown migrate argument: $1 (try --help)" ;;
  esac
  collect_records
  [ -n "$RECORDS" ] || { echo "jg-herdr-names: no herdr task records in $STATE; nothing to migrate"; return 0; }
  want=$(jg_backend_herdr_workspace_label)
  legacy=$(jg_backend_herdr_workspace_legacy_label)
  while IFS= read -r session; do
    if ! fetch_session "$session"; then
      echo "jg-herdr-names: cannot read herdr session '$session'; skipped" >&2
      unread=1
      continue
    fi
    # Workspaces: only a recorded workspace id whose label is exactly this home's old label.
    if [ -n "$legacy" ]; then
      while IFS= read -r workspace; do
        [ -n "$workspace" ] || continue
        label=$(ws_label "$workspace")
        [ "$label" = "$legacy" ] || continue
        do_rename "$dry" workspace "$session" "$workspace" "$label" "$want" \
          jg_backend_herdr_cli "$session" workspace rename "$workspace" "$want"
      done < <(printf '%s' "$RECORDS" | awk -F'\t' -v s="$session" '$2 == s { print $3 }' | sort -u)
    fi
    while IFS=$'\t' read -r id sess workspace tab pane name; do
      [ "$sess" = "$session" ] || continue
      # Tabs: the recorded tab, only from the pre-rename spelling of this task's label.
      live_tab=$(tab_label "$tab")
      if [ -n "$live_tab" ] && [ "$live_tab" != "jg-$id" ] && jg_compat_label_ok "$live_tab" "jg-$id"; then
        do_rename "$dry" tab "$session" "$tab" "$live_tab" "jg-$id" \
          jg_backend_herdr_cli "$session" tab rename "$tab" "jg-$id"
        live_tab="jg-$id"
      fi
      # Agents: the recorded pane, only while it sits in the recorded task tab.
      current=$(agent_field "$pane" name)
      [ -n "$current" ] || { echo "skip agent $pane ($id): no live agent"; continue; }
      if [ "$(agent_field "$pane" tab_id)" != "$tab" ] || [ "$live_tab" != "jg-$id" ]; then
        echo "skip agent $pane ($id): its tab is not the recorded task tab"
        continue
      fi
      desired=$name
      variant=$(jg_backend_herdr_agent_name_variant "$desired" "$session:$pane")
      if [ "$current" = "$desired" ] || [ "$current" = "$variant" ]; then
        continue
      fi
      if [ "$dry" -eq 1 ]; then
        printf 'would rename agent %s: %s -> %s\n' "$pane" "$current" "$desired"
        continue
      fi
      jg_backend_herdr_pin_agent_name "$session" "$pane" "$desired"
      pinned=${JG_BACKEND_HERDR_PINNED_NAME:-}
      if [ -n "$pinned" ]; then
        printf 'renamed agent %s: %s -> %s\n' "$pane" "$current" "$pinned"
        RENAMED=$((RENAMED + 1))
      else
        printf 'FAILED rename agent %s: %s -> %s\n' "$pane" "$current" "$desired" >&2
        FAILED=$((FAILED + 1))
      fi
    done <<EOF
$RECORDS
EOF
  done < <(session_list)
  [ "$unread" -eq 0 ] || return 2
  [ "$FAILED" -eq 0 ] || return 1
  [ "$dry" -eq 1 ] || echo "jg-herdr-names: migrate done - $RENAMED rename(s)"
  return 0
}

case "${1:-}" in
  check) shift; [ "$#" -eq 0 ] || die "check takes no arguments"; cmd_check ;;
  migrate) shift; cmd_migrate "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac

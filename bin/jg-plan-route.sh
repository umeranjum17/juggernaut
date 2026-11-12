#!/usr/bin/env bash
# jg-plan-route.sh - Main files each slice of a plan into the home of its owner.
#
# Usage: jg-plan-route.sh <plan.json> [--dry-run]
#        jg-plan-route.sh --help
#
# A plan is a file in the form bin/jg-plan-file.sh reads. Each slice names its owner_home: `main` is this
# home, any other name is a Squad Lead id in data/squad_leads.md. For each owner this command runs
# bin/jg-plan-file.sh with that owner's home as JG_HOME, so the slices go through that home's own backlog
# command into that home's store, and into no other. It sets JG_ROW_OWNER, so bin/jg-backlog.sh in the
# receiving home refuses a row of another owner and names the owner.
#
# Only Main routes: a Squad Lead home (one with a squad-lead marker) refuses.
#
# Refusals (exit 2, nothing filed; every owner is resolved and dry-run before the first write):
#   - a plan that is not JSON, or that has no slice;
#   - a slice with no owner_home;
#   - an owner that is not `main` and not a registered local Squad Lead with an existing home;
#   - any refusal bin/jg-plan-file.sh gives for one owner's slices on its dry run, with the owner named
#     (the plan's row must be in each owner's store before the plan is routed).
# A filing that fails after the first owner was filed exits 1 and names the owners already filed: those rows
# stay, and the failed owner is routed again alone with bin/jg-plan-file.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
# shellcheck source=bin/jg-compat.sh disable=SC1091
. "$SCRIPT_DIR/jg-compat.sh"
# shellcheck source=bin/jg-squad-lead-registry-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-squad-lead-registry-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}
fail() {
  printf 'jg-plan-route: %s\n' "$*" >&2
  exit 2
}

PLAN_FILE='' DRY=0
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY=1 ;;
    -*) fail "unknown flag $1" ;;
    *) [ -z "$PLAN_FILE" ] || fail "one plan file only"; PLAN_FILE=$1 ;;
  esac
  shift
done
[ -n "$PLAN_FILE" ] || fail "usage: jg-plan-route.sh <plan.json> [--dry-run]"
[ -r "$PLAN_FILE" ] || fail "cannot read $PLAN_FILE"
jq -e 'type == "object"' "$PLAN_FILE" >/dev/null 2>&1 || fail "$PLAN_FILE is not a JSON plan"
[ ! -e "$(jg_compat_marker "$JG_HOME")" ] || fail "this is a Squad Lead home: only Main routes a plan"

jq -e '(.slices // []) | length > 0' "$PLAN_FILE" >/dev/null || fail "$PLAN_FILE has no slice"
jq -e '.slices | all(.[]; (.owner_home | type) == "string" and (.owner_home | gsub("\\s"; "") | length) > 0)' "$PLAN_FILE" >/dev/null \
  || fail "a slice has no owner_home: every slice names the home that owns it"
mapfile -t OWNERS < <(jq -r '[.slices[].owner_home] | unique[]' "$PLAN_FILE")

# The home of each owner.
REG=$(jg_compat_pick "$DATA/squad_leads.md")
declare -A HOME_OF=()
for owner in "${OWNERS[@]}"; do
  if [ "$owner" = main ]; then
    HOME_OF[$owner]=$JG_HOME
    continue
  fi
  case $owner in *[!A-Za-z0-9._-]*) fail "owner $owner is not a home name" ;; esac
  squad_lead_registry_line_for_id "$REG" "$owner" \
    || fail "owner $owner is neither main nor a Squad Lead in $REG: its slices cannot be filed"
  [ "$SQUAD_LEAD_REGISTRY_REMOTE" = 0 ] || fail "owner $owner is a remote Squad Lead: route its slices from its own host"
  [ -d "$SQUAD_LEAD_REGISTRY_HOME" ] || fail "the home of owner $owner does not exist: $SQUAD_LEAD_REGISTRY_HOME"
  HOME_OF[$owner]=$SQUAD_LEAD_REGISTRY_HOME
done

# jg-plan-file.sh on one owner's slices, in that owner's home. Main's home keeps the caller's own overrides;
# a Squad Lead home derives its config, state and data from its root.
file_for() {  # <owner> [--dry-run]
  local owner=$1
  shift
  if [ "$owner" = main ]; then
    JG_ROW_OWNER=$owner JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-plan-file.sh" "$PLAN_FILE" --owner "$owner" "$@" 2>&1
  else
    env -u JG_CONFIG_OVERRIDE -u JG_STATE_OVERRIDE -u JG_DATA_OVERRIDE -u JG_ROOT_OVERRIDE \
      JG_ROW_OWNER="$owner" JG_HOME="${HOME_OF[$owner]}" "$SCRIPT_DIR/jg-plan-file.sh" "$PLAN_FILE" --owner "$owner" "$@" 2>&1
  fi
}

# Every owner's checks run before anything is filed.
for owner in "${OWNERS[@]}"; do
  out=$(file_for "$owner" --dry-run) || fail "owner $owner: $out; nothing was filed"
  printf '%s: %s\n' "$owner" "${out//$'\n'/; }"
done
[ "$DRY" = 0 ] || exit 0

DONE=()
for owner in "${OWNERS[@]}"; do
  if out=$(file_for "$owner"); then
    printf '%s\n' "$out"
    DONE+=("$owner")
  else
    printf '%s\njg-plan-route: owner %s failed; already filed: %s\n' "$out" "$owner" "${DONE[*]:-nobody}" >&2
    exit 1
  fi
done
printf 'routed %s slices to %s\n' "$(jq '.slices | length' "$PLAN_FILE")" "${OWNERS[*]}"

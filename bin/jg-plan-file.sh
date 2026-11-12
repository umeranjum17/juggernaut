#!/usr/bin/env bash
# jg-plan-file.sh - file the slices of a plan file that this home owns into this home's backlog.
#
# Usage: jg-plan-file.sh <plan.json> --owner <home> [--dry-run]
#        jg-plan-file.sh --help
#
# A plan is a file in the form of data/fable-selfheal-fleet-recon/slices-addendum.json: `plan` names the
# plan's row (it must exist already and becomes the epic), and each entry of `slices` has id, title,
# owner_home, project, size, risk, depends_on (a list), files (a list; a trailing " (new)" marks a file
# the slice makes) and machine. This command files the slices whose owner_home is --owner, and no other.
# For each one it sets:
#   - the label project:<project>, so the spawn check reads the repository the slice belongs to;
#   - one dependency edge for each depends_on entry (a slice of this file, or a row already in the store);
#   - the file list as metadata `files` (a JSON array of paths) and `new_files` (the ones marked new),
#     plus plan_slice, size, risk and machine;
#   - the plan's row as its parent, so the row is an epic.
# It then runs `bd swarm validate` on the epic and prints the result.
#
# Refusals (exit 2, nothing filed; every check runs before the first write):
#   - a plan that is not JSON, names no plan, or has no slices of --owner;
#   - a slice with no id, title, project, size or risk, a repeated id, or an empty or blank file list;
#   - a depends_on entry that is neither a slice of this file filed here nor a row of the store (prose);
#   - a dependency on a slice of another owner (the gate of a cross-home dependency is a later slice);
#   - a dependency cycle among the slices;
#   - a plan row missing from the store, or a slice already filed under it (a second run would duplicate it).
# --dry-run runs the checks and prints what would be filed. `bd swarm validate` failing after the filing
# exits 1 with its output; the rows stay filed and the epic is not safe to start from.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
CONFIG_DIR="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
# shellcheck source=bin/jg-backlog-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-backlog-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}
fail() {
  printf 'jg-plan-file: %s\n' "$*" >&2
  exit 2
}

PLAN_FILE='' OWNER='' DRY=0
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --owner) [ $# -ge 2 ] || fail "--owner needs a home name"; OWNER=$2; shift ;;
    --dry-run) DRY=1 ;;
    -*) fail "unknown flag $1" ;;
    *) [ -z "$PLAN_FILE" ] || fail "one plan file only"; PLAN_FILE=$1 ;;
  esac
  shift
done
[ -n "$PLAN_FILE" ] || fail "usage: jg-plan-file.sh <plan.json> --owner <home> [--dry-run]"
[ -n "$OWNER" ] || fail "--owner <home> is required: this command files only the slices that home owns"
[ -r "$PLAN_FILE" ] || fail "cannot read $PLAN_FILE"
jq -e 'type == "object"' "$PLAN_FILE" >/dev/null 2>&1 || fail "$PLAN_FILE is not a JSON plan"

STORE=$(jg_backlog_beads_store "$CONFIG_DIR") || exit 2
bd_() { BEADS_DIR=$STORE "$SCRIPT_DIR/jg-beads.sh" "$@"; }
backlog_() { JG_HOME="$JG_HOME" JG_CONFIG_OVERRIDE="$CONFIG_DIR" "$SCRIPT_DIR/jg-backlog.sh" "$@"; }

PLAN=$(jq -r '.plan // empty' "$PLAN_FILE")
[ -n "$PLAN" ] || fail "the plan file names no plan row (.plan)"

# The slices of this owner, one compact JSON object per line, in file order.
MINE=$(jq -c --arg o "$OWNER" '.slices // [] | map(select(.owner_home == $o)) | .[]' "$PLAN_FILE")
[ -n "$MINE" ] || fail "$PLAN_FILE has no slice owned by $OWNER"
ALL_IDS=$(jq -r '.slices[]?.id // empty' "$PLAN_FILE")
MY_IDS=$(jq -r '.id // empty' <<<"$MINE")

# Per-slice shape and the edges that can be seen from the file alone.
declare -A SEEN=() DEPS=()
while IFS= read -r slice; do
  id=$(jq -r '.id // empty' <<<"$slice")
  [ -n "$id" ] || fail "a slice of $OWNER has no id"
  [ -z "${SEEN[$id]:-}" ] || fail "slice $id is in the plan twice"
  SEEN[$id]=1
  for field in title project size risk; do
    jq -e --arg f "$field" '(.[$f] | type) == "string" and (.[$f] | gsub("\\s"; "") | length) > 0' <<<"$slice" >/dev/null \
      || fail "slice $id has no $field"
  done
  jq -e '(.files | type) == "array" and (.files | length) > 0 and all(.files[]; type == "string" and (gsub("\\s"; "") | length) > 0)' <<<"$slice" >/dev/null \
    || fail "slice $id has no file list: a slice with no files cannot be told apart from another lane's, so it is not filed"
  jq -e '(.depends_on // []) | type == "array" and all(.[]; type == "string")' <<<"$slice" >/dev/null \
    || fail "slice $id: depends_on must be a list of ids"
  DEPS[$id]=$(jq -r '(.depends_on // [])[]' <<<"$slice")
done <<<"$MINE"

# Each dependency is an edge or it is refused: a slice filed here, or a row the store already has.
for id in $MY_IDS; do
  for dep in ${DEPS[$id]}; do
    if [ -n "${SEEN[$dep]:-}" ]; then
      [ "$dep" != "$id" ] || fail "slice $id depends on itself"
    elif grep -Fxq -- "$dep" <<<"$ALL_IDS"; then
      fail "slice $id depends on $dep, which $(jq -r --arg d "$dep" '.slices[] | select(.id == $d) | .owner_home' "$PLAN_FILE") owns: a dependency across homes is not an edge of this store"
    elif ! bd_ show "$dep" --json >/dev/null 2>&1; then
      fail "slice $id depends on \"$dep\", which is neither a slice filed here nor a row of the store: write the id of a row"
    fi
  done
done

# Filing order: a slice after everything it depends on; what cannot be ordered is a cycle.
ORDER=() ; progress=1
mapfile -t _ids <<<"$MY_IDS"
declare -A FILED=()
while [ "${#ORDER[@]}" -lt "${#_ids[@]}" ] && [ "$progress" = 1 ]; do
  progress=0
  for id in "${_ids[@]}"; do
    [ -z "${FILED[$id]:-}" ] || continue
    ready=1
    for dep in ${DEPS[$id]}; do [ -z "${SEEN[$dep]:-}" ] || [ -n "${FILED[$dep]:-}" ] || ready=0; done
    [ "$ready" = 1 ] || continue
    FILED[$id]=1; ORDER+=("$id"); progress=1
  done
done
if [ "${#ORDER[@]}" -lt "${#_ids[@]}" ]; then
  stuck=''
  for id in "${_ids[@]}"; do [ -n "${FILED[$id]:-}" ] || stuck="$stuck $id"; done
  fail "the slices${stuck} depend on each other in a cycle"
fi

# The plan's row exists, and none of these slices is filed under it already.
bd_ show "$PLAN" --json >/dev/null 2>&1 || fail "the plan row $PLAN is not in this store: file it first"
filed=$(bd_ list --parent "$PLAN" --all --limit 0 --json 2>/dev/null | jq -r '.[]? | (.metadata.plan_slice // empty) + " " + .id') || filed=
for id in "${ORDER[@]}"; do
  row=$(awk -v s="$id" '$1 == s { print $2; exit }' <<<"$filed")
  [ -z "$row" ] || fail "slice $id is already filed under $PLAN as $row: a second filing would duplicate it"
done

if [ "$DRY" = 1 ]; then
  for id in "${ORDER[@]}"; do
    project=$(jq -r --arg i "$id" 'select(.id == $i) | .project' <<<"$MINE")
    printf 'would file %s (project:%s), after: %s\n' "$id" "$project" "${DEPS[$id]//$'\n'/ }"
  done
  exit 0
fi

declare -A ROW=()
for id in "${ORDER[@]}"; do
  slice=$(jq -c --arg i "$id" 'select(.id == $i)' <<<"$MINE")
  title=$(jq -r '.title' <<<"$slice")
  project=$(jq -r '.project' <<<"$slice")
  body=$(printf '%s\nPlan: %s, slice %s (owner %s).\nFiles: %s' "$title" "$PLAN" "$id" "$OWNER" \
    "$(jq -r '.files | join(", ")' <<<"$slice")")
  args=(add --parent "$PLAN" "[feature] $id: $title" --repo "$project" --priority 2 --body "$body" --json)
  for dep in ${DEPS[$id]}; do args+=(--blocked-by "${ROW[$dep]:-$dep}"); done
  made=$(backlog_ "${args[@]}") || fail "could not file slice $id: $made"
  row=$(jq -r '.task.id // .id // empty' <<<"$made")
  [ -n "$row" ] || fail "could not read the new row of slice $id from: $made"
  ROW[$id]=$row
  files=$(jq -c '[.files[] | sub(" \\(new\\)$"; "")]' <<<"$slice")
  newfiles=$(jq -c '[.files[] | select(endswith(" (new)")) | sub(" \\(new\\)$"; "")]' <<<"$slice")
  bd_ update "$row" --set-metadata "files=$files" --set-metadata "new_files=$newfiles" \
    --set-metadata "plan_slice=$id" --set-metadata "size=$(jq -r .size <<<"$slice")" \
    --set-metadata "risk=$(jq -r .risk <<<"$slice")" --set-metadata "machine=$(jq -r '.machine // ""' <<<"$slice")" \
    >/dev/null 2>&1 || fail "slice $id is filed as $row but its fields could not be set"
  printf 'filed %s as %s\n' "$id" "$row"
done

if out=$(bd_ swarm validate "$PLAN" 2>&1); then
  printf '%s\nvalidate passed for %s\n' "$out" "$PLAN"
else
  printf '%s\njg-plan-file: bd swarm validate refused %s; do not start rows from it\n' "$out" "$PLAN" >&2
  exit 1
fi

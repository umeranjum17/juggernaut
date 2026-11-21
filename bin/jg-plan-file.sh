#!/usr/bin/env bash
# jg-plan-file.sh - file the slices of a plan file that this home owns into this home's backlog.
#
# Usage: jg-plan-file.sh <plan.json> --owner <home> [--order <ref>] [--dry-run]
#        jg-plan-file.sh --help
#
# A plan is a file in the form of data/fable-selfheal-fleet-recon/slices-addendum.json: `plan` names the
# plan's row (it must exist already and becomes the epic), and each entry of `slices` has id, title,
# owner_home, project, size, risk, depends_on (a list), files (a list; a trailing " (new)" marks a file
# the slice makes), machine, and an optional body (the row's sections). This command files the slices whose
# owner_home is --owner, and no other. The row's title is the slice title; the slice id goes in the body.
# For each one it sets:
#   - the label project:<project>, so the spawn check reads the repository the slice belongs to;
#   - one dependency edge for each depends_on entry (a slice of this file, or a row already in the store);
#   - the file list as metadata `files` (a JSON array of paths) and `new_files` (the ones marked new),
#     plus plan_slice, size, risk and machine;
#   - the plan's row as its parent, so the row is an epic;
#   - the body line `Owner order: <ref>.` when the plan has an `owner_order` (or --order <ref>, which wins): MainNNN or the id of a
#     [captain-ask] row, so the owner-rules brief gate finds the order the lane serves. A completed row lacking the line gets it.
# It then runs `bd swarm validate` on the epic and prints the result.
#
# A second run on a plan that is partly filed (a stopped start) files only what is missing:
#   - a slice already filed under the plan (the same plan_slice) is adopted: nothing is filed for it, `filed <id> as <row>`
#     goes to stdout as for a new one and `adopted <id> as <row>` to stderr;
#   - a child row of the plan with no plan_slice and the slice's title is a row a stop left before its fields were set:
#     its fields are set (`completed <id> as <row>` on stderr) and no second row is made;
#   - two such rows for one slice are refused, naming both.
# JG_PLAN_FILE_STOP_AFTER=<n> (a test hook) exits 9 right after the n-th row is added and before its fields are set.
#
# Refusals (exit 2, nothing filed; every check runs before the first write):
#   - a plan that is not JSON, names no plan, or has no slices of --owner;
#   - a slice with no id, title, project, size or risk, a repeated id, or an empty or blank file list;
#   - a depends_on entry that is neither a slice of this file filed here nor a row of the store (prose);
#   - a dependency on a slice of another owner (the gate of a cross-home dependency is a later slice);
#   - a dependency cycle among the slices;
#   - a plan row missing from the store, or two unfinished rows under it with one slice's title (which one is the slice?);
#   - in a home with strict intake (no config/backlog-intake-loose), a slice whose title is not 2 to 7 plain words
#     (bin/jg-backlog-lib.sh jg_backlog_title_refusal) or whose body lacks ## Captain, ## Ask, ## Why, ## Done when
#     and ## Acceptance Criteria.
# --dry-run runs the checks and prints what would be filed, adopted or completed. `bd swarm validate` failing after the filing
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

PLAN_FILE='' OWNER='' DRY=0 ORDER_REF=''
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --owner) [ $# -ge 2 ] || fail "--owner needs a home name"; OWNER=$2; shift ;;
    --order) [ $# -ge 2 ] || fail "--order needs a reference"; ORDER_REF=$2; shift ;;
    --dry-run) DRY=1 ;;
    -*) fail "unknown flag $1" ;;
    *) [ -z "$PLAN_FILE" ] || fail "one plan file only"; PLAN_FILE=$1 ;;
  esac
  shift
done
[ -n "$PLAN_FILE" ] || fail "usage: jg-plan-file.sh <plan.json> --owner <home> [--order <ref>] [--dry-run]"
[ -n "$OWNER" ] || fail "--owner <home> is required: this command files only the slices that home owns"
[ -r "$PLAN_FILE" ] || fail "cannot read $PLAN_FILE"
jq -e 'type == "object"' "$PLAN_FILE" >/dev/null 2>&1 || fail "$PLAN_FILE is not a JSON plan"

bd_() { JG_HOME="$JG_HOME" python3 -I "$SCRIPT_DIR/../core/item-store/adapters/bd_compat.py" "$@"; }
backlog_() { JG_HOME="$JG_HOME" JG_CONFIG_OVERRIDE="$CONFIG_DIR" "$SCRIPT_DIR/jg-backlog.sh" "$@"; }

PLAN=$(jq -r '.plan // empty' "$PLAN_FILE")
[ -n "$PLAN" ] || fail "the plan file names no plan row (.plan)"
# The owner order each row names: --order, else the plan's owner_order; none leaves the rows as before.
[ -n "$ORDER_REF" ] || ORDER_REF=$(jq -r '.owner_order // empty' "$PLAN_FILE")
case $ORDER_REF in
  *[!A-Za-z0-9._-]*) fail "the owner order \"$ORDER_REF\" is not one reference: write MainNNN or the id of a [captain-ask] row" ;;
esac
ORDER_LINE=${ORDER_REF:+Owner order: $ORDER_REF.}

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

# The plan's row exists. Each slice is then new, adopted (filed already) or completed (a row a stop left without its fields).
bd_ show "$PLAN" --json >/dev/null 2>&1 || fail "the plan row $PLAN is not in this store: file it first"
declare -A ROW=() HOW=()
declare -a BARE_IDS=() BARE_TITLES=()
while IFS=$'\t' read -r slice_id row_id row_title; do
  [ -n "$row_id" ] || continue
  if [ "$slice_id" != - ]; then
    [ -n "${SEEN[$slice_id]:-}" ] && [ -z "${ROW[$slice_id]:-}" ] && { ROW[$slice_id]=$row_id; HOW[$slice_id]=adopt; }
  else
    BARE_IDS+=("$row_id"); BARE_TITLES+=("$row_title")
  fi
done < <(bd_ list --parent "$PLAN" --all --limit 0 --json 2>/dev/null | jq -r '.[]? | [(.metadata.plan_slice // "-"), .id, .title] | @tsv')
for id in "${ORDER[@]}"; do
  [ -z "${HOW[$id]:-}" ] || continue
  title=$(jq -r --arg i "$id" 'select(.id == $i) | .title' <<<"$MINE")
  matches=()
  for i in "${!BARE_IDS[@]}"; do
    [ "${BARE_TITLES[$i]}" != "$title" ] || matches+=("${BARE_IDS[$i]}")
  done
  case ${#matches[@]} in
    0) HOW[$id]=new ;;
    1) HOW[$id]=complete; ROW[$id]=${matches[0]}
       for i in "${!BARE_IDS[@]}"; do [ "${BARE_IDS[i]}" != "${matches[0]}" ] || BARE_TITLES[i]=; done ;;
    *) fail "slice $id: $(printf "%s\n" "${matches[@]}" | sort -V | tr "\n" " ")are rows of $PLAN with the title \"$title\" and no plan_slice, so which one is the slice? close the extra row and file again" ;;
  esac
done

# Strict intake files a row only with a plain title and the five body sections; check every slice before the first write.
if [ ! -e "$JG_HOME/config/backlog-intake-loose" ]; then
  for id in "${ORDER[@]}"; do
    slice=$(jq -c --arg i "$id" 'select(.id == $i)' <<<"$MINE")
    why=$(jg_backlog_title_refusal "$(jq -r '.title' <<<"$slice")") || fail "slice $id: the title is not a readable title: $why"
    for h in Captain Ask Why 'Done when' 'Acceptance Criteria'; do
      jq -r '.body // ""' <<<"$slice" | grep -q "^## $h" \
        || fail "slice $id: this home has strict intake, so the slice needs a body with ## $h (and the other four sections)"
    done
  done
fi

if [ "$DRY" = 1 ]; then
  for id in "${ORDER[@]}"; do
    project=$(jq -r --arg i "$id" 'select(.id == $i) | .project' <<<"$MINE")
    case ${HOW[$id]} in
      adopt|complete) printf 'would %s %s as %s\n' "${HOW[$id]}" "$id" "${ROW[$id]}" ;;
      *) printf 'would file %s (project:%s), after: %s\n' "$id" "$project" "${DEPS[$id]//$'\n'/ }" ;;
    esac
  done
  exit 0
fi

# The fields of a row: its files, the plan's slice id, size, risk and machine.
set_fields() {  # <slice json> <row> <slice id>
  local slice=$1 row=$2 id=$3 files newfiles
  files=$(jq -c '[.files[] | sub(" \\(new\\)$"; "")]' <<<"$slice")
  newfiles=$(jq -c '[.files[] | select(endswith(" (new)")) | sub(" \\(new\\)$"; "")]' <<<"$slice")
  bd_ update "$row" --set-metadata "files=$files" --set-metadata "new_files=$newfiles" \
    --set-metadata "plan_slice=$id" --set-metadata "size=$(jq -r .size <<<"$slice")" \
    --set-metadata "risk=$(jq -r .risk <<<"$slice")" --set-metadata "machine=$(jq -r '.machine // ""' <<<"$slice")" \
    >/dev/null 2>&1 || fail "slice $id is filed as $row but its fields could not be set"
}

# A completed row without the owner order line gets it appended to its body.
set_order_line() {  # <row> <slice id>
  [ -n "$ORDER_LINE" ] || return 0
  local body
  body=$(bd_ show "$1" --json | jq -r '(if type == "array" then .[0] else . end).description // ""')
  grep -qxF -- "$ORDER_LINE" <<<"$body" && return 0
  backlog_ update "$1" --body "$body"$'\n'"$ORDER_LINE" >/dev/null 2>&1 || fail "slice $2 is filed as $1 but its owner order could not be written"
}

added=0
for id in "${ORDER[@]}"; do
  slice=$(jq -c --arg i "$id" 'select(.id == $i)' <<<"$MINE")
  case ${HOW[$id]} in
    adopt) printf 'adopted %s as %s\n' "$id" "${ROW[$id]}" >&2 ;;
    complete) set_fields "$slice" "${ROW[$id]}" "$id"; set_order_line "${ROW[$id]}" "$id"
              printf 'completed %s as %s\n' "$id" "${ROW[$id]}" >&2 ;;
    new)
      title=$(jq -r '.title' <<<"$slice")
      project=$(jq -r '.project' <<<"$slice")
      sections=$(jq -r '.body // empty' <<<"$slice")
      body=$(printf '%s\nPlan: %s, slice %s (owner %s).\nFiles: %s' "${sections:-$title}" "$PLAN" "$id" "$OWNER" \
        "$(jq -r '.files | join(", ")' <<<"$slice")")
      body+=${ORDER_LINE:+$'\n'$ORDER_LINE}
      args=(add --parent "$PLAN" "[feature] $title" --repo "$project" --priority 2 --body "$body" --json)
      for dep in ${DEPS[$id]}; do args+=(--blocked-by "${ROW[$dep]:-$dep}"); done
      made=$(backlog_ "${args[@]}") || fail "could not file slice $id: $made"
      row=$(jq -r '.task.id // .id // empty' <<<"$made")
      [ -n "$row" ] || fail "could not read the new row of slice $id from: $made"
      ROW[$id]=$row
      added=$((added + 1))
      [ "$added" != "${JG_PLAN_FILE_STOP_AFTER:-}" ] || exit 9
      set_fields "$slice" "$row" "$id" ;;
  esac
  printf 'filed %s as %s\n' "$id" "${ROW[$id]}"
done

if out=$(bd_ swarm validate "$PLAN" 2>&1); then
  printf '%s\nvalidate passed for %s\n' "$out" "$PLAN"
else
  printf '%s\njg-plan-file: bd swarm validate refused %s; do not start rows from it\n' "$out" "$PLAN" >&2
  exit 1
fi

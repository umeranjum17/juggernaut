#!/usr/bin/env bash
# jg-backlog-spawnable.sh - the tickets this home can start now.
#
# Usage: jg-backlog-spawnable.sh        (bin/jg-backlog.sh `ready --spawnable` runs it)
#
# Prints `count: <n>`, then one `<id>\t<project>` line per ticket. A ticket can
# start when the store lists it ready and all of these hold:
#   - it is work, not a decision card, and nobody holds it (no assignee, no hold record);
#   - it names a project that data/projects.md registers for this home;
#   - no live lane holds it (no state/<id>.meta);
#   - no open captain decision card is linked to it, in either direction.
# Two store reads (ready, and the whole board for its links) serve the whole answer;
# `bd ready` already leaves out blocked, held and deferred rows.
# The caller bounds the whole run (bin/jg-backlog.sh gives it 10 seconds).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
# shellcheck source=bin/jg-backlog-lib.sh
. "$SCRIPT_DIR/jg-backlog-lib.sh"

die() { printf 'jg-backlog-spawnable: %s\n' "$1" >&2; exit "${2:-2}"; }

store=$(jg_backlog_beads_store "$CONFIG") || exit 2
# Registered project names: the text between "- " and the first " [" or " - ".
projects=$(sed -n 's/^- \(.*\)$/\1/p' "$DATA/projects.md" 2>/dev/null \
  | sed -e 's/ \[.*$//' -e 's/ - .*$//' | jq -R . | jq -sc .) || projects='[]'
[ -n "$projects" ] || projects='[]'
read_store() {  # <bd verb> [args...]: the verb's JSON answer, or the reason it failed
  BEADS_DIR=$store "$SCRIPT_DIR/jg-beads.sh" "$@" --limit 0 --json 2>/dev/null
}
tmp=$(mktemp -d) || die "no scratch directory"
trap 'rm -rf -- "$tmp"' EXIT
read_store ready > "$tmp/ready.json" || die "the store read failed"
read_store list --all > "$tmp/all.json" || die "the store read failed"
for f in "$STATE"/*.meta; do [ -e "$f" ] && basename "$f" .meta; done | jq -R . | jq -sc . > "$tmp/lanes.json"
# Open owner cards: an unclosed decision row, or an unclosed [design-ux] row. A card
# blocks the rows it is linked to by an edge in either direction (links are edges).
list=$(jq -rn --argjson projects "$projects" --slurpfile ready "$tmp/ready.json" \
  --slurpfile all_rows "$tmp/all.json" --slurpfile lanes "$tmp/lanes.json" '
  $ready[0] as $ready | $all_rows[0] as $all | $lanes[0] as $state
  | ([$all[] | select(.status != "closed"
        and (.issue_type == "decision" or (.title | contains("[design-ux]")))) | .id]) as $cards
  | ([$all[] | .id as $id | .dependencies[]? | select(.type != "tracks")
        | select(([.depends_on_id] | inside($cards)) or ([$id] | inside($cards)))
        | (if ([.depends_on_id] | inside($cards)) then .issue_id else .depends_on_id end)]) as $linked
  | $ready[]
  | select(.status == "open" and .issue_type != "decision"
      and ((.assignee // "") == "") and ((.metadata.hold_reason // "") == ""))
  | ([.labels[]? | select(startswith("project:")) | sub("^project:"; "")]
     | map(select(. as $p | $projects | index($p))) | first) as $project
  | select($project != null)
  | select(.id as $id | ($state | index($id)) == null and ($linked | index($id)) == null)
  | [.id, $project] | @tsv') || die "the store answer could not be read"
count=0
[ -z "$list" ] || count=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
printf 'count: %s\n' "$count"
[ -z "$list" ] || printf '%s\n' "$list"

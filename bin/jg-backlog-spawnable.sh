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
# One indexed query on the store's own tables answers it (status, is_blocked and the
# dependency keys are indexed), so the cost follows the startable rows, not the board:
# it reads no closed row and no row body. The project and live-lane checks run here on
# that small answer. Rows come out in the order `bd ready` uses: priority, then age.
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
tmp=$(mktemp -d) || die "no scratch directory"
trap 'rm -rf -- "$tmp"' EXIT
# Registered project names: the text between "- " and the first " [" or " - ".
sed -n 's/^- \(.*\)$/\1/p' "$DATA/projects.md" 2>/dev/null \
  | sed -e 's/ \[.*$//' -e 's/ - .*$//' > "$tmp/projects"
for f in "$STATE"/*.meta; do [ -e "$f" ] && basename "$f" .meta; done > "$tmp/lanes"

# A card is an unclosed decision row or an unclosed [design-ux] row; it blocks the rows it
# is linked to by an edge in either direction (links are edges, `tracks` aside). A startable
# row is open, not blocked, not deferred, not a decision, and has no assignee or hold reason.
# Each row comes out once per project label, so the registered-project pick stays here.
query="SELECT i.id, l.label FROM issues i JOIN labels l ON l.issue_id = i.id AND l.label LIKE 'project:%'
  WHERE i.status = 'open' AND i.is_blocked = 0 AND i.issue_type <> 'decision' AND i.ephemeral = 0
    AND (i.defer_until IS NULL OR i.defer_until <= NOW())
    AND COALESCE(i.assignee, '') = ''
    AND COALESCE(JSON_UNQUOTE(JSON_EXTRACT(i.metadata, '\$.hold_reason')), '') = ''
    AND NOT EXISTS (SELECT 1 FROM dependencies d JOIN issues c ON c.id = d.depends_on_issue_id
      WHERE d.issue_id = i.id AND d.type <> 'tracks' AND c.status <> 'closed'
        AND (c.issue_type = 'decision' OR LOCATE('[design-ux]', c.title) > 0))
    AND NOT EXISTS (SELECT 1 FROM dependencies d JOIN issues c ON c.id = d.issue_id
      WHERE d.depends_on_issue_id = i.id AND d.type <> 'tracks' AND c.status <> 'closed'
        AND (c.issue_type = 'decision' OR LOCATE('[design-ux]', c.title) > 0))
  ORDER BY i.priority, i.created_at, i.id, l.label"
BEADS_DIR=$store "$SCRIPT_DIR/jg-beads.sh" dolt sql -q "$query" > "$tmp/rows" 2>"$tmp/err" \
  || die "the store read failed: $(head -c 300 "$tmp/err")"

# The answer is a table: borders, a header row, then `| id | project:<name> |` rows.
list=$(awk -v lanes="$tmp/lanes" -v projects="$tmp/projects" '
  BEGIN { while ((getline l < lanes) > 0) lane[l] = 1; while ((getline p < projects) > 0) reg[p] = 1 }
  /^\| / { n++; if (n == 1) next
    sub(/^\| /, ""); sub(/ +\|$/, ""); i = index($0, " | "); id = substr($0, 1, i - 1)
    gsub(/ +$/, "", id); label = substr($0, i + 3); sub(/^project:/, "", label)
    if (!(label in reg) || (id in lane) || (id in done)) next
    done[id] = 1; printf "%s\t%s\n", id, label }' "$tmp/rows")
count=0
[ -z "$list" ] || count=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
printf 'count: %s\n' "$count"
[ -z "$list" ] || printf '%s\n' "$list"

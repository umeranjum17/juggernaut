#!/usr/bin/env bash
# group.sh - group the captain's held decisions instead of multiplying them (slice H52).
#
# Usage: group.sh cards | by-ticket | per-day | report
#
# It only reads: every row comes from `bin/jg-backlog.sh list` and `show`, and nothing here holds,
# answers, closes, releases or edits a task. The captain-hold state machine (bin/jg-captain-hold.sh)
# stays the one owner of a hold's state.
#
#   cards      one line per question: card<TAB>key<TAB>primary<TAB>raised-by<TAB>links
#              Open holds that carry the same `question-key: <slug>` line in their body are ONE card;
#              the earliest hold is the primary and the others are its links. A hold with no key is its
#              own card, keyed by its task id.
#   by-ticket  one line per raising ticket: ticket<TAB>raised-by<TAB>cards<TAB>holds (the cards its holds are in)
#              The raiser is the first `parent:` or `linked-to:` target of the hold's body, else `-`.
#   per-day    one line per home and day: day<TAB>home<TAB>date<TAB>new
#              The day is the date of the hold's `Captain hold set:` line; the home is the squad lead
#              id of this home (.jg-squad-lead-home) or `main`.
#   report     the three above, each under a `# <name>` line.
#
# Exit 0 on success, 2 on a usage error or an unreadable backlog.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BACKLOG=${JG_DECISION_GROUP_BACKLOG:-$ROOT/bin/jg-backlog.sh}
HOME_DIR=${JG_HOME:-$ROOT}

fail() { printf 'group.sh: %s\n' "$*" >&2; exit 2; }

home_name() {
  local marker=$HOME_DIR/.jg-squad-lead-home name=''
  [ -f "$marker" ] && name=$(tr -d '[:space:]' < "$marker")
  printf '%s\n' "${name:-main}"
}

# Print one row per open captain hold: id<TAB>key<TAB>raised-by<TAB>day. Sorted by day then id,
# so the first row of a key is the earliest hold.
hold_rows() {
  local listing id shown body key raiser day
  listing=$("$BACKLOG" list) || fail "the backlog could not be listed"
  while IFS= read -r id; do
    shown=$("$BACKLOG" show "$id") || fail "task $id could not be read"
    printf '%s\n' "$shown" | grep -q '^  held: yes$' || continue
    printf '%s\n' "$shown" | grep -q '^  hold_kind: captain$' || continue
    body=$(printf '%s\n' "$shown" | sed -n 's/^  body: "\(.*\)"$/\1/p' | sed 's/\\n/\n/g')
    key=$(printf '%s\n' "$body" | sed -n -E 's/^[[:space:]]*question-key:[[:space:]]*([A-Za-z0-9._-]+).*$/\1/p' | head -n 1)
    raiser=$(printf '%s\n' "$body" | sed -n -E 's/^[[:space:]]*(parent|linked-to):[[:space:]]*([A-Za-z0-9._-]+).*$/\2/p' | head -n 1)
    day=$(printf '%s\n' "$body" | sed -n -E 's/^Captain hold set: ([0-9]{4}-[0-9]{2}-[0-9]{2}).*$/\1/p' | head -n 1)
    printf '%s\t%s\t%s\t%s\n' "$id" "${key:-$id}" "${raiser:--}" "${day:-unknown}"
  done < <(printf '%s\n' "$listing" | sed -n -E 's/^[[:space:]]+([A-Za-z0-9._-]+),(queued|in_flight|in-flight|blocked|[a-z_-]+),.*/\1/p') \
    | LC_ALL=C sort -t "$(printf '\t')" -k4,4 -k1,1
}

cards() {
  hold_rows | awk -F'\t' '
    !($2 in primary) { primary[$2] = $1; raiser[$2] = $3; order[++n] = $2; next }
    { links[$2] = links[$2] (links[$2] == "" ? "" : ",") $1 }
    END { for (i = 1; i <= n; i++) { k = order[i]
      printf "card\t%s\t%s\t%s\t%s\n", k, primary[k], raiser[k], (links[k] == "" ? "-" : links[k]) } }'
}

by_ticket() {
  hold_rows | awk -F'\t' '{ h[$3]++; if (!(($3 SUBSEP $2) in seen)) { seen[$3, $2] = 1; c[$3]++ } }
    END { for (r in h) printf "ticket\t%s\t%d\t%d\n", r, c[r], h[r] }' | LC_ALL=C sort
}

per_day() {
  local home; home=$(home_name)
  hold_rows | awk -F'\t' -v home="$home" '{ n[$4]++ } END { for (d in n) printf "day\t%s\t%s\t%d\n", home, d, n[d] }' | LC_ALL=C sort -k3,3
}

case "${1:-}" in
  cards) cards ;;
  by-ticket) by_ticket ;;
  per-day) per_day ;;
  report) printf '# cards\n'; cards; printf '# by-ticket\n'; by_ticket; printf '# per-day\n'; per_day ;;
  *) fail "usage: group.sh cards | by-ticket | per-day | report" ;;
esac

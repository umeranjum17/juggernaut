#!/usr/bin/env bash
# same-red.sh - one shared red is fixed once (H45).
#
#   same-red.sh record <lane> <tip> <script> [--source lane|verify] [--project <name>]
#       The gate or the verify reports one red: <lane> failed <script> on the trunk tip <tip>. A verify names itself as
#       its lane (for example "verify"). The same lane failing the same script again on the same tip is one red.
#   same-red.sh scan [--project <name>]
#       When 3 or more different lanes failed one script on one tip, file ONE fix ticket for that script through
#       core/trunk-landing/quarantine.sh ticket (the one filer; the script path is its key) and mark the red shared.
#       Prints "shared <script> tip=<tip> lanes=<n> ticket=<id>" once per new shared red. A red already shared files nothing.
#   same-red.sh waiting <lane> [--project <name>]
#       Exit 0 and print "<ticket> <script> tip=<tip>" while the lane has a red marked shared and that ticket is open: the
#       lane waits on the ticket and does not fix the script itself. Exit 1 once the ticket is closed (the lane gates
#       again) or when the lane holds no shared red. A lane that reds the same script on the same tip after the mark
#       joins the wait by `record`.
#
# The ledger is data/trunk/same-red-<project>.tsv, append only: epoch, tip, script, lane, source. The shared marks are
# data/trunk/same-red-shared-<project>.tsv: epoch, tip, script, ticket, lane count. The project defaults to
# JG_QUARANTINE_PROJECT, else juggernaut. JG_SAME_RED_QUARANTINE and JG_SAME_RED_BACKLOG name another filer and backlog
# tool. Exit 2: usage error or a ticket that could not be filed.
set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$SELF_DIR/../.." && pwd -P)
JG_HOME="${JG_HOME:-$ROOT}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
FILER="${JG_SAME_RED_QUARANTINE:-$ROOT/core/trunk-landing/quarantine.sh}"
BACKLOG="${JG_SAME_RED_BACKLOG:-$ROOT/bin/jg-backlog.sh}"
MIN_LANES=3

die() { echo "same-red: $*" >&2; exit 2; }
usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

PROJECT=${JG_QUARANTINE_PROJECT:-juggernaut} SOURCE=lane ARGS=()
case ${1:-} in -h|--help|"") usage; exit 0 ;; esac
CMD=$1; shift
while [ $# -gt 0 ]; do
  case $1 in
    --project) [ $# -ge 2 ] || die "--project needs a name"; PROJECT=$2; shift 2 ;;
    --source) [ $# -ge 2 ] || die "--source needs lane or verify"; SOURCE=$2; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[[ $PROJECT =~ ^[A-Za-z0-9._-]+$ ]] || die "the project name has characters a file name cannot hold: $PROJECT"
case $SOURCE in lane|verify) ;; *) die "--source is lane or verify, got $SOURCE" ;; esac
LEDGER="$DATA/trunk/same-red-$PROJECT.tsv"
SHARED="$DATA/trunk/same-red-shared-$PROJECT.tsv"
NOW=$(date +%s)

field() { [[ $2 =~ ^[A-Za-z0-9._/+:@-]+$ ]] || die "$1 has characters a ledger row cannot hold: $2"; }

ticket_open() {  # <ticket>: the backlog shows it and it is not closed
  "$BACKLOG" show "$1" 2>/dev/null | grep -q '^  closed: "-"'
}

do_record() {
  [ "${#ARGS[@]}" -eq 3 ] || die "record needs <lane> <tip> <script>"
  field lane "${ARGS[0]}"; field tip "${ARGS[1]}"; field script "${ARGS[2]}"
  mkdir -p "$DATA/trunk" || die "could not make $DATA/trunk"
  printf '%s\t%s\t%s\t%s\t%s\n' "$NOW" "${ARGS[1]}" "${ARGS[2]}" "${ARGS[0]}" "$SOURCE" >> "$LEDGER" || die "could not write $LEDGER"
}

do_scan() {
  local tip script n ticket lanes
  [ -s "$LEDGER" ] || return 0
  # Each (tip, script) pair with at least MIN_LANES different lanes, that is not marked shared yet.
  while IFS=$'\t' read -r tip script n; do
    [ -s "$SHARED" ] && awk -F'\t' -v t="$tip" -v s="$script" '$2 == t && $3 == s { f = 1 } END { exit !f }' "$SHARED" && continue
    lanes=$(awk -F'\t' -v t="$tip" -v s="$script" '$2 == t && $3 == s { print $4 }' "$LEDGER" | sort -u | paste -sd, -)
    ticket=$("$FILER" ticket "$script" --project "$PROJECT" \
      --why "$n lanes failed $script on tip $tip (lanes: $lanes). One ticket fixes it for all of them; each lane waits on it and gates again when it closes.") \
      || die "could not file the shared fix ticket for $script"
    printf '%s\t%s\t%s\t%s\t%s\n' "$NOW" "$tip" "$script" "$ticket" "$n" >> "$SHARED" || die "could not write $SHARED"
    echo "shared $script tip=$tip lanes=$n ticket=$ticket"
  done < <(awk -F'\t' -v min="$MIN_LANES" '
    { k = $2 "\t" $3; if (!(k SUBSEP $4 in seen)) { seen[k SUBSEP $4] = 1; n[k]++ } }
    END { for (k in n) if (n[k] >= min) print k "\t" n[k] }' "$LEDGER" | sort)
}

do_waiting() {
  [ "${#ARGS[@]}" -eq 1 ] || die "waiting needs <lane>"
  field lane "${ARGS[0]}"
  local tip script ticket
  [ -s "$LEDGER" ] && [ -s "$SHARED" ] || return 1
  while IFS=$'\t' read -r tip script; do
    ticket=$(awk -F'\t' -v t="$tip" -v s="$script" '$2 == t && $3 == s { id = $4 } END { print id }' "$SHARED")
    [ -n "$ticket" ] || continue
    if ticket_open "$ticket"; then echo "$ticket $script tip=$tip"; return 0; fi
  done < <(awk -F'\t' -v l="${ARGS[0]}" '$4 == l { print $2 "\t" $3 }' "$LEDGER" | sort -u)
  return 1
}

case $CMD in
  record) do_record ;;
  scan) do_scan ;;
  waiting) do_waiting ;;
  *) die "unknown command: $CMD (see --help)" ;;
esac

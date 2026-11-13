#!/usr/bin/env bash
# quarantine.sh - the one flaky-script quarantine list of this repository, and the one filer of a script's fix ticket.
#
#   quarantine.sh ticket <script> [--project <name>] [--why <text>]
#       The only way a script gets a fix ticket (T5, H39, H41, H45 and done-done Q5 call it). The script path is the key:
#       the ticket id is flaky-<project>-<slug of the path>, and while that ticket is open a second call files nothing and
#       prints the same id. Prints the id.
#   quarantine.sh scan [--project <name>]
#       A script with 3 rows in the last 7 days of data/trunk/flaky-<project>.tsv (the lander's flaky ledger) enters the
#       list with its fix ticket. Prints "entered <script> ticket=<id>" for each new entry.
#   quarantine.sh record <script> green|red [--project <name>]
#       The runner reports each run of a listed script. A red is recorded and a script not on the list is ignored. The 10th green
#       in a row (a red starts the count again) takes the script off the list.
#   quarantine.sh sweep [--project <name>]
#       A script listed for 7 days leaves the list as expired: it blocks again and its ticket gets a note for its lead.
#   quarantine.sh check <script> [--project <name>]
#       Exit 0 when the script is listed and the policy key is on (its red does not block); exit 1 otherwise.
#   quarantine.sh state <script> [--project <name>]
#       none | entered (no red yet) | running (a red is recorded) | left (10 green) | expired (blocks again).
#   quarantine.sh list [--project <name>]
#       The listed scripts, one per line: script, state, ticket.
#
# The list is data/trunk/quarantine-<project>.tsv, append only: epoch, script, event, detail. The events are entered (detail
# the ticket), red, green, left and expired. The policy key is the file config/quarantine holding "on"; absent, or any other
# value, is off and `check` never excuses a script, so today's behaviour holds while the list is only kept (report mode).
# The project defaults to JG_QUARANTINE_PROJECT, else juggernaut: this list belongs to the Juggernaut repository.
set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$SELF_DIR/../.." && pwd -P)
JG_HOME="${JG_HOME:-$ROOT}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
BACKLOG="$ROOT/bin/jg-backlog.sh"
THRESHOLD=3        # flaky rows that list a script ...
WINDOW=$((7 * 86400))  # ... within this many seconds; also how long a listing lasts
GREENS_TO_LEAVE=10

die() { echo "quarantine: $*" >&2; exit 2; }

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

PROJECT=${JG_QUARANTINE_PROJECT:-juggernaut}
case ${1:-} in -h|--help|"") usage; exit 0 ;; esac
CMD=$1; shift
ARGS=() WHY=''
while [ $# -gt 0 ]; do
  case $1 in
    --project) [ $# -ge 2 ] || die "--project needs a name"; PROJECT=$2; shift 2 ;;
    --why) [ $# -ge 2 ] || die "--why needs text"; WHY=$2; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[[ $PROJECT =~ ^[A-Za-z0-9._-]+$ ]] || die "the project name has characters a file name cannot hold: $PROJECT"
LIST="$DATA/trunk/quarantine-$PROJECT.tsv"
FLAKY="$DATA/trunk/flaky-$PROJECT.tsv"
NOW=$(date +%s)

need_script() { [ "${#ARGS[@]}" -ge 1 ] && [ -n "${ARGS[0]}" ] || die "$CMD needs a script path"; SCRIPT=${ARGS[0]}; }

key_on() { [ "$(tr -d '[:space:]' < "$JG_HOME/config/quarantine" 2>/dev/null)" = on ]; }

# status_of <script>: "<state> <entered epoch> <greens in a row> <ticket>" from the append-only list.
status_of() {
  [ -f "$LIST" ] || { echo "none 0 0 -"; return; }
  awk -F'\t' -v s="$1" '
    $2 != s { next }
    $3 == "entered" { st = "entered"; at = $1; g = 0; t = $4 }
    $3 == "red" && (st == "entered" || st == "running") { st = "running"; g = 0 }
    $3 == "green" && (st == "entered" || st == "running") { g++ }
    $3 == "left" || $3 == "expired" { st = $3 }
    END { if (st == "") st = "none"; print st, at + 0, g + 0, (t == "" ? "-" : t) }' "$LIST"
}

last_end() { [ -f "$LIST" ] && awk -F'\t' -v s="$1" '$2 == s && ($3 == "left" || $3 == "expired") { a = $1 } END { print a + 0 }' "$LIST" || echo 0; }

active() { case $1 in entered|running) return 0 ;; esac; return 1; }

append() { mkdir -p "$DATA/trunk" && printf '%s\t%s\t%s\t%s\n' "$NOW" "$1" "$2" "${3:--}" >> "$LIST"; }

ticket_id() {  # <script>
  local id
  id=$(basename "$1"); id=${id%.sh}; id=${id%.test}
  printf 'flaky-%s-%s' "$PROJECT" "$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-')"
}

do_ticket() {
  local s=$1 id shown
  id=$(ticket_id "$s")
  if shown=$("$BACKLOG" show "$id" 2>/dev/null); then
    if printf '%s\n' "$shown" | grep -q '^  closed: "-"'; then printf '%s\n' "$id"; return 0; fi
    id="$id-$NOW"   # the earlier ticket is closed and the script is flaky again: a new one, still one open at a time
  fi
  "$BACKLOG" add "$id" "[blocker] flaky test $s on $PROJECT" --kind ship --priority 2 \
    --body "$s is flaky: it failed and then passed on a rerun.${WHY:+ $WHY}
Why: a flaky test hides real reds and costs every gate a rerun.
Done when: $s passes every run, or its flaky case is removed." >/dev/null 2>&1 \
    || die "could not file the fix ticket $id for $s"
  printf '%s\n' "$id"
}

do_sweep() {
  local s st at g t
  [ -f "$LIST" ] || return 0
  while IFS= read -r s; do
    read -r st at g t <<<"$(status_of "$s")"
    active "$st" && [ $((NOW - at)) -ge "$WINDOW" ] || continue
    append "$s" expired "$t"
    "$BACKLOG" update "$t" --append-notes "quarantine ended after 7 days: $s blocks again. Raised to its lead: fix it now." >/dev/null 2>&1 \
      || echo "quarantine: warning: could not note the expiry on $t" >&2
    echo "expired $s ticket=$t"
  done < <(cut -f2 "$LIST" | sort -u)
}

do_scan() {
  local s st at g t id n
  [ -f "$FLAKY" ] || return 0
  do_sweep
  while IFS= read -r s; do
    read -r st at g t <<<"$(status_of "$s")"
    ! active "$st" || continue
    # Rows from before this script last left the list do not count again.
    n=$(awk -F'\t' -v s="$s" -v from=$((NOW - WINDOW)) -v after="$(last_end "$s")" \
      '$3 == s && $1 >= from && $1 > after { c++ } END { print c + 0 }' "$FLAKY")
    [ "$n" -ge "$THRESHOLD" ] || continue
    id=$(do_ticket "$s") || exit 2
    append "$s" entered "$id"
    echo "entered $s ticket=$id"
  done < <(awk -F'\t' -v from=$((NOW - WINDOW)) '$1 >= from { print $3 }' "$FLAKY" | sort -u)
}

do_record() {
  local s=$1 result=${ARGS[1]:-} st at g t
  case $result in green|red) ;; *) die "record needs green or red after the script" ;; esac
  read -r st at g t <<<"$(status_of "$s")"
  active "$st" || return 0
  append "$s" "$result" "$t"
  if [ "$result" = green ] && [ $((g + 1)) -ge "$GREENS_TO_LEAVE" ]; then
    append "$s" left "$t"
    echo "left $s after $GREENS_TO_LEAVE green runs in a row ticket=$t"
  fi
}

case $CMD in
  ticket) need_script; do_ticket "$SCRIPT" ;;
  scan) do_scan ;;
  sweep) do_sweep ;;
  record) need_script; do_sweep >/dev/null; do_record "$SCRIPT" ;;
  check)
    need_script; do_sweep >/dev/null
    key_on || exit 1
    read -r st _ _ _ <<<"$(status_of "$SCRIPT")"
    active "$st" ;;
  state) need_script; status_of "$SCRIPT" | cut -d' ' -f1 ;;
  list)
    [ -f "$LIST" ] || exit 0
    while IFS= read -r s; do
      read -r st _ _ t <<<"$(status_of "$s")"
      ! active "$st" || printf '%s\t%s\t%s\n' "$s" "$st" "$t"
    done < <(cut -f2 "$LIST" | sort -u) ;;
  *) die "unknown command: $CMD (see --help)" ;;
esac

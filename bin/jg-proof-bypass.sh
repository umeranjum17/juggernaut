#!/usr/bin/env bash
# jg-proof-bypass.sh - the owner's bypass of proving: one record, one command (machine 17 of the state-machine plan).
#
# Usage:
#   jg-proof-bypass.sh grant (--ticket <id> | --project <name> | --home) --word <id> [--until <when> | --hours <n>]
#   jg-proof-bypass.sh end <bypass-id>
#   jg-proof-bypass.sh list [--standing]
#   jg-proof-bypass.sh find <ticket-id> [<project>]   print the id of the bypass that covers the ticket; exit 1 when none stands
#   jg-proof-bypass.sh use <bypass-id>                count one use of a standing bypass
#   jg-proof-bypass.sh expire                         the tick: end what has reached its end (prints one line for each)
#   jg-proof-bypass.sh verify <bypass-id> <word>      exit 0 when that bypass row exists (standing or ended) with that word
#   jg-proof-bypass.sh show <bypass-id>               print scope, target and word of the bypass, tab separated; exit 1 when unknown
#   jg-proof-bypass.sh state <bypass-id>              print standing or ended (what the bypass table's observer reads); exit 1 when unknown
#   jg-proof-bypass.sh digest                         one line for each standing bypass, with its uses; nothing when none stands
#
# The record is config/proof-bypass, one line for each bypass, written only by this command (the pattern of the trunk's waiver in
# bin/jg-trunk.sh): id, scope (ticket, project or home), target (the ticket, the project or -), word, granted, end, status
# (standing or ended), uses, ended_at, ended_why. Only the owner's recorded word sets it: --word is the id of an owner rule
# (owner-rule-<id>) or of a board answer that holds his exact words (board-answer:<card-key>). A worker never writes it: a call with
# JG_TASK_ID set is refused. A bypass for a project or the home carries an end time; <when> is an epoch or YYYY-MM-DDTHH:MMZ, and with
# none the end is 24 hours after the grant. A ticket's bypass has no end time: it ends when the ticket is released or closed.
# `when` is read once: a status of standing past its end time reads ended at once, before the tick writes it.
# The stage of a ticket comes from `jg-machine.sh show ticket <id>`; JG_PROOF_BYPASS_STAGE_CMD names another reader (it prints the stage).
# Exit: 0 done, 1 refused or none found, 2 usage.
# shellcheck disable=SC2016 # the awk programs are single-quoted on purpose
set -u
export LC_ALL=C
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}}
CONFIG=${JG_CONFIG_OVERRIDE:-$JG_HOME/config}; STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
FILE=$CONFIG/proof-bypass
DEFAULT_HOURS=24
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"

refuse() { echo "REFUSED: $*" >&2; exit 1; }
usage() { sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
now() { date +%s; }

# Every line of the file, with the effective status in column 7: standing past its end time reads ended.
rows() {
  [ -s "$FILE" ] || return 0
  awk -F'\t' -v OFS='\t' -v now="$(now)" '$7 == "standing" && $6 != "-" && $6 + 0 <= now { $7 = "ended" } { print }' "$FILE"
}

write_locked() {  # <awk program> [awk -v args...]: rewrite the file through one awk program, under the lock
  local prog=$1; shift; local tmp
  mkdir -p "$CONFIG" "$STATE"
  jg_lock_acquire_wait "$STATE/.proof-bypass.lock" || refuse "could not lock the bypass record"
  tmp=$(mktemp "$FILE.XXXXXX") || { jg_lock_release "$STATE/.proof-bypass.lock"; refuse "cannot write $FILE"; }
  if awk -F'\t' -v OFS='\t' "$@" "$prog" "$FILE" > "$tmp" 2>/dev/null; then mv -f -- "$tmp" "$FILE"; else rm -f -- "$tmp"; fi
  jg_lock_release "$STATE/.proof-bypass.lock" || true
}

epoch_of() {  # <epoch|YYYY-MM-DDTHH:MMZ>: print an epoch or fail
  case $1 in
    ''|*[!0-9]*) date -u -d "$1" +%s 2>/dev/null ;;
    *) printf '%s\n' "$1" ;;
  esac
}

stage_of() {  # <ticket>: the stage word of the ticket, or nothing
  if [ -n "${JG_PROOF_BYPASS_STAGE_CMD:-}" ]; then $JG_PROOF_BYPASS_STAGE_CMD "$1" 2>/dev/null | head -n 1; return 0; fi
  bash "$SCRIPT_DIR/jg-machine.sh" show ticket "$1" 2>/dev/null | awk -F'\t' '$1 == "state" { print $2; exit }'
}

cmd_grant() {
  local scope='' target='-' word='' end='' hours='' t id
  t=$(now)
  [ -z "${JG_TASK_ID:-}" ] || refuse "a worker never writes a proof bypass"
  while [ "$#" -gt 0 ]; do
    case $1 in
      --ticket|--project) [ -z "$scope" ] || refuse "one scope for each bypass: a ticket, a project or the home"
        [ "$#" -ge 2 ] && [ -n "$2" ] || usage; scope=${1#--}; target=$2; shift 2 ;;
      --home) [ -z "$scope" ] || refuse "one scope for each bypass: a ticket, a project or the home"; scope=home; shift ;;
      --word) [ "$#" -ge 2 ] || usage; word=$2; shift 2 ;;
      --until) [ "$#" -ge 2 ] || usage; end=$(epoch_of "$2") || refuse "'$2' is not an epoch or YYYY-MM-DDTHH:MMZ"; shift 2 ;;
      --hours) [ "$#" -ge 2 ] || usage; hours=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$scope" ] || refuse "name the scope: --ticket <id>, --project <name> or --home"
  [[ $target =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || $target = - ]] || refuse "'$target' is not a ticket id or project name"
  [ -n "$word" ] || refuse "a bypass names the id of the owner rule or the board answer that holds the owner's words: --word owner-rule-<id> or board-answer:<card-key>"
  case $word in
    owner-rule-[A-Za-z0-9]*|board-answer:[A-Za-z0-9]*) ;;
    *) refuse "'$word' is not an owner rule id (owner-rule-<id>) or a board answer (board-answer:<card-key>)" ;;
  esac
  if [ -n "$hours" ]; then
    [ -z "$end" ] || refuse "give --until or --hours, not both"
    case $hours in ''|*[!0-9]*|0) refuse "--hours needs a whole number above 0" ;; esac
    end=$(( t + hours * 3600 ))
  fi
  if [ "$scope" = ticket ]; then
    [ -z "$end" ] || refuse "a ticket's bypass has no end time: it ends when the ticket is released or closed"
    end=-
  else
    [ -n "$end" ] || end=$(( t + DEFAULT_HOURS * 3600 ))
    [ "$end" -gt "$t" ] || refuse "the end time is already past"
  fi
  id="bp-$t-$(printf '%s' "$scope $target $word $t" | cksum | awk '{ printf "%06x", $1 % 16777216 }')"
  mkdir -p "$CONFIG" "$STATE"
  jg_lock_acquire_wait "$STATE/.proof-bypass.lock" || refuse "could not lock the bypass record"
  printf '%s\t%s\t%s\t%s\t%s\t%s\tstanding\t0\t-\t-\n' "$id" "$scope" "$target" "$word" "$t" "$end" >> "$FILE"
  jg_lock_release "$STATE/.proof-bypass.lock" || true
  if [ "$end" = - ]; then end="when the ticket is released or closed"; else end=$(date -u -d "@$end" +%Y-%m-%dT%H:%MZ); fi
  echo "bypass $id standing: $scope ${target/#-/(the home)} under $word, ends $end"
}

cmd_end() {
  local id=${1-}
  [ -z "${JG_TASK_ID:-}" ] || refuse "a worker never ends a proof bypass"
  [ -n "$id" ] || usage
  rows | awk -F'\t' -v i="$id" '$1 == i && $7 == "standing" { f = 1 } END { exit !f }' || refuse "no standing bypass $id"
  write_locked '$1 == i && $7 == "standing" { $7 = "ended"; $9 = t; $10 = "owner" } { print }' -v i="$id" -v t="$(now)"
  echo "bypass $id ended; the next done line in its scope is proved"
}

cmd_list() {
  local only=${1-} id scope target word end st uses e
  [ -s "$FILE" ] || { echo "no proof bypass on record"; return 0; }
  while IFS=$'\t' read -r id scope target word _ end st uses _; do
    [ "$only" != --standing ] || [ "$st" = standing ] || continue
    if [ "$end" = - ]; then e="when the ticket is released or closed"; else e=$(date -u -d "@$end" +%Y-%m-%dT%H:%MZ); fi
    [ "$target" != - ] || target="(the home)"
    printf '%s\t%s\t%s\t%s\tword=%s\tends=%s\tuses=%s\n' "$id" "$st" "$scope" "$target" "$word" "$e" "$uses"
  done < <(rows)
}

cmd_find() {  # the ticket's own bypass first, then its project, then the home
  local t=${1-} p=${2-}
  [ -n "$t" ] || usage
  rows | awk -F'\t' -v t="$t" -v p="$p" '$7 != "standing" { next }
    $2 == "ticket" && $3 == t { a = $1 } $2 == "project" && p != "" && $3 == p { b = $1 } $2 == "home" { c = $1 }
    END { r = a ? a : (b ? b : c); if (r == "") exit 1; print r }'
}

cmd_use() {
  local id=${1-}
  [ -z "${JG_TASK_ID:-}" ] || refuse "a worker never records the use of a proof bypass"
  [ -n "$id" ] || usage
  rows | awk -F'\t' -v i="$id" '$1 == i && $7 == "standing" { f = 1 } END { exit !f }' || refuse "no standing bypass $id"
  write_locked '$1 == i && $7 == "standing" { $8 += 1 } { print }' -v i="$id"
}

cmd_expire() {
  local id scope target end st why t ended=''
  t=$(now)
  [ -s "$FILE" ] || return 0
  while IFS=$'\t' read -r id scope target _ _ end st _; do
    [ "$st" = standing ] || continue
    why=''
    if [ "$scope" = ticket ]; then
      case $(stage_of "$target") in released|closed) why="ticket $target is $(stage_of "$target")" ;; esac
    elif [ "$end" != - ] && [ "$end" -le "$t" ]; then why="end time reached"
    fi
    [ -n "$why" ] || continue
    ended="$ended$id	$why
"
  done < "$FILE"
  [ -n "$ended" ] || return 0
  while IFS=$'\t' read -r id why; do
    [ -n "$id" ] || continue
    write_locked '$1 == i && $7 == "standing" { $7 = "ended"; $9 = t; $10 = w } { print }' -v i="$id" -v t="$t" -v w="$why"
    echo "proof bypass $id ended: $why"
  done <<< "$ended"
}

cmd_verify() { rows | awk -F'\t' -v i="${1-}" -v w="${2-}" '$1 == i && $4 == w { f = 1 } END { exit !f }'; }

cmd_show() { rows | awk -F'\t' -v i="${1-}" '$1 == i { print $2 "\t" $3 "\t" $4; f = 1 } END { exit !f }'; }

cmd_state() { rows | awk -F'\t' -v i="${1-}" '$1 == i { print $7; f = 1 } END { exit !f }'; }

cmd_digest() {
  local out
  out=$(cmd_list --standing)
  case $out in ''|'no proof bypass on record') return 0 ;; esac
  echo "proof bypass (the owner's word; no proof runs for a ticket in its scope; bin/jg-proof-bypass.sh list):"
  printf '%s\n' "$out" | awk -F'\t' '{ printf "  %s %s %s %s %s %s\n", $1, $3, $4, $5, $6, $7 }'
}

c=${1-}; [ "$#" -eq 0 ] || shift
case $c in
  grant) cmd_grant "$@" ;;
  end) cmd_end "$@" ;;
  list) cmd_list "$@" ;;
  find) cmd_find "$@" ;;
  use) cmd_use "$@" ;;
  expire) cmd_expire ;;
  verify) cmd_verify "$@" ;;
  show) cmd_show "$@" ;;
  state) cmd_state "$@" ;;
  digest) cmd_digest ;;
  *) usage ;;
esac

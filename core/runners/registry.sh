#!/usr/bin/env bash
# runners registry: the machines the owner registered to run work besides this host (H30a).
# Usage: registry.sh get <jg-home> <id>      print the record as key=value lines; exit 1 when absent or malformed
#        registry.sh list <jg-home>          print the id of every registered runner; no file or no record prints nothing
#        registry.sh usable <jg-home> [--private]   print the id of every runner whose latest probe passed, own machines first;
#                                            with --private only runners with private_ok=yes (a private repository stays on owned machines)
#        registry.sh free <jg-home> <id>     print the free cores of the latest passed probe of the runner; exit 1 when it has none
# Record  one line of config/runners, `#` lines and blank lines ignored:
#   <id> ssh=<alias> root=<code root> home=<runner home> arch=<x86_64|arm64> cores=<n> mem_gb=<n> slots=<n> cost_per_hour=<usd> private_ok=<yes|no>
#   A runner is a remote home of kind runner: no lead agent and no lanes. cost_per_hour 0 is an own machine; above 0 is a cloud machine.
# Health  state/runner-health.tsv, written by probe.sh, tab separated: <epoch> <id> <ok|failed> <free cores> <why>
#   The latest row of an id decides. A runner with no row, or a failed row, gets no work: `usable` never names it.
# With no runner registered `usable` prints nothing and every run stays on this host.
set -u
usage() { echo "usage: registry.sh get|list|usable <jg-home> [id|--private] | free <jg-home> <id>" >&2; exit 2; }
[ "$#" -ge 2 ] && [ -d "$2" ] || usage
CMD=$1
HOME_DIR=$2
CONFIG="${JG_CONFIG_OVERRIDE:-$HOME_DIR/config}"
STATE="${JG_STATE_OVERRIDE:-$HOME_DIR/state}"
FILE="$CONFIG/runners"
HEALTH="$STATE/runner-health.tsv"

# record_ok <line>: the line is one well-formed record; prints it with its id first.
record_ok() {
  local line=$1 id kv key val seen=" "
  # shellcheck disable=SC2086 # a record is plain fields
  set -- $line
  id=${1:-}
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  shift
  for kv in "$@"; do
    key=${kv%%=*}
    val=${kv#*=}
    [ "$key" != "$kv" ] && [ -n "$val" ] || return 1
    case "$seen" in *" $key "*) return 1 ;; esac
    seen="$seen$key "
    case "$key" in
      ssh) case "$val" in -*|*[!A-Za-z0-9._-]*) return 1 ;; esac ;;
      root|home) case "$val" in /*) ;; *) return 1 ;; esac
        case "/$val/" in */../*|*/./*) return 1 ;; esac ;;
      arch) case "$val" in x86_64|arm64) ;; *) return 1 ;; esac ;;
      cores|mem_gb|slots) case "$val" in *[!0-9]*|0*) return 1 ;; esac ;;
      cost_per_hour) case "$val" in *[!0-9.]*|*.*.*|.|'') return 1 ;; esac ;;
      private_ok) case "$val" in yes|no) ;; *) return 1 ;; esac ;;
      *) return 1 ;;
    esac
  done
  for key in ssh root home arch cores mem_gb slots cost_per_hour private_ok; do
    case "$seen" in *" $key "*) ;; *) return 1 ;; esac
  done
}

records() {
  local line
  [ -f "$FILE" ] && [ ! -L "$FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*|' '*'#'*) continue ;; esac
    record_ok "$line" && printf '%s\n' "$line"
  done < "$FILE"
}

latest_health() { # <id>: the id's last health row
  [ -f "$HEALTH" ] || return 0
  awk -F'\t' -v id="$1" '$2 == id { row = $0 } END { if (row != "") print row }' "$HEALTH"
}

case "$CMD" in
  list) records | while read -r id _; do printf '%s\n' "$id"; done ;;
  get)
    [ "$#" -eq 3 ] || usage
    line=$(records | awk -v id="$3" '$1 == id { print; exit }')
    [ -n "$line" ] || { echo "error: no valid runner record for '$3' in $FILE" >&2; exit 1; }
    # shellcheck disable=SC2086 # a record is plain fields
    set -- $line
    printf 'id=%s\n' "$1"
    shift
    printf '%s\n' "$@"
    ;;
  free)
    [ "$#" -eq 3 ] || usage
    row=$(latest_health "$3")
    [ "$(printf '%s' "$row" | cut -f3)" = ok ] || exit 1
    printf '%s\n' "$(printf '%s' "$row" | cut -f4)"
    ;;
  usable)
    PRIVATE=0
    case "${3:-}" in '') ;; --private) PRIVATE=1 ;; *) usage ;; esac
    # Own machines first (cost 0), then by id, so placement takes the cheapest ready runner.
    records | while read -r id rest; do
      cost=${rest##*cost_per_hour=}
      cost=${cost%% *}
      row=$(latest_health "$id")
      [ "$(printf '%s' "$row" | cut -f3)" = ok ] || continue
      [ "$PRIVATE" -eq 0 ] || case " $rest " in *" private_ok=yes "*) ;; *) continue ;; esac
      printf '%s\t%s\n' "$cost" "$id"
    done | sort -g -k1,1 -k2,2 | cut -f2
    ;;
  *) usage ;;
esac

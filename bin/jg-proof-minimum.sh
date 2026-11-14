#!/usr/bin/env bash
# jg-proof-minimum.sh set <ticket> --checks <journey[,journey]> [--named-by <who>]
#                     show <ticket>
#                     verify <ticket> --outcome "<what a user can now do>"
# The lead sets `proof: minimum` on a ticket with the checks it names (bin/jg-proof-minimum-lib.sh owns the field);
# `verify` hands that list to `done-done verify --journeys` (done-done 0.6.27, slice Q10), so the receipt says `minimum`,
# who named the checks and which affected journeys did not run. A worker session never sets the field.
set -u
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/jg-proof-minimum-lib.sh
. "$SCRIPT_DIR/jg-proof-minimum-lib.sh"
JG_HOME=${JG_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
CONFIG=${JG_CONFIG_OVERRIDE:-$JG_HOME/config}
fail() { echo "jg-proof-minimum: $*" >&2; exit 1; }

cmd=${1:-}; [ "$#" -eq 0 ] || shift
ticket=${1:-}; [ "$#" -eq 0 ] || shift
[ -n "$ticket" ] || fail "usage: jg-proof-minimum.sh set|show|verify <ticket> ..."
checks=''; named_by=''; outcome=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --checks|--named-by|--outcome) [ "$#" -ge 2 ] && [ -n "$2" ] || fail "$1 needs a value"
      case "$1" in --checks) checks=$2 ;; --named-by) named_by=$2 ;; --outcome) outcome=$2 ;; esac; shift 2 ;;
    *) fail "unknown argument $1" ;;
  esac
done

case "$cmd" in
  set)
    [ -z "${JG_TASK_ID:-}" ] || fail "a worker session never sets the proof level; the lead names the checks"
    [ -n "$checks" ] || fail "set needs --checks <journey[,journey]>: the checks the lead names"
    jg_proof_minimum_write "$CONFIG" "$ticket" "$checks" "${named_by:-lead}" || exit 1
    echo "proof: minimum on $ticket, checks $checks, named by ${named_by:-lead}" ;;
  show)
    row=$(jg_proof_minimum_read "$CONFIG" "$ticket") || { echo "proof: full"; exit 0; }
    echo "proof: minimum, checks ${row%%$'\t'*}, named by ${row#*$'\t'}" ;;
  verify)
    [ -n "$outcome" ] || fail "verify needs --outcome \"<what a user can now do>\""
    row=$(jg_proof_minimum_read "$CONFIG" "$ticket") || fail "ticket $ticket carries no \`proof: minimum\` field; run the full proof"
    exec "${JG_DONE_DONE_BIN:-done-done}" verify --journeys "${row%%$'\t'*}" --named-by "${row#*$'\t'}" --outcome "$outcome" ;;
  *) fail "usage: jg-proof-minimum.sh set|show|verify <ticket> ..." ;;
esac

#!/usr/bin/env bash
# One owner of the minimum proof level (core/machines/proof-level.states: full, minimum, bypass).
# "Bare-minimum checks" is a field on the ticket, never a sentence in a brief: `proof: minimum` plus the checks the
# lead names (metadata proof, proof_checks, proof_named_by). It is a small proof and not a bypass: the worker still
# runs done-done, which drives only the named journeys, seals, and writes a receipt that says `minimum`, who named
# the checks and which affected journeys did not run (`done-done verify --journeys ... --named-by ...`).
# Sourced by bin/jg-brief.sh (writes the field, refuses the old sentence) and run by bin/jg-proof-minimum.sh.

# jg_proof_minimum_old_sentence <file>: succeeds when the text still says it in words.
jg_proof_minimum_old_sentence() {
  grep -Eiq 'bare[- ]minimum (checks?|proof|verification)|minimal checks only' "$1" 2>/dev/null
}

# jg_proof_minimum_form: the new form, printed in every refusal.
jg_proof_minimum_form() {
  printf '%s' "set the field on the ticket instead of writing a sentence: jg-brief.sh <task-id> <repo> --ticket <ticket> --proof minimum --proof-checks <journey> [--proof-named-by <who>] (or bin/jg-proof-minimum.sh set <ticket> --checks <journey>); the worker then runs bin/jg-proof-minimum.sh verify <ticket> --outcome \"<what a user can now do>\""
}

# jg_proof_minimum_valid_checks <list>: journey names, comma separated, no blanks.
jg_proof_minimum_valid_checks() {
  case "$1" in ''|*[!A-Za-z0-9._,/-]*|,*|*,|*,,*) return 1 ;; esac
}

# jg_proof_minimum_store <config>: the ticket store, or the reason it is missing.
_jg_proof_minimum_bd() {  # <config> <beads args...>
  local cfg=$1 lib_dir store
  shift
  lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  # shellcheck source=bin/jg-backlog-lib.sh disable=SC1091
  . "$lib_dir/jg-backlog-lib.sh"
  store=$(jg_backlog_beads_store "$cfg") || return 2
  BEADS_DIR=$store "$lib_dir/jg-beads.sh" "$@"
}

# jg_proof_minimum_write <config> <ticket> <checks> <named-by>: the one writer of the field.
jg_proof_minimum_write() {
  jg_proof_minimum_valid_checks "$3" || { echo "error: --proof-checks names journeys separated by commas (got '$3')" >&2; return 1; }
  [ -n "$4" ] || { echo "error: the checks need a name for who named them" >&2; return 1; }
  _jg_proof_minimum_bd "$1" update "$2" --set-metadata proof=minimum --set-metadata "proof_checks=$3" \
    --set-metadata "proof_named_by=$4" >/dev/null || { echo "error: could not write the proof field on ticket $2" >&2; return 1; }
}

# jg_proof_minimum_read <config> <ticket>: prints `checks<TAB>named-by` when the ticket carries `proof: minimum`; fails otherwise.
jg_proof_minimum_read() {
  local json
  json=$(_jg_proof_minimum_bd "$1" show "$2" --json 2>/dev/null) || return 1
  jq -er '(if type == "array" then .[0] else . end).metadata // {}
    | select(.proof == "minimum" and ((.proof_checks // "") != "")) | "\(.proof_checks)\t\(.proof_named_by // "lead")"' <<<"$json"
}

# jg_proof_minimum_section <checks> <named-by> <task-id>: the brief section that hands the list to the worker.
jg_proof_minimum_section() {
  local bin
  bin=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/jg-proof-minimum.sh
  # shellcheck disable=SC2016
  printf '\n\n# Proof: minimum\nThe ticket carries `proof: minimum`: %s named these checks: `%s`. It is a small proof, not a bypass: done-done runs and the reviewer runs.\nAt your final clean head run `%s verify %s --outcome "<what a user can now do>"`; it drives only those checks and seals, and the receipt records `minimum`, who named the checks and the affected journeys that did not run. Run nothing wider by hand, and do not edit the field.' \
    "$2" "$1" "$bin" "$3"
}

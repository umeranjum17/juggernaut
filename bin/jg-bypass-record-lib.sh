#!/usr/bin/env bash
# jg-bypass-record-lib.sh - the bypass record of a lane: what stands in the place of a completion receipt while the owner's bypass
# of proving is in force (machine 17, bin/jg-proof-bypass.sh). Sourced, never run.
#
# The record is state/<task>.bypass-record.json, written only by bin/jg-proof-bypass-apply.sh (the tick) and read by the proof gate
# (jg_dod_trunk_proof_gaps in bin/jg-merge-gate-lib.sh). A bypass is never a pass: no receipt is written and no check ran. Its fields:
#   kind=bypass, task, ticket, commit (the exact head of the done line, and again the rebased head), scope (ticket, project or home),
#   bypass (the id of the row in config/proof-bypass), by=owner, word (the owner rule or board answer that holds his words),
#   at (RFC3339 UTC), done_at (the epoch of the done line it answers), checks=none ran, review=none ran, proof="no proof ran".
# A record counts for a head only when its commit is that head and its bypass row exists in config/proof-bypass with the same word,
# so a record written by hand cannot stand in for a proof. Needs jq.

jg_bypass_record_file() { printf '%s/%s.bypass-record.json\n' "$1" "$2"; }  # <state> <task>

# jg_bypass_record_write <state> <task> <ticket> <commit> <bypass-id> <scope> <word> <done-epoch>: write the record atomically.
jg_bypass_record_write() {
  local file tmp
  file=$(jg_bypass_record_file "$1" "$2")
  tmp=$(mktemp "$file.XXXXXX") || return 1
  if jq -n --arg task "$2" --arg ticket "$3" --arg commit "$4" --arg bypass "$5" --arg scope "$6" --arg word "$7" --argjson doneat "${8:-0}" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema: 1, kind: "bypass", task: $task, ticket: $ticket, commit: $commit, scope: $scope, bypass: $bypass, by: "owner", word: $word,
      at: $at, done_at: $doneat, checks: "none ran", review: "none ran", proof: "no proof ran"}' > "$tmp"; then
    mv -f -- "$tmp" "$file"
  else
    rm -f -- "$tmp"; return 1
  fi
}

# jg_bypass_record_holds <home> <state> <task> <head>: 0 when a bypass record names this head and its bypass row exists with its word.
jg_bypass_record_holds() {
  local file bp word dir
  file=$(jg_bypass_record_file "$2" "$3")
  [ -f "$file" ] && command -v jq >/dev/null 2>&1 || return 1
  jq -e --arg h "$4" --arg t "$3" '.kind == "bypass" and .task == $t and .commit == $h' "$file" >/dev/null 2>&1 || return 1
  bp=$(jq -r '.bypass // empty' "$file"); word=$(jq -r '.word // empty' "$file")
  dir=${BASH_SOURCE[0]%/*}
  [ -n "$bp" ] && [ -n "$word" ] && JG_HOME=$1 bash "$dir/jg-proof-bypass.sh" verify "$bp" "$word" >/dev/null 2>&1
}

# jg_bypass_standing <home> <task> <project-name>: print the id of the standing bypass that covers the ticket; 1 when none does.
jg_bypass_standing() { JG_HOME=$1 bash "${BASH_SOURCE[0]%/*}/jg-proof-bypass.sh" find "$2" "$3" 2>/dev/null; }

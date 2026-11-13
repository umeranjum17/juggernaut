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

# The words a bypassed change carries wherever it is shown (J26c). One owner, so the proof status, the release body, the report and
# the board read the same text. A record counts only when jg_bypass_record_holds says it is genuine at its own commit.
JG_BYPASS_UNPROVED_WORD=unproved
# shellcheck disable=SC2034 # read by bin/jg-live-claim.sh, which sources this file
JG_BYPASS_NOT_PROVEN='not proven: bypassed by the owner'

# jg_bypass_mark_line <home> <state> <task>: print `bypassed: no proof ran (word <word>)` for a task with a genuine record; 1 when none.
jg_bypass_mark_line() {
  local file commit word
  file=$(jg_bypass_record_file "$2" "$3")
  [ -f "$file" ] && command -v jq >/dev/null 2>&1 || return 1
  commit=$(jq -r '.commit // empty' "$file" 2>/dev/null); word=$(jq -r '.word // empty' "$file" 2>/dev/null)
  [ -n "$commit" ] && jg_bypass_record_holds "$1" "$2" "$3" "$commit" || return 1
  printf 'bypassed: no proof ran (word %s)\n' "$word"
}

# jg_bypass_release_lines <home> <state> <commit>...: one line for each genuine record whose commit is among the release's commits,
# `- <short commit> <ticket>: unproved, bypassed by the owner (word <word>)`. Prints nothing when none of them was bypassed.
jg_bypass_release_lines() {
  local home=$1 state=$2 file task commit
  shift 2
  for file in "$state"/*.bypass-record.json; do
    [ -f "$file" ] || continue
    task=$(jq -r '.task // empty' "$file" 2>/dev/null); commit=$(jq -r '.commit // empty' "$file" 2>/dev/null)
    [ -n "$task" ] && [ -n "$commit" ] || continue
    case " $* " in *" $commit "*) ;; *) continue ;; esac
    jg_bypass_mark_line "$home" "$state" "$task" >/dev/null || continue
    printf -- '- %s %s: %s, bypassed by the owner (word %s)\n' "${commit:0:12}" "$(jq -r '.ticket // .task' "$file")" "$JG_BYPASS_UNPROVED_WORD" "$(jq -r '.word' "$file")"
  done
}

# jg_bypass_claim_ticket <home> <state> <claim>: print the task of a genuine record that the claim names (by task or ticket id); 1 when none.
jg_bypass_claim_ticket() {
  local file task ticket
  for file in "$2"/*.bypass-record.json; do
    [ -f "$file" ] || continue
    task=$(jq -r '.task // empty' "$file" 2>/dev/null); ticket=$(jq -r '.ticket // empty' "$file" 2>/dev/null)
    for id in "$task" "$ticket"; do
      [ -n "$id" ] || continue
      printf '%s\n' "$3" | grep -Eq -- "(^|[^[:alnum:]_.-])$id([^[:alnum:]_.-]|\$)" || continue
      jg_bypass_mark_line "$1" "$2" "$task" >/dev/null && { printf '%s\n' "$task"; return 0; }
    done
  done
  return 1
}

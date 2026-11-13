#!/usr/bin/env bash
# The proof of a pull request, as the forge shows it and as bin/jg-pr-merge.sh needs it.
# Usage: . bin/jg-proof-status-lib.sh
#
# Two kinds of pull request carry two kinds of proof. Nothing here is set as required on the forge:
# bin/jg-pr-merge.sh is the enforcement point and calls jg_proof_merge_gate.
#
# A release pull request (the local trunk going into the default branch) holds many commits, and no
# one committed receipt can cover its head. Its proof is the release proof that bin/jg-trunk-release-proof.sh
# runs at that head inside done-done. Our host publishes its pass as the commit status
# juggernaut/release-proof on that head (jg_proof_status_publish, called by bin/jg-trunk.sh). The merge
# needs the newest status of that context at the exact head to be success; a head with no status is red.
#
# One worker's pull request that commits a receipt (a file under .done-done-receipts/ in the pull
# request's own diff) is checked by the receipt check, `done-done gate <head>`: it passes only when a
# committed receipt names the head or an ancestor of it, with only receipt files changed since. A pull
# request that commits no receipt is outside this gate; the done-done run record and the merge card still
# prove it as before.
#
# Every function reads the forge through gh and returns nonzero with its reason on stdout.
JG_PROOF_STATUS_CONTEXT=juggernaut/release-proof
JG_PROOF_RECEIPT_DIR=.done-done-receipts

# jg_proof_status_publish <owner/repo> <head> <success|failure|pending> <line> [<target-url>]
jg_proof_status_publish() {
  local slug=$1 head=$2 state=$3 line=$4 url=${5-}
  case $state in success | failure | pending) ;; *) return 1 ;; esac
  line=$(printf '%s' "$line" | tr '\n\t' '  ' | cut -c1-140)
  gh api -X POST "repos/$slug/statuses/$head" -f state="$state" -f context="$JG_PROOF_STATUS_CONTEXT" \
    -f description="$line" ${url:+-f target_url="$url"} >/dev/null
}

# The state of the newest release-proof status at <head>: success, failure, error, pending or none.
jg_proof_status_read() {  # <owner/repo> <head>
  local json
  json=$(gh api "repos/$1/commits/$2/statuses" 2>/dev/null) || return 1
  jq -r --arg c "$JG_PROOF_STATUS_CONTEXT" '[.[] | select(.context == $c)][0].state // "none"' <<<"$json" 2>/dev/null
}

# 0 when the head carries a successful release proof.
jg_proof_release_gate() {  # <owner/repo> <head>
  local state
  state=$(jg_proof_status_read "$1" "$2") || { echo "the $JG_PROOF_STATUS_CONTEXT status of ${2:0:12} could not be read from the forge"; return 1; }
  [ "$state" = success ] && return 0
  if [ "$state" = none ]; then
    echo "the release head ${2:0:12} has no $JG_PROOF_STATUS_CONTEXT status: run bin/jg-trunk.sh release to prove it"
  else
    echo "the $JG_PROOF_STATUS_CONTEXT status of ${2:0:12} is \"$state\", not success"
  fi
  return 1
}

# 0 when the pull request commits no receipt, or the receipt check passes at <head> in <worktree>.
jg_proof_receipt_gate() {  # <owner/repo> <pr-number> <head> <worktree>
  local files out rc=0
  files=$(gh api --paginate "repos/$1/pulls/$2/files" --jq '.[].filename' 2>/dev/null) || { echo "the files of pull request $2 could not be read from the forge"; return 1; }
  grep -q "^$JG_PROOF_RECEIPT_DIR/" <<<"$files" || return 0
  if [ ! -d "$4" ] || [ "$(git -C "$4" rev-parse HEAD 2>/dev/null)" != "$3" ]; then
    echo "the pull request commits a receipt, but its local copy is not at the head ${3:0:12}, so the receipt check cannot run"
    return 1
  fi
  command -v done-done >/dev/null 2>&1 || { echo "the pull request commits a receipt, but done-done is not installed to check it"; return 1; }
  out=$(cd "$4" && done-done gate "$3" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] && return 0
  echo "the receipt check refused head ${3:0:12}: $out"
  return 1
}

# The merge gate: a release pull request needs its release proof status, any other the receipt check.
jg_proof_merge_gate() {  # <meta> <owner/repo> <pr-number> <head>
  local kind worktree
  kind=$(jg_dod_meta_value "$1" kind 2>/dev/null) || kind=
  if [ "$kind" = release ]; then
    jg_proof_release_gate "$2" "$4"
  else
    worktree=$(jg_dod_meta_value "$1" worktree 2>/dev/null) || worktree=
    jg_proof_receipt_gate "$2" "$3" "$4" "$worktree"
  fi
}

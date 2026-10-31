#!/usr/bin/env bash
# jg-owner-rules-gate.sh <task-id> <worktree|-> <head|-> <pr-url|-> - local proof authorization and merge gate.
# Run `init-key` once in the captain's home, then use `sign <task-id> <head> <pr-url|->` only after the passed-proof recipe succeeds.
# The private key stays in the main home's config; the merge gate verifies its detached signature with the public key.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true
set -u
mode=gate
case ${1:-} in sign|init-key) mode=$1; shift ;; esac
if [ -z "${JG_HOME:-}" ] || [ ! -e "$JG_HOME/config/owner-rules" ]; then
  [ "$mode" = gate ] && exit 0
  echo "owner-rules: config/owner-rules is not enabled" >&2
  exit 1
fi
command -v openssl >/dev/null 2>&1 || { echo "owner-rules: OpenSSL is required for local proof signatures" >&2; exit 1; }
key_home=${JG_MAIN_HOME:-$JG_HOME}
pub=$key_home/config/owner-rules-proof.pub
private=$key_home/config/owner-rules-proof.key
if [ "$mode" = init-key ]; then
  [ "$#" -eq 0 ] || { echo "usage: jg-owner-rules-gate.sh init-key" >&2; exit 2; }
  [ ! -e "$private" ] && [ ! -e "$pub" ] || { echo "owner-rules: local proof key already exists; it was not replaced" >&2; exit 1; }
  tmp=$(mktemp -d "$key_home/config/.owner-proof-key.XXXXXX") || exit 1
  if ! openssl genpkey -algorithm ED25519 -out "$tmp/private.pem" 2>/dev/null ||
    ! openssl pkey -in "$tmp/private.pem" -pubout -out "$tmp/public.pem" 2>/dev/null ||
    ! chmod 600 "$tmp/private.pem" || ! mv -- "$tmp/private.pem" "$private" || ! mv -- "$tmp/public.pem" "$pub"; then
    rm -rf -- "$tmp"
    echo "owner-rules: could not create the local proof key pair" >&2
    exit 1
  fi
  rm -rf -- "$tmp"
  echo "owner-rules: created the local proof key pair in $key_home/config"
  exit 0
fi
if [ "$mode" = sign ]; then
  [ "$#" -eq 3 ] || { echo "usage: jg-owner-rules-gate.sh sign <task-id> <head> <pr-url|->" >&2; exit 2; }
else
  [ "$#" -eq 4 ] || { echo "usage: jg-owner-rules-gate.sh <task-id> <worktree|-> <head|-> <pr-url|->" >&2; exit 2; }
fi
if [ "$mode" = sign ]; then id=$1; head=$2; pr=$3
else id=$1; head=$3; pr=$4
fi
[[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $head =~ ^[a-f0-9]{40,64}$ ]] || { echo "owner-rules: invalid task id or commit head" >&2; exit 1; }
case $pr in *$'\n'*|*$'\r'*|*$'\t'*) echo "owner-rules: invalid proof scope" >&2; exit 1 ;; esac
mc=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../merge-card" && pwd -P)/merge-card
script=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/jg-owner-rules-gate.sh
proof_dir=$JG_HOME/data/$id/proof-authorizations
signature=$proof_dir/$head.sig
proof_receipt() { "$mc" receipt-json "$id" "$head"; }
proof_payload() {
  local receipt=$1 hash
  hash=$(printf '%s' "$receipt" | openssl dgst -sha256 | awk '{print $NF}') || return 1
  printf 'juggernaut-owner-proof-v1\ntask=%s\nhead=%s\npr=%s\nreceipt-sha256=%s\n' "$id" "$head" "$pr" "$hash"
}
if [ "$mode" = sign ]; then
  [ -f "$private" ] && [ ! -L "$private" ] || { echo "owner-rules: local private key is missing; configure $private with the matching public key at $pub" >&2; exit 1; }
  chmod go-rwx "$private" || { echo "owner-rules: cannot secure local private key permissions" >&2; exit 1; }
  receipt=$(proof_receipt) || { echo "owner-rules: no sealed clean receipt to sign for $head" >&2; exit 1; }
  [ -n "$receipt" ] || { echo "owner-rules: no sealed clean receipt to sign for $head" >&2; exit 1; }
  mkdir -p "$proof_dir" || { echo "owner-rules: cannot create local proof record" >&2; exit 1; }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/owner-proof.XXXXXX") || exit 1
  proof_payload "$receipt" > "$tmp/payload" || { rm -rf -- "$tmp"; exit 1; }
  out=$(mktemp "$proof_dir/.signature.XXXXXX") || { rm -rf -- "$tmp"; exit 1; }
  if ! openssl pkeyutl -sign -rawin -inkey "$private" -in "$tmp/payload" -out "$out" 2>/dev/null; then
    rm -f -- "$out"; rm -rf -- "$tmp"; echo "owner-rules: local signing failed" >&2; exit 1
  fi
  chmod 600 "$out" && mv -f -- "$out" "$signature" || { rm -f -- "$out"; rm -rf -- "$tmp"; exit 1; }
  rm -rf -- "$tmp"
  echo "owner-rules: signed the local receipt for $head"
  exit 0
fi
what=$pr; [ "$pr" != - ] || what="local merge $head"
none=0
"$mc" screen-none "$1" "$4" && none=1
# The top line: a screen-free merge is on the text-only card path, and no capture is asked for.
[ "$none" -eq 0 ] || echo "owner-rules: $what declares screen: none, so it takes the text-only Evidence card path; no capture is needed"
# canary_enforced: 0 when this home is in the canary rollout (or no canary file exists) and no active UTC waiver
# covers it. The screen-free receipt refusal honors it; the other refusals are not canary-gated.
canary_enforced() {
  local canary=$JG_HOME/config/owner-rules-canary waiver=$JG_HOME/config/owner-rules-canary-waiver expires
  [ ! -r "$canary" ] || grep -Fqx -- "$JG_HOME" "$canary" || return 1
  if [ -r "$waiver" ]; then
    IFS= read -r expires < "$waiver"
    if [[ $expires =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z$ ]] && [[ $(date -u +%Y-%m-%dT%H:%MZ) < $expires ]]; then return 1; fi
  fi
  return 0
}
# The receipt is a sealed clean done-done run at the merge head; a screen-free merge needs it for its text card too.
if [ "$3" != - ] && ! "$mc" receipt "$1" "$3"; then
  # A screen-free merge keeps today's skip on a home the canary has not reached yet.
  if [ "$none" -eq 0 ] || canary_enforced; then
    if [ "$2" = - ]; then
      echo "owner-rules: no passed-proof receipt for $what: seal a clean done-done run at $3 with: done-done run -- <the command that proves it> in the copy at $3"
    else
      echo "owner-rules: no passed-proof receipt for $what: seal a clean done-done run at $3 with: cd '$2' && done-done run -- <the command that proves it>"
    fi
    exit 1
  fi
fi
# The signature is local authorization for this exact task, PR scope, head, and receipt contents.
receipt=$(proof_receipt) || receipt=''
if [ -z "$receipt" ] || [ ! -f "$pub" ] || [ -L "$pub" ] || [ ! -f "$signature" ] || [ -L "$signature" ]; then
  echo "owner-rules: no valid local proof signature for $what at $head; sign only after the passed-proof recipe succeeds: JG_HOME=$JG_HOME $script sign $id $head $pr"
  exit 1
fi
payload=$(mktemp "${TMPDIR:-/tmp}/owner-proof-payload.XXXXXX") || exit 1
proof_payload "$receipt" > "$payload" || { rm -f -- "$payload"; exit 1; }
if ! openssl pkeyutl -verify -rawin -pubin -inkey "$pub" -in "$payload" -sigfile "$signature" >/dev/null 2>&1; then
  rm -f -- "$payload"
  echo "owner-rules: local proof signature is invalid for $what at $head; re-run the passed-proof recipe and sign the exact receipt"
  exit 1
fi
rm -f -- "$payload"
# Lint: the newest checks-gate row for this PR url at this head, from checks-lint (read, never rerun), must be a
# `pass`: a later fail takes the verdict back, and a `card` row is not a verdict. A local merge's rows
# name the report file and carry head `-`, so they match on the task's own folder instead.
awk -F'\t' -v pr="$4" -v head="$3" -v task="$1" '
  $4 == "card" { next }
  pr != "-" { if ($2 == pr && $3 == head) f = ($4 == "pass"); next }
  $3 == head || ($3 == "-" && $2 !~ /^https?:/ && $2 ~ ("/" task "/[^/]*$")) { f = ($4 == "pass") }
  END { exit !f }' "$JG_HOME/data/checks-gate.log" 2>/dev/null || {
  src=$4; [ "$4" != - ] || src="<report file>"
  lint=${JG_CHECKS_LINT:-${XDG_DATA_HOME:-$HOME/.local/share}/jg-merge-on-green/checks-lint.sh}
  [ -x "$lint" ] || lint=${JG_MAIN_HOME:-$HOME/juggernaut}/config/jg-checks-lint.sh
  echo "owner-rules: no checks-lint PASS for $src at $3; run JG_HOME=$JG_HOME $lint $src $JG_HOME/data/$1 then merge again"
  exit 1
}
# Local merges retain the existing receipt/lint behavior; only PRs have board keys.
[ "$4" != - ] || exit 0
# Canary config lists exact JG_HOME paths; without it every home keeps today's gate behavior.
canary_enforced || exit 0
board=${JG_FLEET_BOARD:-}
if [ -z "$board" ] && [ -r "$JG_HOME/config/fleet-board" ]; then
  IFS= read -r board < "$JG_HOME/config/fleet-board"
fi
main_home=${JG_MAIN_HOME:-$HOME/juggernaut}
if [ -z "$board" ] && [ -r "$main_home/config/fleet-board" ]; then
  IFS= read -r board < "$main_home/config/fleet-board"
fi
if [ -z "$board" ]; then
  echo "owner-rules: fleet board is not configured for $what (set JG_FLEET_BOARD, or write its path with: echo <board.json> > $JG_HOME/config/fleet-board; the main home's $main_home/config/fleet-board is the fallback)"
  exit 1
fi
if [ ! -r "$board" ] || ! jq -e '.items | type == "array"' "$board" >/dev/null 2>&1; then
  echo "owner-rules: cannot read fleet board $board for $what: set JG_FLEET_BOARD or $JG_HOME/config/fleet-board to a board.json holding {\"items\": [...]}"
  exit 1
fi
key=merge-$(printf '%s' "${4#*://}" | sed 's|^[^/]*/||' | tr -c 'A-Za-z0-9._-' -)
key=${key:0:128}
if jq -e --arg k "$key" --arg h "$3" 'any(.items[]?; (.key == $k or (.key | startswith($k + "-"))) and .kind == "evidence" and ((.run.commit? // .evidence.commit?) == $h) and ((.run.commit? == null) or .run.commit == $h) and ((.evidence.commit? == null) or .evidence.commit == $h))' "$board" >/dev/null; then
  exit 0
fi
if [ "$none" -eq 1 ] && "$mc" receipt "$1" "$3"; then
  timeout 15 "$mc" post --board "$board" "$1" "$2" "$3" "$4" || {
    rc=$?
    echo "owner-rules: could not post the text-only Evidence card for $what (merge-card exit $rc); its own line above names the step it needs"
    exit 1
  }
  jq -e --arg k "$key" --arg h "$3" 'any(.items[]?; (.key == $k or (.key | startswith($k + "-"))) and .kind == "evidence" and ((.run.commit? // .evidence.commit?) == $h) and ((.run.commit? == null) or .run.commit == $h) and ((.evidence.commit? == null) or .evidence.commit == $h))' "$board" >/dev/null && exit 0
fi
echo "owner-rules: no passed-proof Evidence card for $what; post it with: JG_HOME=$JG_HOME $mc post --board $board $1 $2 $3 $4"
exit 1

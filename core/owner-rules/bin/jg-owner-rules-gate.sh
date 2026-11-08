#!/usr/bin/env bash
# jg-owner-rules-gate.sh <task-id> <worktree|-> <head|-> <pr-url|-> - local proof authorization and merge gate.
# Run `init-key` once in the captain's home, then use `sign <task-id> <head> <pr-url|->` only after the passed-proof recipe succeeds.
# `diagnose <task-id> <worktree|-> <head> <pr-url|->` changes nothing and refuses nothing: it prints the facts the gate judges
# (`receipt=`, `signature=`, `lint=`, `screen_none=`), or `owner-rules=off` in a home that has not enabled the gate, so a
# missing input can be read from the gate's own evaluation. A local-trunk landing (bin/jg-trunk.sh) does not run this gate.
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
case ${1:-} in sign|init-key|diagnose) mode=$1; shift ;; esac
if [ -z "${JG_HOME:-}" ] || [ ! -e "$JG_HOME/config/owner-rules" ]; then
  [ "$mode" = gate ] && exit 0
  [ "$mode" != diagnose ] || { echo "owner-rules=off"; exit 0; }
  echo "owner-rules: config/owner-rules is not enabled" >&2
  exit 1
fi
command -v openssl >/dev/null 2>&1 || { echo "owner-rules: OpenSSL is required for local proof signatures" >&2; exit 1; }
# Main's home holds the key pair. An explicit JG_MAIN_HOME wins; otherwise a lead home follows the parent binding it
# already carries (.jg-squad-lead-parent) up to the home with none, so no merge in a lead home needs a hand export.
# A binding that cannot be followed stops with the exact fix instead of reading a key the lead home never had.
# The merge gate and sign follow it, so a lead home signs with Main's key in place (never copied) and keeps the signature in its own data;
# init-key still creates a pair only in the home it runs in.
if [ -z "${JG_MAIN_HOME:-}" ] && [ "$mode" != init-key ]; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../bin" && pwd -P)/jg-squad-lead-parent-lib.sh"
  JG_MAIN_HOME=$JG_HOME hops=0
  while [ -e "$JG_MAIN_HOME/.jg-squad-lead-parent" ]; do
    if [ "$hops" -ge 8 ] || ! jg_squad_lead_parent_record_parse "$JG_MAIN_HOME/.jg-squad-lead-parent" || [ -z "$JG_SQUAD_LEAD_PARENT_HOME" ] || [ ! -d "$JG_SQUAD_LEAD_PARENT_HOME" ]; then
      echo "owner-rules: cannot find Main's home from $JG_MAIN_HOME/.jg-squad-lead-parent (it is corrupt, remote, or names a missing home); fix: export JG_MAIN_HOME=<absolute path of Main's home> and run the merge again" >&2
      exit 1
    fi
    JG_MAIN_HOME=$JG_SQUAD_LEAD_PARENT_HOME hops=$((hops + 1))
  done
fi
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
# The order of refusals is policy/gate/owner_proof.rego (the checks-lint rule is policy/gate/lint_row.rego): this
# gathers the facts, asks the one evaluator, and prints the message for the reason it gives. An evaluator that
# cannot run refuses like a missing proof does.
guard_host=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)/bin/jg-guard-host.sh
none=false
"$mc" screen-none "$1" "$4" && none=true
# The top line: a screen-free merge is on the text-only card path, and no capture is asked for.
[ "$none" = false ] || [ "$mode" = diagnose ] || echo "owner-rules: $what declares screen: none, so it takes the text-only Evidence card path; no capture is needed"
receipt_ok=false
"$mc" receipt "$1" "$3" && receipt_ok=true
# The signature is local authorization for this exact task, PR scope, head, and receipt contents.
sig=missing
receipt=$(proof_receipt) || receipt=''
if [ -n "$receipt" ] && [ -f "$pub" ] && [ ! -L "$pub" ] && [ -f "$signature" ] && [ ! -L "$signature" ]; then
  payload=$(mktemp "${TMPDIR:-/tmp}/owner-proof-payload.XXXXXX") || exit 1
  proof_payload "$receipt" > "$payload" || { rm -f -- "$payload"; exit 1; }
  sig=invalid
  ! openssl pkeyutl -verify -rawin -pubin -inkey "$pub" -in "$payload" -sigfile "$signature" >/dev/null 2>&1 || sig=valid
  rm -f -- "$payload"
fi
# Lint: the newest checks-gate row for this PR url at this head, from checks-lint (read, never rerun). A local
# merge's rows name the report file and carry head `-`, so they match on the task's own folder instead.
lint_log=$JG_HOME/data/checks-gate.log
[ -r "$lint_log" ] || lint_log=/dev/null
src=$4; [ "$4" != - ] || src=$JG_HOME/data/$1/checks.md
lint=error
if lint_verdict=$(jq -Rn --arg pr "$4" --arg head "$3" --arg task "$1" \
  '{pr: $pr, head: $head, task: $task, rows: [inputs | split("\t") | select(length >= 4) | {src: .[1], head: .[2], verdict: .[3]}]}' \
  "$lint_log" | "$guard_host" eval gate.lint_row 2>&1); then
  lint=fail
  [ "$(jq -r '.ok' <<<"$lint_verdict" 2>/dev/null)" != true ] || lint=pass
fi
if [ "$mode" = diagnose ]; then
  printf 'receipt=%s\nsignature=%s\nlint=%s\nscreen_none=%s\n' "$receipt_ok" "$sig" "$lint" "$none"
  exit 0
fi
# Canary config lists exact JG_HOME paths; without it every home keeps today's gate behavior.
canary=$JG_HOME/config/owner-rules-canary waiver=''
canary_readable=false canary_listed=false
if [ -r "$canary" ]; then canary_readable=true; ! grep -Fqx -- "$JG_HOME" "$canary" || canary_listed=true; fi
[ ! -r "$JG_HOME/config/owner-rules-canary-waiver" ] || IFS= read -r waiver < "$JG_HOME/config/owner-rules-canary-waiver"
# Only PRs have board keys: where the fleet board is, whether it holds an items list, and the card's key.
# The board is read by file, never through argv: a real board is hundreds of KB and one argument is capped near 128 KB.
board=${JG_FLEET_BOARD:-} board_state=ok board_file=/dev/null
main_home=${JG_MAIN_HOME:-$JG_HOME}
if [ -z "$board" ] && [ -r "$JG_HOME/config/fleet-board" ]; then IFS= read -r board < "$JG_HOME/config/fleet-board"; fi
if [ -z "$board" ] && [ -r "$main_home/config/fleet-board" ]; then IFS= read -r board < "$main_home/config/fleet-board"; fi
read_board() {
  board_state=ok board_file=/dev/null
  if [ -z "$board" ]; then board_state="unset"
  elif [ ! -r "$board" ] || ! jq -e '.items | type == "array"' "$board" >/dev/null 2>&1; then board_state=unreadable
  else board_file=$board; fi
}
key=merge-$(printf '%s' "${4#*://}" | sed 's|^[^/]*/||' | tr -c 'A-Za-z0-9._-' -)
key=${key:0:128}
decide() { # <posted: true|false>: the policy's answer for the facts above; the evaluator's own stderr is left on stderr
  local input
  input=$(jq -nc --arg pr "$pr" --arg head "$head" --argjson none "$none" --argjson receipt_ok "$receipt_ok" --arg sig "$sig" --arg lint "$lint" \
    --argjson readable "$canary_readable" --argjson listed "$canary_listed" --arg waiver "$waiver" --arg now "$(date -u +%Y-%m-%dT%H:%MZ)" \
    --arg board "$board_state" --slurpfile board_doc "$board_file" --arg key "$key" --argjson posted "$1" \
    '{pr: $pr, head: $head, none: $none, receipt_ok: $receipt_ok, signature: $sig, lint: $lint, canary: {readable: $readable, listed: $listed},
      waiver: $waiver, now: $now, board: $board, items: ($board_doc[0].items // []), key: $key, posted: $posted}') || return 1
  printf '%s' "$input" | "$guard_host" eval gate.owner_proof
}
read_board
posted=false
errs=$(mktemp "${TMPDIR:-/tmp}/owner-gate-err.XXXXXX") || exit 1
trap 'rm -f -- "$errs"' EXIT
while :; do
  # The verdict is stdout only. A failure or a non-JSON answer refuses with the real reason from stderr, never as a missing card.
  if ! verdict=$(decide $posted 2>"$errs") || ! jq -e 'type == "object"' <<<"$verdict" >/dev/null 2>&1; then
    reason=$(head -c 2000 "$errs")
    echo "owner-rules: cannot evaluate the merge gate for $what at $3: ${reason:-${verdict:-no answer}}"
    exit 1
  fi
  [ "$(jq -r '.ok' <<<"$verdict")" != true ] || exit 0
  case $(jq -r '.why' <<<"$verdict") in
    no_receipt)
      if [ "$2" = - ]; then
        echo "owner-rules: no passed-proof receipt for $what: seal a clean done-done run at $3 with: done-done run -- <the command that proves it> in the copy at $3"
      else
        echo "owner-rules: no passed-proof receipt for $what: seal a clean done-done run at $3 with: cd '$2' && done-done run -- <the command that proves it>"
      fi ;;
    no_signature) echo "owner-rules: no valid local proof signature for $what at $head; sign only after the passed-proof recipe succeeds: JG_HOME=$JG_HOME $script sign $id $head $pr" ;;
    bad_signature) echo "owner-rules: local proof signature is invalid for $what at $head; re-run the passed-proof recipe and sign the exact receipt" ;;
    lint_error) echo "owner-rules: cannot evaluate the checks-lint rule for $src at $3: ${lint_verdict:-no answer}" ;;
    no_lint)
      lint=${JG_CHECKS_LINT:-${XDG_DATA_HOME:-$HOME/.local/share}/jg-merge-on-green/checks-lint.sh}
      [ -x "$lint" ] || lint=${JG_MAIN_HOME:-$HOME/juggernaut}/config/jg-checks-lint.sh
      echo "owner-rules: no checks-lint PASS for $src at $3; run JG_HOME=$JG_HOME $lint $src $JG_HOME/data/$1 then merge again" ;;
    no_board_config) echo "owner-rules: fleet board is not configured for $what (set JG_FLEET_BOARD, or write its path with: echo <board.json> > $JG_HOME/config/fleet-board; the main home's $main_home/config/fleet-board is the fallback)" ;;
    bad_board) echo "owner-rules: cannot read fleet board $board for $what: set JG_FLEET_BOARD or $JG_HOME/config/fleet-board to a board.json holding {\"items\": [...]}" ;;
    post_card)
      timeout 15 "$mc" post --board "$board" "$1" "$2" "$3" "$4" || {
        rc=$?
        echo "owner-rules: could not post the text-only Evidence card for $what (merge-card exit $rc); its own line above names the step it needs"
        exit 1
      }
      posted=true; read_board
      continue ;;
    *) echo "owner-rules: no passed-proof Evidence card for $what; post it with: JG_HOME=$JG_HOME $mc post --board $board $1 $2 $3 $4" ;;
  esac
  exit 1
done

#!/usr/bin/env bash
# jg-owner-rules-gate.sh <task-id> <worktree|-> <head|-> <pr-url|-> - the owner proof signature tool; the merge gate step passes.
# Run `init-key` once in the captain's home, then use `sign <task-id> <head> <pr-url|->` after the passed-proof recipe succeeds.
# The merge-gate form (four arguments) refuses nothing: no signature, checks-lint row, receipt or Evidence card is a condition of a
# merge any more (pcp-s7). An older home's config/merge-gate still calls it, so it stays and exits 0. The owner's real
# boundaries stay with their owners: an open decision (bin/jg-captain-hold.sh blocking), owner-guard (credentials and owner details)
# and the merge authority of bin/jg-pr-merge.sh. A local-trunk landing never ran this gate, and records the signature after landing.
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
# The merge-gate form judges nothing, so it never reads a key, a binding or a tool: it passes at once.
[ "$mode" != gate ] || exit 0
if [ -z "${JG_HOME:-}" ] || [ ! -e "$JG_HOME/config/owner-rules" ]; then
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
[ "$#" -eq 3 ] || { echo "usage: jg-owner-rules-gate.sh sign <task-id> <head> <pr-url|->" >&2; exit 2; }
id=$1; head=$2; pr=$3
[[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $head =~ ^[a-f0-9]{40,64}$ ]] || { echo "owner-rules: invalid task id or commit head" >&2; exit 1; }
case $pr in *$'\n'*|*$'\r'*|*$'\t'*) echo "owner-rules: invalid proof scope" >&2; exit 1 ;; esac
mc=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../merge-card" && pwd -P)/merge-card
proof_dir=$JG_HOME/data/$id/proof-authorizations
signature=$proof_dir/$head.sig
proof_receipt() { "$mc" receipt-json "$id" "$head"; }
proof_payload() {
  local receipt=$1 hash
  hash=$(printf '%s' "$receipt" | openssl dgst -sha256 | awk '{print $NF}') || return 1
  printf 'juggernaut-owner-proof-v1\ntask=%s\nhead=%s\npr=%s\nreceipt-sha256=%s\n' "$id" "$head" "$pr" "$hash"
}
[ -f "$private" ] && [ ! -L "$private" ] || { echo "ENV: owner-rules: local private key is missing; configure $private with the matching public key at $pub" >&2; exit 1; }
chmod go-rwx "$private" || { echo "ENV: owner-rules: cannot secure local private key permissions" >&2; exit 1; }
receipt=$(proof_receipt) || { echo "owner-rules: no sealed clean receipt to sign for $head" >&2; exit 1; }
[ -n "$receipt" ] || { echo "owner-rules: no sealed clean receipt to sign for $head" >&2; exit 1; }
mkdir -p "$proof_dir" || { echo "owner-rules: cannot create local proof record" >&2; exit 1; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/owner-proof.XXXXXX") || exit 1
proof_payload "$receipt" > "$tmp/payload" || { rm -rf -- "$tmp"; exit 1; }
out=$(mktemp "$proof_dir/.signature.XXXXXX") || { rm -rf -- "$tmp"; exit 1; }
if ! openssl pkeyutl -sign -rawin -inkey "$private" -in "$tmp/payload" -out "$out" 2>/dev/null; then
  rm -f -- "$out"; rm -rf -- "$tmp"; echo "ENV: owner-rules: local signing failed" >&2; exit 1
fi
chmod 600 "$out" && mv -f -- "$out" "$signature" || { rm -f -- "$out"; rm -rf -- "$tmp"; exit 1; }
rm -rf -- "$tmp"
echo "owner-rules: signed the local receipt for $head"
exit 0

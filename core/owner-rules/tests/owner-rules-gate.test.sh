#!/usr/bin/env bash
# owner-rules merge-gate e2e: the config/merge-gate that wiring.sh writes, run with the args jg-pr-merge.sh passes.
# The generic proof compliance is gone (pcp-s7): with no receipt, no sealed run, no signature, no checks-lint row, no
# Evidence card and no fleet board, the owner step passes and the home's own previous gate still decides. Signing stays.
# Usage: owner-rules/tests/owner-rules-gate.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
addons=$(cd "$here/../.." && pwd) || exit 1
work=$(mktemp -d "${TMPDIR:-/tmp}/owner-rules-gate.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
export HOME=$work/user XDG_DATA_HOME=$work/data
fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }

home=$work/home; mkdir -p "$home/config" "$home/data/lane"
pr=https://github.com/umeranjum17/juggernaut/pull/9 head=$(printf 'a%.0s' {1..40})
# The home's previous gate records that it ran; a file beside it makes it refuse.
printf '#!/bin/sh\n[ ! -e "%s/refuse" ] || { echo "prev gate refused: credential in the change"; exit 1; }\necho "prev gate ran: $*"\n' "$work" > "$home/config/merge-gate"
chmod +x "$home/config/merge-gate"
gate() { JG_HOME=$home "$home/config/merge-gate" lane - "$head" "$pr" 2>&1; printf 'rc=%s\n' "$?"; }

"$addons/owner-rules/wiring.sh" "$home" >/dev/null || no "wiring.sh failed"
is "installed: the home previous gate is kept at config/merge-gate.pre-chain" "$([ -x "$home/config/merge-gate.pre-chain" ] && echo yes)" yes
"$addons/owner-rules/wiring.sh" "$home" >/dev/null && ok "install is idempotent" || no "second install failed"

is "pass: no receipt, signature, lint row, card or board is a condition" "$(gate)" "prev gate ran: lane - $head $pr
rc=0"
printf 'schema=jg-squad-lead-parent.v1\nroute=remote\n' > "$home/.jg-squad-lead-parent"
is "pass: an unusable parent binding no longer stops a merge" "$(gate | tail -1)" "rc=0"
rm -f "$home/.jg-squad-lead-parent"
touch "$work/refuse"
is "refusal: the chained previous gate (credential check) still decides" "$(gate)" "prev gate refused: credential in the change
rc=1"
rm -f "$work/refuse"

# Signing is the owner's own act and stays: it needs the key pair and a sealed receipt.
signer=$addons/owner-rules/bin/jg-owner-rules-gate.sh
out=$(JG_HOME=$home "$signer" sign lane "$head" "$pr" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "sign: refuses without a key pair ($out)" || no "sign passed with no key pair"
JG_HOME=$home "$signer" init-key >/dev/null && [ -f "$home/config/owner-rules-proof.pub" ] && ok "init-key creates the key pair" || no "init-key"
out=$(JG_HOME=$home "$signer" sign lane "$head" "$pr" 2>&1); rc=$?
[ "$rc" -ne 0 ] && [[ $out == *"no sealed clean receipt"* ]] && ok "sign: refuses with no sealed receipt" || no "sign without a receipt: rc=$rc $out"

"$addons/owner-rules/unwiring.sh" "$home" >/dev/null
is "uninstalled: only the previous gate runs" "$(gate)" "prev gate ran: lane - $head $pr
rc=0"

[ "$fails" -eq 0 ] && echo "PASS owner-rules-gate" || { echo "FAIL owner-rules-gate: $fails"; exit 1; }

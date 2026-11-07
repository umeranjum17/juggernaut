#!/usr/bin/env bash
# E2E: a lane that lands several pull requests keeps one receipt slot, and the merge path puts back the receipt
# published for the head being merged, with nobody republishing by hand. Real publisher, real acceptance (the
# policy evaluator), real commits. Accepted: each member's own head. Refused: a head never published, a head whose
# newest receipt is FAIL, and a restore that would cross tasks.
# Usage: core/receipts/tests/receipt-lane-restore.test.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$here/../../.." && pwd -P)
TOOL=$ROOT/core/receipts/bin/jg-run-receipt.sh
d=$(mktemp -d "${TMPDIR:-/tmp}/lane-restore.XXXXXX") || exit 1
trap 'rm -rf -- "$d"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
is() { [ "$2" = "$3" ] || fail "$1: want [$3], got [$2]"; }
export HOME=$d/home TMPDIR=$d GIT_CONFIG_GLOBAL=/dev/null JG_HOME=$d/jg JG_CORE_DIR=$ROOT/core JG_FORK_BIN=$ROOT/bin
mkdir -p "$HOME" "$JG_HOME/state" "$JG_HOME/data" "$d/c"
S=$JG_HOME/state
printf 'id=lane\nmode=direct-PR\nspawn_gen=g1\nreceipt_required=1\nworktree=%s\n' "$d/c" >"$S/lane.meta"
printf 'id=other\nmode=direct-PR\nspawn_gen=g1\nreceipt_required=1\n' >"$S/other.meta"
printf 'commands, results and limitations\n' >"$d/ev.txt"
g() { git -c user.email=t@example.com -c user.name=t -C "$d/c" "$@"; }
git -C "$d/c" init -q .
publish() { # publish <PASS|FAIL> <pr number>: the real publisher at the checkout's HEAD
  JG_RECEIPT_PR=https://github.com/o/r/pull/$2 "$TOOL" lane "$1" "$d/ev.txt" "$d/c" >/dev/null 2>&1 || fail "publish $1 $2 refused"
}
g commit -q --allow-empty -m one; h1=$(g rev-parse HEAD); publish PASS 1
g commit -q --allow-empty -m two; h2=$(g rev-parse HEAD); publish PASS 2
g commit -q --allow-empty -m three; h3=$(g rev-parse HEAD)
# shellcheck disable=SC1091  # $ROOT resolves at run time
. "$ROOT/bin/jg-dod-lib.sh"
# shellcheck disable=SC1091
. "$ROOT/core/receipts/bin/jg-receipts-lib.sh"
slot_head() { jq -r .head "$S/lane.run-receipt.json"; }
accept() { jg_dod_receipt_accept "$S" lane "$S/lane.meta" "$1" "$2" >/dev/null 2>&1; }

is 'the slot holds the newest member' "$(slot_head)" "$h2"
[ -f "$S/lane.run-receipt.$h1.json" ] || fail 'the publisher kept no receipt for the first head'
accept "$h2" https://github.com/o/r/pull/2 || fail 'the newest member is accepted'
accept "$h1" https://github.com/o/r/pull/1 || fail 'the first member is accepted with no hand republish'
is 'acceptance put the first member receipt in the slot' "$(slot_head)" "$h1"
accept "$h2" https://github.com/o/r/pull/2 || fail 'the second member is accepted again'
is 'and back again' "$(slot_head)" "$h2"
accept "$h1" https://github.com/o/r/pull/2 && fail 'a receipt naming another pull request must be refused'
is 'a refused head leaves the restored receipt in the slot' "$(slot_head)" "$h1"
accept "$h3" https://github.com/o/r/pull/3 && fail 'a head never published must be refused'
# The first member's newest receipt is a FAIL: restoring it refuses the merge.
g checkout -q "$h1" 2>/dev/null; publish FAIL 1; g checkout -q - 2>/dev/null
accept "$h1" https://github.com/o/r/pull/1 && fail 'a newest FAIL receipt must refuse the merge'
# Another task never borrows this lane's receipt.
"$ROOT/core/receipts/bin/jg-receipt-restore.sh" "$S" other "$h2" >/dev/null
[ ! -e "$S/other.run-receipt.json" ] || fail 'a restore must not cross tasks'
# An archived file that names another head is not restored.
cp "$S/lane.run-receipt.$h2.json" "$S/lane.run-receipt.$h3.json"
is 'a mislabelled archive file restores nothing' "$("$ROOT/core/receipts/bin/jg-receipt-restore.sh" "$S" lane "$h3")" ''
echo "ok - lane receipts: each member lands with its own head's receipt; unpublished, FAIL, foreign and mislabelled are refused"

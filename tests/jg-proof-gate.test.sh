#!/usr/bin/env bash
# jg_dod_proof_gate (bin/jg-merge-gate-lib.sh): a merge lands only with its proof card on the board.
# The gate runs the real bin/jg-proof-attach.sh; only the board client is a stub.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
T=$(jg_test_tmproot proof-gate)
mkdir -p "$T/bin" "$T/home/config" "$T/home/data/t1" "$T/home/state"
# shellcheck disable=SC2016 # the stub script is meant to read its own arguments
printf '#!/usr/bin/env bash\ncase "$1" in list) echo "{\\"decisions\\":[]}" ;; post) exit 0 ;; esac\n' > "$T/bin/sign-off-axi"
chmod +x "$T/bin/sign-off-axi"
H=$T/home
run_gate() {  # <home> [PATH]: the gate's verdict and output
  local out rc=0
  out=$(PATH="${2:-$T/bin:$PATH}" bash -c '. "$1/bin/jg-merge-gate-lib.sh"; jg_dod_proof_gate "$2" t1 deadbeef -' _ "$ROOT" "$1" 2>&1) || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}

out=$(run_gate "$H")
assert_contains "$out" "rc=0" "a home with no board is not gated"

printf '#!/bin/sh\nexec x post --board %s "$@"\n' "$T/board.json" > "$H/config/post-merge"
out=$(run_gate "$H")
assert_contains "$out" "rc=1" "a board with no proof media refuses the merge"
assert_contains "$out" "merge refused" "the refusal says the merge is refused"
assert_contains "$out" "no proof media" "the refusal names the missing proof"

: > "$H/data/t1/shot.png"
echo '{"decisions":[]}' > "$T/board.json"
out=$(run_gate "$H")
assert_contains "$out" "rc=0" "proof media and a working board let the merge land"
assert_contains "$out" "posted" "the gate posts the proof card itself"

# A board client that cannot be found refuses; it never skips.
mkdir -p "$T/empty"
out=$(run_gate "$H" "$T/empty:/usr/bin:/bin")
assert_contains "$out" "rc=1" "no board client refuses the merge"

# A Squad Lead with no board of its own is gated on its parent's.
L=$T/lead; mkdir -p "$L/config" "$L/state" "$L/data/t1"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$H" > "$L/.jg-squad-lead-parent"
printf 'lead-c' > "$L/.jg-squad-lead-home"
out=$(run_gate "$L")
assert_contains "$out" "rc=1" "a lead without proof is refused on its parent's board"
pass "proof gate"

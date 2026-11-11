#!/usr/bin/env bash
# Behavior tests for bin/jg-machine-guard.sh: the per-machine flip from shadow to refusal (SM12).
# The fixture machine and the shadow log are generated here; no fleet record is copied.
# Off by default: an illegal edge is logged and allowed. Listed in config/machine-enforce: the same edge is refused.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

G="$ROOT/bin/jg-machine-guard.sh"
T=$(jg_test_tmproot jg-machine-enforce); mkdir -p "$T/tables" "$T/home/config" "$T/home/data"
export JG_MACHINES_TABLES="$T/tables" JG_HOME="$T/home"
unset JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE
LOG="$T/home/data/machine-shadow.log" CONF="$T/home/config/machine-enforce"
tab() { local IFS=$'\t'; printf '%s\n' "$*"; }
guard() { OUT=$(bash "$G" "$@" 2>&1); RC=$?; }
violations() { grep -c "	$1	" "$LOG" 2>/dev/null || true; }

seed_table() {  # <name>: a three-state document machine, one legal path draft -> review -> published
  { tab machine "$1" "files" tests/jg-machine-enforce.test.sh
    tab state draft initial "A draft is being written." -
    tab state review normal "The draft waits for a reviewer." -
    tab state published terminal "The draft is published." -
    tab edge draft submit review author:submit - "the author finishes" t-submit
    tab edge review approve published reviewer:approve - "a reviewer agrees" t-approve
    tab observer "echo draft"; } > "$T/tables/$1.tsv"
}
seed_table doc; seed_table other
tab doc legacy > "$T/tables/known-baseline.tsv"                 # today's accepted state
tab doc review reset review >> "$T/tables/known-baseline.tsv"  # today's accepted move

# Shadow (the default): a legal edge is silent, an illegal edge is logged and allowed.
guard edge doc draft review; expect_code 0 "$RC" "a legal edge"; assert_equals "" "$OUT" "a legal edge is silent"
assert_absent "$LOG" "a legal edge writes no shadow line"
guard edge doc draft published; expect_code 0 "$RC" "shadow allows an illegal edge"
assert_equals 1 "$(violations doc)" "shadow logs the illegal edge once"
assert_contains "$(cat "$LOG")" "doc	draft	published	shadow" "the shadow line names machine, edge and mode"
pass "off by default: an illegal edge is logged and allowed"

# The baseline keeps today's states and edges legal, even when enforced.
tab doc > "$CONF"
guard edge doc draft legacy; expect_code 0 "$RC" "a baseline edge"
guard edge doc legacy review; expect_code 0 "$RC" "an edge from a baseline state"
guard edge doc review review; expect_code 0 "$RC" "a baseline move"
assert_equals 1 "$(violations doc)" "baseline edges add no violation"
pass "the baseline keeps today's states legal"

# Per-edge refusal: every illegal edge is refused naming the machine and edge; a legal one still passes.
guard edge doc review draft; expect_code 1 "$RC" "enforced: review -> draft"
assert_contains "$OUT" "refused doc: review -> draft" "the refusal names machine and edge"
guard edge doc published review; expect_code 1 "$RC" "enforced: leaving a terminal state"
guard edge doc draft nowhere; expect_code 1 "$RC" "enforced: a state the table lacks"
guard edge doc review published; expect_code 0 "$RC" "enforced: a legal edge still passes"
assert_contains "$(cat "$LOG")" "doc	review	draft	refused" "the refusal is logged as refused"
pass "an enforced machine refuses each illegal edge and passes each legal one"

# Per machine: a machine not listed stays in shadow.
guard edge other draft published; expect_code 0 "$RC" "an unlisted machine"
assert_contains "$(cat "$LOG")" "other	draft	published	shadow" "the unlisted machine logs in shadow"
pass "enforcement is per machine"

# Rollback: delete the config line, and the same edge is allowed again.
: > "$CONF"; guard edge doc review draft; expect_code 0 "$RC" "after the line is deleted"
pass "rollback is deleting the config line"

# A broken table never fails the writer: the guard steps aside and logs the error.
rm "$T/tables/other.tsv"; tab other > "$CONF"
guard edge other draft review; expect_code 0 "$RC" "no table"; assert_contains "$(cat "$LOG")" "other	draft	review	error" "the error is logged"
guard edge doc; expect_code 2 "$RC" "usage"
pass "a guard failure never fails the writer"

# Flip: refused while the shadow log has a recent violation for the machine, allowed once it is quiet.
: > "$CONF"
guard flip doc 3600; expect_code 1 "$RC" "a recent violation blocks the flip"; assert_contains "$OUT" "not quiet" "the refusal says why"
assert_equals "" "$(cat "$CONF")" "no config line was written"
tab 1 doc draft published shadow > "$LOG"                       # a violation from epoch 1: long quiet
guard flip doc 3600; expect_code 0 "$RC" "a quiet machine flips"
assert_equals doc "$(cat "$CONF")" "the machine is listed"
guard flip doc 3600; expect_code 0 "$RC" "flip twice"; assert_equals 1 "$(grep -c '^doc$' "$CONF")" "flip is idempotent"
guard flip nosuch 3600; expect_code 1 "$RC" "an unknown machine"
guard edge doc draft published; expect_code 1 "$RC" "the flipped machine now refuses"
pass "flip waits for a quiet shadow log"

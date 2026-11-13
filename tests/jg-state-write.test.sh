#!/usr/bin/env bash
# Behavior test for J29b: a state word is written only if its enum has it, and the bare-state lint refuses a new one.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(jg_test_tmproot jg-state-write); H=$T/home; mkdir -p "$H/core/machines" "$H/state" "$H/data" "$H/bin"
cp -r "$ROOT/core/machines/tables" "$ROOT"/core/machines/*.states "$H/core/machines/"
export JG_HOME=$H JG_DATA_OVERRIDE=$H/data JG_MACHINES_TABLES=$H/core/machines/tables
JM=$ROOT/bin/jg-machine.sh

# 1. Writing `landed` as a ticket stage is refused with the legal values, and the stage file is unchanged.
echo building > "$H/state/t1.stage"
OUT=$(bash "$JM" write ticket landed "$H/state/t1.stage" 2>&1); RC=$?
expect_code 1 "$RC" "a value outside the enum is refused"
assert_contains "$OUT" "legal: intake ready building proving delivering released closed" "refusal lists the legal values"
assert_equals building "$(cat "$H/state/t1.stage")" "the stage file is unchanged"
OUT=$(bash "$JM" write ticket nonesuch "$H/state/new.stage" 2>&1); expect_code 1 "$?" "an illegal value to a new file is refused"
[ ! -e "$H/state/new.stage" ] || fail "an illegal write created the file"
bash "$JM" write ticket proving "$H/state/t1.stage" || fail "a legal write failed"
assert_equals proving "$(cat "$H/state/t1.stage")" "a legal value is written"
pass "a state word outside its enum is refused and nothing changes"

# 2. The move command reads its destination through the enum: a table whose move lands outside the enum writes no line.
sed -i 's|^observer	.*|observer	cat "$(dirname "$JG_MACHINES_TABLES")/../../state/$1.stage"|' "$H/core/machines/tables/ticket.tsv"
echo building > "$H/state/t2.stage"
sed -i 's/^\(edge	building	claim-done	\)[^	]*/\1landed/' "$H/core/machines/tables/ticket.tsv"
OUT=$(bash "$ROOT/bin/jg-move.sh" t2 claim-done 2>&1); RC=$?
expect_code 1 "$RC" "a move to a word outside the enum is refused"
[ ! -e "$H/data/moves.log" ] || fail "the refused move wrote the log"
pass "the move command refuses a destination outside the enum"

# 3. The lint prints today's count and fails on a fixture commit that adds a bare state string.
mkdir -p "$H/core/x"; cp "$ROOT/core/machines/bare-states.baseline" "$H/core/machines/"
printf 'ok=1\n' > "$H/bin/a.sh"
OUT=$(bash "$ROOT/bin/jg-state-lint.sh" --root "$H" --check 2>&1); RC=$?
expect_code 0 "$RC" "a clean tree passes at baseline 0"
echo 0 > "$H/core/machines/bare-states.baseline"
assert_contains "$OUT" "bare state strings: 0" "the lint prints the count"
OUT=$(bash "$ROOT/bin/jg-state-lint.sh" --root "$ROOT" 2>&1); expect_code 0 "$?" "report-only exits 0"
assert_contains "$OUT" "bare state strings: $(tr -dc 0-9 < "$ROOT/core/machines/bare-states.baseline")" "today's count matches the baseline"
printf '[ "$stage" = landed ] && echo x\n' >> "$H/bin/a.sh"
OUT=$(bash "$ROOT/bin/jg-state-lint.sh" --root "$H" --check 2>&1); RC=$?
expect_code 1 "$RC" "an added bare state string fails the lint"
assert_contains "$OUT" "bare state strings: 1" "the new string is counted"
pass "the lint counts the bare state strings and refuses a new one"

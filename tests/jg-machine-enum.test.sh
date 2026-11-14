#!/usr/bin/env bash
# Behavior tests for the closed state lists (core/machines/<name>.states) and the lint that reads them, through bin/jg-machine.sh.
# The 23 files of this repository all load; a fixture table with a state outside its enum fails and the lint names the value;
# a fixture enum with two initial values fails; the ticket and delivering tables read their enums.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JM="$ROOT/bin/jg-machine.sh" MACHINES="$ROOT/core/machines"
T=$(jg_test_tmproot jg-machine-enum); mkdir -p "$T/tables"
export JG_MACHINES_TABLES="$T/tables"
tab() { local IFS=$'\t'; printf '%s\n' "$*"; }
jm() { OUT=$(bash "$JM" "$@" 2>&1); RC=$?; }

# 1. Each of the 23 files of this repository loads (the real files, through the real command).
n=0
for f in "$MACHINES"/*.states; do
  name=$(basename "$f" .states); n=$((n + 1))
  JG_MACHINES_ENUMS="$MACHINES" jm enum "$name"
  expect_code 0 "$RC" "enum $name loads"; assert_contains "$OUT" "ok enum $name:" "enum $name golden"
done
assert_equals 23 "$n" "23 enum files"
pass "the 23 enum files load"

# 2. The real ticket and delivering tables name only states of their enums.
unset JG_MACHINES_TABLES
jm check ticket; expect_code 0 "$RC" "ticket reads its enum"
jm check delivering; expect_code 0 "$RC" "delivering reads its enum"
grep -q '^enum	ticket$' "$MACHINES/tables/ticket.tsv" || fail "ticket table does not name its enum"
export JG_MACHINES_TABLES="$T/tables"
pass "the ticket and delivering tables read their enums"

# 3. A fixture table with a state outside its enum fails, and the lint names the value.
seed() {  # <extra state lines>
  { tab machine doc "files" tests/jg-machine-enum.test.sh
    tab enum doc
    tab state draft initial "A draft is being written." -
    tab state published terminal "The draft is published." -
    [ -n "${1:-}" ] && printf '%s\n' "$1"
    tab edge draft publish published a:b c g t
    tab observer "echo draft"; } > "$T/tables/doc.tsv"
}
{ tab '# doc: a fixture list'; tab draft initial active "being written"; tab published final final "out"; } > "$T/tables/../doc.states"
seed; jm check doc; expect_code 0 "$RC" "a table inside its enum"
seed "$(tab state limbo normal "Not in the list." -)"
jm check doc; expect_code 1 "$RC" "a state outside the enum"
assert_contains "$OUT" "state limbo is not in enum doc" "the lint names the value"
assert_contains "$OUT" "legal: draft published" "the lint lists the legal values"
pass "a state outside the enum fails and is named"

# 4. A fixture enum with two initial values fails; other malformed lists fail by name.
seed
bad_enum() {  # <name> <expected text> <line...>: replace the enum with the lines
  local want=$2; shift 2; printf '%s\n' "$@" > "$T/doc.states"
  jm enum doc; expect_code 1 "$RC" "enum should be refused"; assert_contains "$OUT" "$want" "enum lint should name"
  jm check doc; expect_code 1 "$RC" "check refuses the table with a bad enum"
}
bad_enum two-initial "2 initial values (draft published)" "$(tab draft initial active x)" "$(tab published initial active y)"
bad_enum none "no initial value" "$(tab draft - active x)" "$(tab published final final y)"
bad_enum dup "duplicate value draft" "$(tab draft initial active x)" "$(tab draft - active y)"
bad_enum nomeaning "value draft has no meaning" "$(tab draft initial active '')"
bad_enum badkind "kind 'busy' is not" "$(tab draft initial busy x)"
bad_enum badmark "mark 'start' is not" "$(tab draft start active x)"
bad_enum finalkind "disagree about being final" "$(tab draft initial active x)" "$(tab published final active y)"
bad_enum width "columns, got 3" "$(tab draft initial active x)" "$(tab published final y)"
jm enum nope; expect_code 2 "$RC" "a missing enum is a usage error"
pass "a malformed enum fails and the lint names the defect"

# 5. A side list has three columns and no initial value is needed.
{ tab a - "first"; tab b final "second"; } > "$T/side.states"
jm enum side; expect_code 0 "$RC" "a side list"; assert_equals "ok enum side: 2 values" "$OUT" "side list golden"
pass "a side list loads"

#!/usr/bin/env bash
# Behavior test for the writer report of core/machines/bin/tablelint.py (silent_writers), through its real caller
# bin/jg-machine.sh writers: each edge whose writer file calls neither the shadow nor the move command is named,
# the report never fails, and every shipped table can be reported.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JM="$ROOT/bin/jg-machine.sh"
T=$(jg_test_tmproot jg-machine-writer-lint); mkdir -p "$T/t" "$T/root/bin"
tab() { local IFS=$'\t'; printf '%s\n' "$*"; }

# A fixture repo: one writer that calls the move command, one that calls the shadow, one that calls neither.
printf '#!/usr/bin/env bash\nbash "$ROOT/bin/jg-move.sh" --shadow "$1" start\n' >"$T/root/bin/loud.sh"
printf '#!/usr/bin/env bash\nbash "$ROOT/bin/jg-machine-guard.sh" edge m work ended\n' >"$T/root/bin/shadowed.sh"
printf '#!/usr/bin/env bash\necho "writes a state and says nothing"\n' >"$T/root/bin/quiet.sh"
{ tab machine m carrier owner
  tab state start initial 'The record is filed.' - rest go
  tab state work normal 'A worker has it.' - waiting '5m -> alert slow-work'
  tab state ended terminal 'The work is finished.' -
  tab edge '(none)' file start bin/loud.sh:add - 'a record is filed' t
  tab edge start go work bin/quiet.sh:go - 'the worker starts' t
  tab edge work finish ended bin/shadowed.sh:done - 'the worker finishes' t
  tab edge work lose start bin/missing.sh:main - 'the worker is lost' t
  tab observer 'echo start'; } >"$T/t/m.tsv"

OUT=$(JG_MACHINES_TABLES="$T/t" JG_MACHINES_ROOT="$T/root" bash "$JM" writers m 2>&1); RC=$?
expect_code 0 "$RC" "the report never fails: $OUT"
assert_contains "$OUT" "silent m start go work"$'\t'"bin/quiet.sh:go" "a writer that says nothing is named"
assert_contains "$OUT" "silent m work lose start"$'\t'"bin/missing.sh:main" "a writer file that does not exist is named"
case "$OUT" in *loud.sh* | *shadowed.sh*) fail "a reporting writer was named: $OUT" ;; esac
assert_contains "$OUT" "report m: 4 edges, 2 silent" "the count line"
pass "silent writers are named and reporting ones are not"

# Every shipped table can be reported, and the report exits 0.
n=0
for f in "$ROOT"/core/machines/tables/*.tsv; do
  name=$(basename "$f" .tsv); n=$((n + 1))
  OUT=$(bash "$JM" writers "$name" 2>&1); RC=$?; expect_code 0 "$RC" "$name reports: $OUT"
  assert_contains "$OUT" "report $name:" "$name has a count line"
done
[ "$n" -ge 14 ] || fail "only $n tables found"
pass "the $n shipped tables report with exit 0"

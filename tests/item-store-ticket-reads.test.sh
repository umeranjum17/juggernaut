#!/usr/bin/env bash
# The read verbs of bin/jg-backlog.sh answer from the ticket tables in fleet.db: the fixture of tests/item-store-tickets.test.sh is
# imported, every read the callers make is answered, and tree and ready --spawnable give the fixture's rows.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FX=$ROOT/tests/fixtures/item-store-tickets
TK=$ROOT/core/item-store/adapters/tickets.py
T=$(jg_test_tmproot item-store-ticket-reads)
mkdir -p "$T/home/config" "$T/home/data" "$T/home/state"
printf '%s\n' "$T/store" > "$T/home/config/beads-dir"   # kept until bin/jg-backlog-lib.sh stops asking for a store path
: > "$T/home/config/backlog-intake-loose"
mkdir -p "$T/py"; for _py in /usr/bin/python3 /usr/local/bin/python3 "$(command -v python3)"; do [ -x "$_py" ] && { ln -sf "$_py" "$T/py/python3"; break; }; done
export PATH=$T/py:$PATH
export JG_HOME=$T/home JG_DATA_OVERRIDE=$T/home/data JG_STATE_OVERRIDE=$T/home/state BEADS_ACTOR=main
unset JG_TASK_ID JG_BACKLOG_LANE JG_BACKLOG_SPAWN_GEN JG_ROOT_OVERRIDE JG_BACKLOG_SNAPSHOT
BL="$ROOT/bin/jg-backlog.sh"

python3 "$TK" import --home main "$FX/export.jsonl" >/dev/null; expect_code 0 $? "the fixture imports"

# Every read verb, with the flags the callers pass: each is answered (an unknown id is refused as not found).
READS=("list" "list --all" "list --state held" "list --state queued --repo p" "list --blocked" "list --fields parent,labels,ask,release"
  "show jg-ready1" "show jg-pr --full" "show jg-blk" "show jg-unres" "view jg-child" "ready" "ready --repo p" "ready --repo nowhere"
  "markdown" "questions" "questions --all" "questions --json")
for r in "${READS[@]}"; do
  # shellcheck disable=SC2086
  out=$("$BL" $r 2>&1) || fail "read '$r' failed: $(printf '%s' "$out" | head -3)"
done
assert_contains "$("$BL" show jg-ready1)" "title: row ready1" "show prints the row from the tables"
out=$("$BL" show jg-nothere 2>&1); expect_code 1 $? "an unknown id is refused"
assert_contains "$out" "not found" "an unknown id says so"
pass "all ${#READS[@]} reads answer from the tables, and an unknown id is refused"

# --- tree and ready --spawnable
FLAG=$T/home/config/one-engine-read   # kept until bin/jg-backlog-spawnable.sh reads the tables without it
: > "$FLAG"
printf -- '- p\n' > "$T/home/data/projects.md"
out=$("$BL" ready --spawnable 2>&1); expect_code 0 $? "ready --spawnable from the tables: $out"
[ "$out" = "$(printf 'count: 4\njg-ready1\tp\njg-unres\tp\njg-child\tp\njg-rel\tp')" ] || fail "spawnable differs from the startable rows of the fixture: $out"
rm -f "$FLAG"
out=$("$BL" tree --homes 2>&1); expect_code 0 $? "tree from the tables: $out"
[ "$out" = "$(printf 'main:jg-ready1  [open]  row ready1\n  main:jg-child  [open]  row child')" ] || fail "tree differs from the fixture's parent edge: $out"
pass "ready --spawnable and tree read the tables"

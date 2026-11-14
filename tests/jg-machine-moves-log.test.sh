#!/usr/bin/env bash
# One move log: a legal move a writer reports through the shadow is appended to data/machine-moves.log with
# its time, machine, id, from, event, to and writer; an illegal move still goes only to the shadow log.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(jg_test_tmproot jg-machine-moves-log)
H="$TMP_ROOT/home"; TABLES="$TMP_ROOT/tables"
MOVES="$H/data/machine-moves.log"; SHADOW="$H/data/machine-shadow.log"
export JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_MACHINES_TABLES="$TABLES"
mkdir -p "$H/data" "$H/state" "$H/bin" "$H/core/machines/bin" "$TABLES"
for f in "$ROOT"/bin/*; do ln -s "$f" "$H/bin/"; done
mkdir -p "$H/core/machines/styles"
cp "$ROOT"/core/machines/bin/*.py "$H/core/machines/bin/"  # machine.py imports its siblings and reads the alert table, so the fixture takes both
cp "$ROOT/core/machines/styles/alert-table.tsv" "$H/core/machines/styles/"
{ printf 'machine\tdemo\trec\tx\n'
  printf 'state\tstart\tinitial\tStart.\t-\nstate\ttarget\tnormal\tTarget.\t-\nstate\tother\tnormal\tOther.\t-\n'
  printf 'edge\tstart\tgo\ttarget\tw:f\t-\tg\tt\nedge\ttarget\tback\tother\tw:f\t-\tg\tt\n'
  printf 'open\t*\tA fixture: the target states have no move out.\n'
  # shellcheck disable=SC2016 # expanded later by the table's observer
  printf 'observer\tcat "$JG_HOME/obs-demo" 2>/dev/null\n'; } > "$TABLES/demo.tsv"
report() { printf '%s\n' "$1" > "$H/obs-demo"; "$H/bin/jg-machine-shadow.sh" demo r1 "$2"; }

report start target || fail "the writer failed on a legal move"
[ "$(wc -l < "$MOVES")" -eq 1 ] || fail "a legal move wanted one move line, got $(cat "$MOVES" 2>/dev/null)"
IFS=$'\t' read -r epoch machine id from event to writer < "$MOVES"
case "$epoch" in '' | *[!0-9]*) fail "the epoch is not a time: $epoch" ;; esac
[ "$machine/$id/$from/$event/$to/$writer" = "demo/r1/start/go/target/w:f" ] || fail "the move line is wrong: $(cat "$MOVES")"
[ ! -s "$SHADOW" ] || fail "a legal move reached the shadow log"
pass "a legal move is one line: epoch, machine, id, from, event, to, writer"

report start other || fail "the writer failed on an illegal move"
[ "$(wc -l < "$MOVES")" -eq 1 ] || fail "an illegal move reached the move log"
[ "$(wc -l < "$SHADOW")" -eq 1 ] || fail "an illegal move wanted one shadow line"
pass "an illegal move goes only to the shadow log"

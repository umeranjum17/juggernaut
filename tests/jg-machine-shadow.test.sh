#!/usr/bin/env bash
# Adoption hooks: a writer reports its move to the machine table in shadow.
# The log (data/machine-shadow.log) stays empty for a legal move, gains exactly one line for an illegal one,
# and the writer's own result never changes. Fixture tables are generated here; no fleet record is used.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(jg_test_tmproot jg-machine-shadow)
HOME_DIR="$TMP_ROOT/home"; TABLES="$TMP_ROOT/tables"; LOG="$HOME_DIR/data/machine-shadow.log"
export JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$HOME_DIR/state" JG_MACHINES_TABLES="$TABLES"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/bin" "$HOME_DIR/core/machines/bin" "$TABLES"

# seed <machine> <target>: a table whose one legal move is start -> <target>; the observer reads the state from a file.
seed() {
  { printf 'machine\t%s\trec\tx\n' "$1"
    printf 'state\tstart\tinitial\tStart.\t-\nstate\t%s\tnormal\tTarget.\t-\nstate\tother\tnormal\tOther.\t-\n' "$2"
    printf 'edge\tstart\tgo\t%s\tw:f\t-\tg\tt\nedge\tstart\tdrift\tother\tw:f\t-\tg\tt\n' "$2"
    # shellcheck disable=SC2016 # the observer line is read later by the table, with $JG_HOME expanded then
    printf 'observer\tcat "$JG_HOME/obs-%s" 2>/dev/null\n' "$1"; } > "$TABLES/$1.tsv"
}
observe() { printf '%s\n' "$2" > "$HOME_DIR/obs-$1"; }  # <machine> <state word>
lines() { [ -f "$LOG" ] && wc -l < "$LOG" || echo 0; }
# expect <label> <machine> <state> <log lines gained>: run "$@"-style writer in $RUN with the record in <state>
expect() {
  local label=$1 machine=$2 state=$3 want=$4 before
  observe "$machine" "$state"; before=$(lines)
  "$RUN" || fail "$label: the writer failed with a $state record"
  [ "$(( $(lines) - before ))" -eq "$want" ] || fail "$label: wanted $want new shadow lines for $state, got $(( $(lines) - before ))"
}
both() { # <label> <machine> <target>: legal move logs nothing, an illegal one logs one line naming the machine
  seed "$2" "$3"
  expect "$1 legal" "$2" start 0
  expect "$1 illegal" "$2" other 1
  [ "$(tail -n 1 "$LOG" | cut -f2-5)" = "$(printf '%s\tother\t%s\tshadow' "$2" "$3")" ] || fail "$1: the line does not name the move: $(tail -n 1 "$LOG")"
  pass "$1: legal move logs nothing, illegal move logs one line, writer unchanged"
}

# The fixture home holds the real bin/ scripts (linked, as a landed home has them) and the engine's code.
for f in "$ROOT"/bin/*; do ln -s "$f" "$HOME_DIR/bin/"; done
cp "$ROOT/core/machines/bin/machine.py" "$HOME_DIR/core/machines/bin/"
RUN=shadow_demo; shadow_demo() { "$HOME_DIR/bin/jg-machine-shadow.sh" demo r1 target; }
both "helper" demo target
RUN=shadow_nosuch; shadow_nosuch() { "$HOME_DIR/bin/jg-machine-shadow.sh" nosuch r1 x; }; expect "a machine with no table" nosuch start 0

RUN=inbox_ring; mkdir -p "$HOME_DIR/state/t1.inbox"
inbox_ring() { bash -c '. "$1/bin/jg-task-inbox-lib.sh"; jg_task_inbox_record_ring "$2" t1 "$2/t1.inbox/001.msg"' _ "$ROOT" "$HOME_DIR/state"; }
both "inbox ring" task-inbox ring-counted

RUN=backlog_close
backlog_close() { bash -c '. "$1/bin/jg-backlog-transition-lib.sh"; jg_backlog_close_transition "" "$2/t1.marker" "$2/data" t1 "$2/state"' _ "$ROOT" "$HOME_DIR" >/dev/null 2>&1; true; }
both "backlog close" task "done"

RUN=landing_run
rm -f "$HOME_DIR/bin/jg-trunk.sh" "$HOME_DIR/bin/jg-teardown.sh"  # fakes: a landing that succeeds and a cleanup that succeeds
printf '#!/bin/sh\nexit 0\n' > "$HOME_DIR/bin/jg-trunk.sh"; cp "$HOME_DIR/bin/jg-trunk.sh" "$HOME_DIR/bin/jg-teardown.sh"; chmod +x "$HOME_DIR/bin/jg-trunk.sh" "$HOME_DIR/bin/jg-teardown.sh"
printf "branch=feature/t1\n" > "$HOME_DIR/state/t1.meta"  # the landing writer reads its task record
landing_run() { bash "$ROOT/core/trunk-landing/trunk-landing.sh" run "$HOME_DIR" t1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; }
both "landing run" landing landed

#!/usr/bin/env bash
# Slice J3b of the state-machine plan on a real Beads store, through the real callers: the writers of the moments make the ticket's move
# (bin/jg-move.sh) first. `trace record` (bin/jg-beads-trace.py, what the spawn, the tick, the lander and the merge call) and `moment`
# (bin/jg-beads-moment.py) refuse an illegal move and then write no event and no moment; the delivery tick's done step
# (bin/jg-ready-trace.sh) writes a new ready_at for a new head, nothing for a landed ticket (it sets the wait `lead` for a head that is not
# on the trunk), and nothing for the same head; a local landing of a project that publishes nothing writes released_at with landed_at.
# JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the builds; without them the run skips plainly.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

T=$(jg_test_tmproot jg-move-writers); H=$T/home
WRAPPER=$ROOT/bin/jg-beads.sh CLI=$ROOT/bin/jg-backlog.sh
unset BEADS_DB BEADS_DOLT_SHARED_SERVER BEADS_ACTOR JG_BACKLOG_LANE JG_BACKLOG_SPAWN_GEN JG_BACKLOG_AGENT JG_BACKLOG_LANE_HANDOVER
mkdir -p "$T/store" "$H/config" "$H/data" "$H/state" "$H/core/machines"
# The home holds a copy of the ticket tables whose observer reads state/<ticket>.stage, and the ticket machine is enforced.
cp -r "$ROOT/core/machines/tables" "$ROOT"/core/machines/*.states "$H/core/machines/"
sed -i 's|^observer	.*|observer	cat "$(dirname "$JG_MACHINES_TABLES")/../../state/$1.stage"|' "$H/core/machines/tables/ticket.tsv"
printf 'ticket\n' > "$H/config/machine-enforce"
export TZ=UTC TMPDIR=$T BEADS_DIR=$T/store/.beads JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT JG_HOME=$H JG_DATA_OVERRIDE=$H/data \
  JG_MACHINES_TABLES=$H/core/machines/tables
printf '%s\n' "$BEADS_DIR" > "$H/config/beads-dir"

bd() { "$WRAPPER" "$@"; }
axi() { "$CLI" "$@"; }
row() { bd show "$1" --json 2>/dev/null | jq -c 'if type == "array" then .[0] else . end'; }
meta() { row "$1" | jq -r --arg k "$2" '.metadata[$k] // ""'; }
events() { bd provenance log "$1" --json | jq length; }
moves() { { grep "	$1	" "$H/data/moves.log" 2>/dev/null || true; } | wc -l | tr -d " "; }
stage() { printf '%s\n' "$2" > "$H/state/$1.stage"; }
tick() { bash "$ROOT/bin/jg-ready-trace.sh" "$H" >/dev/null 2>&1 || fail "the ready step failed"; }

bd init --prefix jg >"$T/init.log" 2>&1 || fail "init the store: $(cat "$T/init.log")"

# 1. An illegal move writes no event and no moment; a legal one writes both and one move line.
axi add jg-w1 "[feature] illegal then legal" --priority 2 --body why >/dev/null || fail "file jg-w1"
stage jg-w1 intake
axi trace record jg-w1 commit work-id w1@done-1 --source jg-done --at 1794000000 >/dev/null 2>&1 && fail "claim-done from intake must be refused"
[ "$(events jg-w1)" = 0 ] && [ -z "$(meta jg-w1 ready_at)" ] || fail "a refused move wrote an event or a moment"
[ "$(moves jg-w1)" = 0 ] || fail "a refused move wrote a move line"
axi moment jg-w1 proved_at >/dev/null 2>&1 && fail "prove-pass from intake must be refused"
[ -z "$(meta jg-w1 proved_at)" ] || fail "a refused moment wrote proved_at"
stage jg-w1 building
axi trace record jg-w1 commit work-id w1@done-1 --source jg-done --at 1794000000 >/dev/null || fail "claim-done from building must be written"
[ "$(events jg-w1)" = 1 ] && [ -n "$(meta jg-w1 ready_at)" ] && [ "$(moves jg-w1)" = 1 ] || fail "a legal move must write one move, one event and ready_at"
stage jg-w1 proving.planned
axi moment jg-w1 gated_at >/dev/null 2>&1 && fail "gate from proving must be refused"
pass "a move that is illegal writes no event and no moment; a legal one writes both"

# 2. The done step of the tick. A lane with a project and a branch offers a head; the ticket has the row's moments.
P=$T/proj; jg_git_identity fmtest fmtest@example.com; jg_git_init_commit "$P"; git -C "$P" branch -M main
git -C "$P" checkout -q -b lane-w2; printf '1\n' > "$P/a"; git -C "$P" add a; git -C "$P" commit -q -m one
printf 'main\n' > "$H/state/trunk-branch-proj"
lane() {  # <task> <ticket>
  printf 'ticket=%s\nproject=%s\nbranch=lane-w2\nmode=local\n' "$2" "$P" > "$H/state/$1.meta"
}
done_line() { printf 'done [at=%s]: ready\n' "$2" >> "$H/state/$1.status"; }
newhead() { printf '%s\n' "$1" > "$P/a"; git -C "$P" commit -qam "$1"; }

# 2a. A ticket that has not landed: a done line with a new head writes a new ready_at; the same head again writes nothing.
axi add jg-w2 "[feature] proved, not landed" --priority 2 --body why >/dev/null || fail "file jg-w2"
lane lane-w2 jg-w2; stage jg-w2 building
done_line lane-w2 1794000100; tick
first=$(meta jg-w2 ready_at); [ -n "$first" ] || fail "the first done line must write ready_at"
bd update jg-w2 --set-metadata proved_at=2026-11-12T10:00:00Z >/dev/null; stage jg-w2 delivering.queued
done_line lane-w2 1794000200; tick
[ "$(meta jg-w2 ready_at)" = "$first" ] && [ "$(events jg-w2)" = 1 ] || fail "a done line with the same head must write nothing"
newhead two; done_line lane-w2 1794000300; tick
[ "$(meta jg-w2 ready_at)" \> "$first" ] && [ "$(events jg-w2)" = 2 ] || fail "a new head on a proved ticket that has not landed must write a new ready_at"
[ -z "$(meta jg-w2 wait)" ] || fail "a ticket that has not landed gets no wait"
pass "tick: a new head on a proved ticket writes a new ready_at; the same head writes nothing"

# 2b. A landed ticket: a done line with a new head writes no moment and sets the wait lead (reason decision).
axi add jg-w3 "[feature] landed" --priority 2 --body why >/dev/null || fail "file jg-w3"
lane lane-w3 jg-w3; stage jg-w3 building
done_line lane-w3 1794000400; tick
before=$(meta jg-w3 ready_at); [ -n "$before" ] || fail "the first done line of jg-w3 must write ready_at"
bd update jg-w3 --set-metadata landed_at=2026-11-12T11:00:00Z --set-metadata proved_at=2026-11-12T10:30:00Z >/dev/null; stage jg-w3 delivering.batched
newhead three; done_line lane-w3 1794000500; tick
[ "$(meta jg-w3 ready_at)" = "$before" ] && [ "$(events jg-w3)" = 1 ] || fail "a done line on a landed ticket must write no moment"
[ "$(meta jg-w3 wait)" = lead ] && [ "$(meta jg-w3 wait_reason)" = decision ] || fail "a new head that is not on the trunk must set the wait lead, got [$(meta jg-w3 wait)/$(meta jg-w3 wait_reason)]"
pass "tick: a new head on a landed ticket writes no moment and sets the wait lead"

# 3. A local landing of a project that publishes nothing is the end: released_at is written with landed_at.
axi add jg-w4 "[feature] landed locally" --priority 2 --body why >/dev/null || fail "file jg-w4"
stage jg-w4 delivering.gated
axi trace record jg-w4 land git-sha 0123456789abcdef0123456789abcdef01234567 --source jg-merge-local --at 1794000600 >/dev/null || fail "the local landing"
[ -n "$(meta jg-w4 landed_at)" ] && [ "$(meta jg-w4 released_at)" = "$(meta jg-w4 landed_at)" ] || fail "released_at must be written with landed_at"
[ "$(row jg-w4 | jq -r .metadata.commit)" = 0123456789abcdef0123456789abcdef01234567 ] || fail "the landing records its commit"
axi add jg-w5 "[feature] landed on the trunk line" --priority 2 --body why >/dev/null || fail "file jg-w5"
stage jg-w5 delivering.gated
axi trace record jg-w5 land git-sha 0123456789abcdef0123456789abcdef01234567 --source jg-trunk-land --at 1794000600 >/dev/null || fail "the trunk landing"
[ -z "$(meta jg-w5 released_at)" ] || fail "a landing that publishes later must not write released_at"
pass "a local landing that publishes nothing writes released_at with landed_at; a trunk landing does not"

#!/usr/bin/env bash
# Spawn carries the ticket: a fresh ship or Recon spawn starts from a ticket, the task id is made from it, and every
# script that knows only the task id reaches the ticket's row. Real bin/jg-backlog.sh, bin/jg-brief.sh, bin/jg-spawn.sh,
# bin/jg-captain-hold.sh and bin/jg-teardown.sh over a fixture home with a real Beads store; only the terminal and the
# worktree tool are stand-ins. JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the pinned builds, which skip without them.
#
# T1 a fresh spawn with no --ticket, an unknown ticket, an unreadable title, a task id that is not the one made from the
#    ticket, and a task id that another row answers to is each refused with one line that names the fix.
# T2 a child ticket jg-x.1 runs as task jg-x-1: the brief and the spawn write metadata.task on its row, the record
#    holds ticket=, the pane gets JG_TICKET, the row answers to its task id and goes in flight through it.
# T3 a child with an open owner question is refused at spawn, and the landing's own check (blocking, by task id) finds it.
# T4 the start-up sweep's one read finds the child's row by its task id.
# T5 a teardown closes the child's row.
# T6 --squad-lead and --relaunch take no --ticket; a relaunch reads ticket= from the record.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-spawn-ticket)
W="$TMP_ROOT/world"; H="$W/home"; PROJ="$W/proj"
mkdir -p "$W"
git init -q --bare -b main "$W/origin.git"
git clone -q "$W/origin.git" "$PROJ" 2>/dev/null
printf 'v1\n' > "$PROJ/AGENTS.md"; git -C "$PROJ" add -A; git -C "$PROJ" commit -qm c1
git -C "$PROJ" push -q origin HEAD:refs/heads/main; git -C "$PROJ" fetch -q
git -C "$PROJ" remote set-head origin main >/dev/null 2>&1 || true
FAKEBIN=$(make_spawn_fakebin "$W/fake" gh gh-axi)
jg_test_fake_sleep_noop "$FAKEBIN"
sed -i '/^set -u$/a case "$*" in *pane_current_command*) echo bash; exit 0 ;; esac' "$FAKEBIN/tmux"
jg_test_spawn_home "$H"
: > "$H/config/backlog-intake-loose"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$H/config/host-memory"
export JG_FAKE_PANE_LOG="$W/pane.log"
: > "$JG_FAKE_PANE_LOG"

bl() { jg_test_backlog "$H" "$@"; }
field() { BEADS_DIR=$(cat "$H/config/beads-dir") "$ROOT/bin/jg-beads.sh" show "$1" --json 2>/dev/null | jq -r "(if type == \"array\" then .[0] else . end) | $2"; }
row_field() { bl show "$1" 2>&1 | sed -n "s/^  $2: *//p" | head -1; }
N=0
# brief_and_spawn <task id> <ticket> [spawn args...]: a real brief from the ticket, then the real spawn in its own isolated copy.
brief_and_spawn() {
  local id=$1 tkt=$2 wt
  shift 2
  N=$((N + 1)); wt="$W/wt-$N"
  JG_HOME="$H" "$ROOT/bin/jg-brief.sh" "$id" proj --mode direct-PR --ticket "$tkt" --project "$PROJ" --migration-row none >"$W/brief.out" 2>&1 \
    || { out=$(cat "$W/brief.out"); rc=1; return; }
  sed -i 's/{TASK}/Exercise the ticket join./;s/{JUGGERNAUT_SPEC}/Exercise the ticket join end to end./' "$H/data/$id/brief.md"
  git -C "$PROJ" worktree add -q --detach "$wt" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy"
  out=$(jg_test_run_spawn "$H" "$wt" "$FAKEBIN" "$id" "$PROJ" codex --mode direct-PR --yolo off --ticket "$tkt" "$@"); rc=$?
}

# The ask and its slices as real children (bd numbers them): ticket jg-x.N runs as task jg-x-N; a piece jg-x.N.M as jg-x-N-M.
ask=$(bl add --mint "[captain-ask] Plan the ticket join" --repo sample --body why --json | jq -r .task.id) || fail "mint the ask"
child() { bl add --parent "$1" "$2" --repo sample --body why --json | jq -r .task.id; }
c1=$(child "$ask" "Spawn carries the ticket") || fail "file the first slice"
c2=$(child "$ask" "Second slice of work") || fail "file the second slice"
c3=$(child "$ask" "Third slice of work") || fail "file the third slice"
piece=$(child "$c1" "Piece of the slice") || fail "file the piece"
task_of() { printf '%s\n' "${1//./-}"; }
T1=$(task_of "$c1"); T2=$(task_of "$c2"); T3=$(task_of "$c3")
[ "$c1" = "$ask.1" ] && [ "$(task_of "$piece")" = "$ask-1-1" ] || fail "the children must be $ask.1 and $ask.1.1, got $c1 and $piece"
# A refusal case spawns with a bare brief: the ticket checks run after the brief's own, and no refusal case reaches a launch.
plain_brief() {
  mkdir -p "$H/data/$1"
  printf '# Task\n## Captain'"'"'s intent\nExercise the ticket join.\n\n## Juggernaut spec\nExercise it end to end.\n' > "$H/data/$1/brief.md"
}
bare() { jg_test_run_spawn "$H" "$W/none" "$FAKEBIN" "$@"; }

# T1: the refusals, each with the line that names the fix, and none leaves a task record.
out=$(PATH="$FAKEBIN:$PATH" JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" JG_CONFIG_OVERRIDE="$H/config" JG_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/jg-spawn.sh" "$T1" "$PROJ" codex --mode direct-PR --yolo off 2>&1); rc=$?
expect_code 1 "$rc" "T1 a fresh spawn with no --ticket should be refused: $out"
assert_contains "$out" "requires --ticket" "T1 the refusal for a missing ticket must say so"
out=$(bare "$T1" "$PROJ" codex --mode direct-PR --yolo off --ticket "$ask"); rc=$?
expect_code 2 "$rc" "T1 a task id that is not the one made from the ticket should be refused: $out"
assert_contains "$out" "the task id for ticket $ask is $ask (every dot becomes a dash), not $T1" "T1 the refusal must name the id made from the ticket"
plain_brief jg-nosuch-1; plain_brief "$T1"; plain_brief jg-clash-name; plain_brief "$T3"
out=$(bare jg-nosuch-1 "$PROJ" codex --mode direct-PR --yolo off --ticket jg-nosuch.1); rc=$?
expect_code 1 "$rc" "T1 a ticket with no row should be refused: $out"
assert_contains "$out" "bin/jg-backlog.sh add jg-nosuch.1" "T1 the refusal for an unknown ticket must name the add command"
bl update "$c1" --title "[blocker] jg-abc12345 http://x/y a very long title with far too many words in it" >/dev/null 2>&1 || fail "T1 could not set the bad title"
out=$(bare "$T1" "$PROJ" codex --mode direct-PR --yolo off --ticket "$c1"); rc=$?
expect_code 1 "$rc" "T1 an unreadable title should be refused: $out"
assert_contains "$out" "update $c1 --title" "T1 the refusal for an unreadable title must name the update --title command"
bl update "$c1" --title "Spawn carries the ticket" >/dev/null 2>&1 || fail "T1 could not restore the title"
# A different row that already answers to the task id: an own-id row jg-clash-name, and a ticket jg-clash.name that would run as it.
bl add jg-clash-name "Row that owns the name" --kind ship --repo sample --body why >/dev/null 2>&1 || fail "T1 could not file the own-id row"
bl add jg-clash.name "Ticket with a dot" --kind ship --repo sample --body why >/dev/null 2>&1 || fail "T1 could not file the dotted ticket"
out=$(bare jg-clash-name "$PROJ" codex --mode direct-PR --yolo off --ticket jg-clash.name); rc=$?
expect_code 1 "$rc" "T1 a task id another row answers to should be refused: $out"
assert_contains "$out" "jg-clash-name" "T1 the clash refusal must name the task id"
assert_contains "$out" "jg-clash.name" "T1 the clash refusal must name the ticket"
! compgen -G "$H/state/*.meta" >/dev/null || fail "T1 a refused spawn wrote a task record: $(ls "$H/state")"
[ "$(field "$c1" '.metadata.task // "none"')" = none ] || fail "T1 a refused spawn wrote metadata.task on the row"
printf 'ok - T1 refusals: no ticket, wrong task id, unknown ticket, unreadable title, a clash\n'

# T2: slice jg-x.2 runs as task jg-x-2.
brief_and_spawn "$T2" "$c2"
expect_code 0 "$rc" "T2 the spawn of ticket $c2 should launch: $out"
grep -q "^Ticket: $c2 - Second slice of work\$" "$H/data/$T2/brief.md" || fail "T2 the brief must carry the ticket id and title: $(cat "$H/data/$T2/brief.md")"
grep -q "trailer \`Ticket: $c2\`" "$H/data/$T2/brief.md" || fail "T2 the brief must carry the commit trailer"
grep -q "Start the subject with the task id \`$T2\`" "$H/data/$T2/brief.md" || fail "T2 the brief must carry the task id for the subject while the landing check reads the commit text"
[ "$(sed -n 's/^ticket=//p' "$H/state/$T2.meta")" = "$c2" ] || fail "T2 the record must hold ticket=$c2: $(cat "$H/state/$T2.meta")"
[ "$(field "$c2" .metadata.task)" = "$T2" ] || fail "T2 the row must hold metadata.task=$T2"
grep -qxF "export JG_TICKET=$c2" "$JG_FAKE_PANE_LOG" || fail "T2 the pane must get JG_TICKET: $(cat "$JG_FAKE_PANE_LOG")"
[ "$(row_field "$T2" id)" = "$c2" ] || fail "T2 the task id must reach the ticket's row, got: $(bl show "$T2" 2>&1 | head -3)"
[ "$(row_field "$T2" state)" = in_flight ] || fail "T2 the spawn must put the ticket In flight through its task id"
printf 'ok - T2 ticket %s runs as task %s: record, row, pane and brief carry it\n' "$c2" "$T2"

# T3: an open owner question on a child blocks its start, and the landing's own check finds it by the task id.
hold() { JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" JG_CONFIG_OVERRIDE="$H/config" "$ROOT/bin/jg-captain-hold.sh" "$@"; }
bl add jg-q3 "Which way for slice three" --kind ship --repo sample --body "Owner question on the third slice
linked-to: $c3" >/dev/null 2>&1 || fail "T3 could not file the owner question"
hold hold jg-q3 --reason "Which way should the slice go?" >/dev/null 2>&1 || fail "T3 could not hold the question for the owner"
out=$(bare "$T3" "$PROJ" codex --mode direct-PR --yolo off --ticket "$c3"); rc=$?
expect_code 1 "$rc" "T3 a child with an open owner question should be refused at spawn: $out"
assert_contains "$out" "decision still open" "T3 the refusal must name the open decision"
blocked=$(hold blocking "$T3"); rc=$?
expect_code 0 "$rc" "T3 the landing's open-decision check should find the child by its task id: $blocked"
printf 'ok - T3 an open owner question on %s blocks its start and its landing check\n' "$c3"

# T4: the start-up sweep's one read keys rows by task id, so it finds the child.
sweep=$(JG_HOME="$H" JG_CONFIG_OVERRIDE="$H/config" JG_DATA_OVERRIDE="$H/data" JG_STATE_OVERRIDE="$H/state" bash -c '
  . "$1/bin/jg-backlog-lib.sh"; . "$1/bin/jg-backlog-transition-lib.sh"
  jg_backlog_row_snapshot "$2/data" && jg_backlog_row_snapshot_probe "$3" && printf "%s %s\n" "$JG_BACKLOG_ROW_RESULT" "$JG_BACKLOG_ROW_STATE"' _ "$ROOT" "$H" "$T2")
[ "$sweep" = "found in_flight no no" ] || fail "T4 the sweep must find the child's row by its task id, got: $sweep"
printf 'ok - T4 the start-up sweep finds the child by task id: %s\n' "$sweep"

# T6: --squad-lead and --relaunch take no --ticket; a relaunch reads ticket= from the record and keeps it.
out=$(bare lead-x "$H" codex --squad-lead --ticket "$c2"); rc=$?
expect_code 1 "$rc" "T6 --squad-lead with a ticket should be refused: $out"
assert_contains "$out" "applies only to ship and scout" "T6 the refusal must say a lead starts a home, not a ticket"
out=$(bare "$T2" --relaunch --ticket "$c2"); rc=$?
expect_code 1 "$rc" "T6 --relaunch with a ticket should be refused: $out"
: > "$JG_FAKE_PANE_LOG"
out=$(JG_FAKE_DUPLICATE_WINDOW="jg-$T2" jg_test_run_spawn "$H" "$W/wt-1" "$FAKEBIN" "$T2" --relaunch); rc=$?
expect_code 0 "$rc" "T6 a relaunch should read the ticket from the record: $out"
[ "$(sed -n 's/^ticket=//p' "$H/state/$T2.meta")" = "$c2" ] || fail "T6 a relaunch must keep ticket= in the record"
grep -qxF "export JG_TICKET=$c2" "$JG_FAKE_PANE_LOG" || fail "T6 a relaunch must export JG_TICKET again: $(cat "$JG_FAKE_PANE_LOG")"
printf 'ok - T6 a lead and a relaunch take no --ticket; a relaunch reads it from the record\n'

# T5: a teardown closes the child's row through its task id.
printf 'pr=https://github.com/o/r/pull/7\n' >> "$H/state/$T2.meta"
out=$(HOME="$H/user-home" PATH="$FAKEBIN:$PATH" JG_ROOT_OVERRIDE='' JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" JG_CONFIG_OVERRIDE="$H/config" \
  "$ROOT/bin/jg-teardown.sh" "$T2" 2>&1) || fail "T5 the teardown should succeed: $out"
[ "$(field "$c2" .status)" = closed ] || fail "T5 the teardown must close the child's row: $(bl show "$c2" 2>&1 | head -5)"
printf 'ok - T5 a teardown closed the row of %s\n' "$c2"

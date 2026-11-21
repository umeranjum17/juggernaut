#!/usr/bin/env bash
# Behavior test: a local-trunk lane spawned again under a task id whose earlier head already landed.
# A landed record for an earlier head must not answer cleaned or landed for the lane's current head
# (core/machines/observers/task.sh, landing()); the lane reads ready-to-land once its new worker is done.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JM="$ROOT/bin/jg-machine.sh"
T=$(jg_test_tmproot jg-task-reused-id); H=$T/home
mkdir -p "$H"/{state,config,bin,crew,rows,data/jg-trunk-landing}
export JG_HOME=$H
cat > "$H/bin/jg-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: none · fixture\n' "$(cat "$JG_HOME/crew/$1" 2>/dev/null || echo unknown)"
SH
cat > "$H/bin/jg-backlog.sh" <<'SH'
#!/usr/bin/env bash
[ -r "$JG_HOME/rows/$2" ] || exit 1
printf 'task:\n  id: %s\n  state: %s\n' "$2" "$(cat "$JG_HOME/rows/$2")"
SH
chmod +x "$H"/bin/*.sh

jg_git_init_commit "$T/wt"
B=$(git -C "$T/wt" rev-parse HEAD)   # the lane's current head
A=$(printf 'a%.0s' {1..40})          # an earlier head that landed

# seed <id> <worktree|-> <head of the landed record> <status line>
seed() {
  printf 'done' > "$H/crew/$1"; printf 'in_flight' > "$H/rows/$1"; printf '%s\n' "$4" > "$H/state/$1.status"
  printf 'kind=ship\nmode=local-trunk\n' > "$H/state/$1.meta"
  [ "$2" = - ] || printf 'worktree=%s\n' "$2" >> "$H/state/$1.meta"
  printf 'landed cleaned up\n' > "$H/data/jg-trunk-landing/$1.$3.state"
}
state() { JG_HOME=$H bash "$JM" show task "$1" 2>&1 | grep "^state"; }
done_line='done [at=2]: ready in branch b'

seed t1 "$T/wt" "$A" "$done_line"
assert_equals ready-to-land "$(bash "$ROOT/core/machines/observers/task.sh" t1)" "T1: an earlier head's landed record leaves the new head ready to land"
assert_contains "$(state t1)" "state"$'\t'"ready-to-land" "T1: the machine shows ready-to-land for the re-spawned lane"
seed t2 "$T/wt" "$B" "$done_line"
assert_equals cleaned "$(bash "$ROOT/core/machines/observers/task.sh" t2)" "T2: a landed record naming the current head reads cleaned"
seed t3 - "$A" "$done_line"
assert_equals cleaned "$(bash "$ROOT/core/machines/observers/task.sh" t3)" "T3: a lane with no worktree is cleaned"
seed t4 "$T/wt" "$A" 'working [at=2]: second part'
assert_not_equals ready-to-land "$(bash "$ROOT/core/machines/observers/task.sh" t4)" "T4: a re-spawned lane still working is not ready to land"
pass "a task id reused after a landing reads the new head, not the landed one"

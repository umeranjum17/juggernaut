#!/usr/bin/env bash
# Shared fixture for the captain-approval suites tests/jg-captain-approval.test.sh and tests/jg-captain-approval-b.test.sh: a fixture home with a
# Beads backlog, a project clone, a stand-in terminal and the helpers both read. It is sourced, never run.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v openssl >/dev/null 2>&1 || { echo "skip: openssl not found"; exit 0; }

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot "${JG_CAPTAIN_APPROVAL_SUITE:-jg-captain-approval}")

W="$TMP_ROOT/world"
HOME_DIR="$W/home"
PROJ="$W/proj"
mkdir -p "$W"
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$W/origin.git" "$PROJ" 2>/dev/null
printf 'v1\n' > "$PROJ/AGENTS.md"
git -C "$PROJ" add -A
git -C "$PROJ" commit -qm c1
git -C "$PROJ" push -q origin HEAD:refs/heads/main
git -C "$PROJ" fetch -q
git -C "$PROJ" remote set-head origin main >/dev/null 2>&1 || true

jg_test_spawn_home "$HOME_DIR"
FAKEBIN=$(make_spawn_fakebin "$W/fake")
jg_test_fake_sleep_noop "$FAKEBIN"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$HOME_DIR/config/host-memory"
jg_test_beads_home "$HOME_DIR"

tasks() { jg_test_backlog "$HOME_DIR" "$@"; }
captain() {  # <home> <args...>
  local h=$1
  shift
  PATH="$FAKEBIN:$PATH" JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" \
    JG_DATA_OVERRIDE="$h/data" JG_CONFIG_OVERRIDE="$h/config" "$ROOT/bin/jg-captain-hold.sh" "$@"
}
body_of() { tasks show "$1" --full 2>/dev/null; }

N=0
# ticket <title> [body]: a queued ticket; sets TID.
ticket() {
  N=$((N + 1))
  TID=jg-ap$N
  local prio=2; [[ "$1" == \[captain-ask\]* ]] && prio=0
  tasks add "$TID" "$1" --priority "$prio" --kind ship --repo proj --body "${2:-Fixture ticket $TID}" >"$W/add.out" 2>&1 \
    || fail "could not add the ticket $TID: $(cat "$W/add.out")"
}
scaffold() {  # <id> [brief-args...]
  local id=$1
  shift
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$id" proj --project "$PROJ" "$@" >"$W/scaffold.out" 2>&1 \
    || { cat "$W/scaffold.out" >&2; return 1; }
  sed -i 's/{TASK}/Exercise the approval gate./;s/{JUGGERNAUT_SPEC}/Exercise the approval gate end to end./' "$HOME_DIR/data/$id/brief.md"
}
spawn() {  # <id> <ship|scout>
  local id=$1 wt="$W/wt-$1-$RANDOM"
  git -C "$PROJ" worktree add -q --detach "$wt" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy"
  if [ "$2" = scout ]; then
    jg_test_run_spawn "$HOME_DIR" "$wt" "$FAKEBIN" "$id" "$PROJ" codex --scout
  else
    jg_test_run_spawn "$HOME_DIR" "$wt" "$FAKEBIN" "$id" "$PROJ" codex --mode direct-PR --yolo off
  fi
}
refused_clean() { [ ! -e "$HOME_DIR/state/$1.meta" ] || fail "the refused spawn $1 wrote a task record"; }

#!/usr/bin/env bash
# tests/jg-backend-herdr-workspace-per-home-e2e.test.sh - mandatory ISOLATED
# end-to-end real-herdr test for the P3 "workspace-per-home" pass (AGENTS.md
# task herdr-sm-spaces-k4). Drives the REAL bin/jg-spawn.sh and
# bin/jg-teardown.sh (not just adapter primitives), because the requirement
# under test - a --squad-lead spawn's tab landing in the squad_lead's OWN
# herdr workspace, and a operator spawned FROM a squad_lead home landing there
# too - only exists at jg-spawn.sh's own home-shadowing logic (the herdr case
# arm) and at jg_backend_herdr_workspace_label's JG_HOME read; neither is
# exercised by the adapter-primitive smoke test.
#
# Mirrors tests/jg-backend-autodetect-smoke.test.sh's isolated-session
# convention: a private throwaway HERDR_SESSION (never the captain's
# default), scratch JG_HOME(s), and scratch local-only projects.
#
# Safety (2026-07-02 incident, see tests/herdr-test-safety.sh): cleanup uses
# ONLY herdr_safe_stop_and_delete, never a bare/inline-prefixed `herdr server
# stop`.
#
# Covers, at minimum (per the task brief):
#   - a primary-shaped home (no .jg-squad-lead-home marker) spawning a
#     operator into the "juggernaut" workspace
#   - a squad-lead-shaped home (with .jg-squad-lead-home) getting its own
#     labeled workspace when the PRIMARY spawns it (jg-spawn.sh's JG_HOME
#     shadow for --squad-lead)
#   - a operator spawned FROM that squad-lead-shaped home (the squad_lead
#     running its OWN jg-spawn.sh) landing in the squad_lead's own workspace -
#     this exact path has never run before this test
#   - teardown closing the right tab (and no other)
#   - list-live recovery seeing only its own home's tabs, for both homes
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
  esac
}
assert_not_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by jg-spawn.sh)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_test_require_beads || exit 0

# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

# TMP_ROOT is physically resolved (mktemp -d "$(pwd -P)"-relative) for the same
# low-noise scratch fixture shape used by
# tests/jg-backend-autodetect-smoke.test.sh.
# jg-spawn no longer needs this as a symlink workaround: jg-spawn-symlink-guard-s8
# canonicalized project and backend cwd comparisons in the worktree-discovery
# poll.
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/jg-herdr-e2e.XXXXXX")
SESSION="jg-lab-herdr-e2e-$$"
export HERDR_SESSION="$SESSION"
WT1=; WT2=
cleanup_all() {
  [ -n "$WT1" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT1" >/dev/null 2>&1
  [ -n "$WT2" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT2" >/dev/null 2>&1
  herdr_safe_stop_and_delete "$SESSION"
  # Spawn leaves each state/<id>.git-hooks strip dir read-only.
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT
herdr_prepare_runtime "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/jg-backend.sh"
jg_backend_source herdr || fail "jg_backend_source herdr failed"

# --- scratch world: a primary-shaped home, a squad-lead-shaped home, two projects ---

# This test asserts the per-home FLAT workspace shape, so both homes opt out of
# the default-on presentation projection rather than depending on that default.
PRIMARY_HOME="$TMP_ROOT/primary-home"
mkdir -p "$PRIMARY_HOME/state" "$PRIMARY_HOME/data/jg-cm1" "$PRIMARY_HOME/config"
printf 'off\n' > "$PRIMARY_HOME/config/herdr-presentation-spaces"
cat > "$PRIMARY_HOME/data/jg-cm1/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise primary-home Herdr placement.

## Juggernaut spec
Verify the operator uses its primary home's workspace.
EOF
herdr_test_backlog_ticket "$PRIMARY_HOME" jg-cm1 || fail "could not file the fixture ticket for jg-cm1"

SM_HOME="$TMP_ROOT/squad-lead-home"
mkdir -p "$SM_HOME/state" "$SM_HOME/data/jg-cm2" "$SM_HOME/config" "$SM_HOME/projects" "$SM_HOME/bin"
printf 'off\n' > "$SM_HOME/config/herdr-presentation-spaces"
printf '# scratch squad_lead home AGENTS.md placeholder\n' > "$SM_HOME/AGENTS.md"
printf 'e2esm1\n' > "$SM_HOME/.jg-squad-lead-home"
printf 'trivial e2e squad_lead charter: nothing to do.\n' > "$SM_HOME/data/charter.md"
printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$SM_HOME/.gitignore"
git -C "$SM_HOME" init -q -b main
cat > "$SM_HOME/data/jg-cm2/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise squad-lead-owned Herdr placement.

## Juggernaut spec
Verify the operator uses its squad_lead home's workspace.
EOF
herdr_test_backlog_ticket "$SM_HOME" jg-cm2 || fail "could not file the fixture ticket for jg-cm2"

make_scratch_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# scratch\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Juggernaut Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}

PROJ1="$TMP_ROOT/scratch-project-1"; make_scratch_project "$PROJ1"
PROJ2="$TMP_ROOT/scratch-project-2"; make_scratch_project "$PROJ2"

# --- 1. primary-shaped home: a operator spawns into the "juggernaut" space ---

CM1_OUT="$TMP_ROOT/jg-cm1.out"; CM1_ERR="$TMP_ROOT/jg-cm1.err"
JG_SPAWN_NO_GUARD=1 JG_HOME="$PRIMARY_HOME" JG_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/jg-spawn.sh" jg-cm1 "$PROJ1" "sh -c 'echo primary-crew-ok'" --mode no-mistakes --yolo off --ticket jg-cm1 --backend herdr \
  >"$CM1_OUT" 2>"$CM1_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "primary-shaped operator spawn failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM1_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM1_ERR")"

CM1_META="$PRIMARY_HOME/state/jg-cm1.meta"
[ -f "$CM1_META" ] || fail "no meta written for jg-cm1"
assert_contains_local "$(cat "$CM1_META")" "backend=herdr" "jg-cm1 meta missing backend=herdr"
WT1=$(grep '^worktree=' "$CM1_META" | cut -d= -f2-)
CM1_PANE=$(grep '^herdr_pane_id=' "$CM1_META" | cut -d= -f2-)
[ -n "$CM1_PANE" ] || fail "jg-cm1 meta missing herdr_pane_id"
pass "real herdr E2E: a primary-shaped home spawns a operator on the herdr backend"

sleep 1
CM1_CAPTURE=$(jg_backend_herdr_capture "$SESSION:$CM1_PANE" 30) || fail "capture failed on jg-cm1's pane"
assert_contains_local "$CM1_CAPTURE" "primary-crew-ok" "jg-cm1's raw launch command did not run in its herdr pane"

CM1_WSID=$(herdr pane get "$CM1_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$CM1_WSID" ] || fail "could not read jg-cm1's pane workspace_id"
CM1_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$CM1_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$CM1_WS_LABEL" = "juggernaut" ] || fail "a primary-shaped home's operator should land in the 'juggernaut' workspace, got '$CM1_WS_LABEL'"
pass "real herdr E2E: the primary-shaped home's operator landed in the 'juggernaut' workspace"

# --- 2. the PRIMARY spawns a squad_lead: its tab lands in the SQUAD_LEAD's own space ---
# (jg-spawn.sh's herdr case arm shadows JG_HOME to the squad_lead's home for
# exactly this call - AGENTS.md task herdr-sm-spaces-k4, requirement 3.)

SM_OUT="$TMP_ROOT/sm.out"; SM_ERR="$TMP_ROOT/sm.err"
JG_SPAWN_NO_GUARD=1 JG_HOME="$PRIMARY_HOME" JG_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/jg-spawn.sh" e2esm1 "$SM_HOME" "sh -c 'echo squad-lead-launch-ok'" --squad-lead --backend herdr \
  >"$SM_OUT" 2>"$SM_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "the primary's --squad-lead spawn of e2esm1 failed"$'\n'"--- stdout ---"$'\n'"$(cat "$SM_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$SM_ERR")"

SM_META="$PRIMARY_HOME/state/e2esm1.meta"
[ -f "$SM_META" ] || fail "no meta written for e2esm1 (recorded in the PRIMARY's own state dir, since the primary did the spawning)"
assert_contains_local "$(cat "$SM_META")" "kind=squad_lead" "e2esm1 meta missing kind=squad_lead"
assert_contains_local "$(cat "$SM_META")" "backend=herdr" "e2esm1 meta missing backend=herdr"
assert_contains_local "$(cat "$SM_META")" "home=$SM_HOME" "e2esm1 meta does not record its own home"
SM_PANE=$(grep '^herdr_pane_id=' "$SM_META" | cut -d= -f2-)
[ -n "$SM_PANE" ] || fail "e2esm1 meta missing herdr_pane_id"
pass "real herdr E2E: the primary spawns a --squad-lead task on the herdr backend"

SM_WSID=$(herdr pane get "$SM_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$SM_WSID" ] || fail "could not read e2esm1's pane workspace_id"
[ "$SM_WSID" != "$CM1_WSID" ] || fail "the squad_lead's tab must NOT land in the primary's workspace, but it shares $CM1_WSID"
SM_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$SM_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$SM_WS_LABEL" = "lead-e2esm1" ] || fail "a --squad-lead spawn should land in 'lead-<id>', got '$SM_WS_LABEL'"
pass "real herdr E2E: a --squad-lead spawn by the PRIMARY lands in the SQUAD_LEAD's own labeled workspace, distinct from the primary's"

# --- 3. a operator spawned FROM the squad-lead-shaped home lands in the SAME
# squad_lead workspace (this exact path has never run before this test) -----

CM2_OUT="$TMP_ROOT/jg-cm2.out"; CM2_ERR="$TMP_ROOT/jg-cm2.err"
JG_SPAWN_NO_GUARD=1 JG_HOME="$SM_HOME" JG_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/jg-spawn.sh" jg-cm2 "$PROJ2" "sh -c 'echo sm-crew-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM2_OUT" 2>"$CM2_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "a operator spawned FROM the squad-lead-shaped home failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM2_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM2_ERR")"

CM2_META="$SM_HOME/state/jg-cm2.meta"
[ -f "$CM2_META" ] || fail "no meta written for jg-cm2 (recorded in the SQUAD_LEAD's own state dir - it did its own spawning)"
assert_contains_local "$(cat "$CM2_META")" "backend=herdr" "jg-cm2 meta missing backend=herdr"
WT2=$(grep '^worktree=' "$CM2_META" | cut -d= -f2-)
CM2_PANE=$(grep '^herdr_pane_id=' "$CM2_META" | cut -d= -f2-)
[ -n "$CM2_PANE" ] || fail "jg-cm2 meta missing herdr_pane_id"
pass "real herdr E2E: a operator spawns successfully FROM a squad-lead-shaped home's own jg-spawn.sh process"

sleep 1
CM2_CAPTURE=$(jg_backend_herdr_capture "$SESSION:$CM2_PANE" 30) || fail "capture failed on jg-cm2's pane"
assert_contains_local "$CM2_CAPTURE" "sm-crew-ok" "jg-cm2's raw launch command did not run in its herdr pane"

CM2_WSID=$(herdr pane get "$CM2_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ "$CM2_WSID" = "$SM_WSID" ] || fail "a operator spawned FROM the squad_lead home should land in the SAME workspace as the squad_lead's own task ($SM_WSID), got '$CM2_WSID'"
[ "$CM2_WSID" != "$CM1_WSID" ] || fail "a operator spawned FROM the squad_lead home must NOT land in the primary's workspace"
pass "real herdr E2E: a operator spawned FROM the squad-lead-shaped home lands in the squad_lead's OWN workspace - falls out of per-home resolution, no glue needed"

# --- 4. list-live recovery: each home sees only its own tabs ---------------

PRIMARY_LIVE=$(JG_HOME="$PRIMARY_HOME" jg_backend_herdr_list_live "$SESSION")
assert_contains_local "$PRIMARY_LIVE" "jg-jg-cm1" "the primary home's list_live did not see its own task"
assert_not_contains_local "$PRIMARY_LIVE" "jg-e2esm1" "the primary home's list_live must not see the squad_lead's own task"
assert_not_contains_local "$PRIMARY_LIVE" "jg-jg-cm2" "the primary home's list_live must not see the squad-lead-owned operator's task"
pass "real herdr E2E: list_live from the primary's own context sees only the primary's own task"

SM_LIVE=$(JG_HOME="$SM_HOME" jg_backend_herdr_list_live "$SESSION")
assert_contains_local "$SM_LIVE" "jg-e2esm1" "the squad_lead home's list_live did not see its own task"
assert_contains_local "$SM_LIVE" "jg-jg-cm2" "the squad_lead home's list_live did not see the operator spawned from it"
assert_not_contains_local "$SM_LIVE" "jg-jg-cm1" "the squad_lead home's list_live must not see the primary's task"
pass "real herdr E2E: list_live from the squad_lead's own context sees only tasks in the squad_lead's own workspace (both its own tab and its operator's)"

# --- 5. teardown closes the RIGHT tab, and no other ------------------------

TD1_OUT="$TMP_ROOT/td1.out"
JG_ROOT_OVERRIDE="$ROOT" JG_STATE_OVERRIDE="$PRIMARY_HOME/state" JG_DATA_OVERRIDE="$PRIMARY_HOME/data" \
  JG_CONFIG_OVERRIDE="$PRIMARY_HOME/config" \
  "$ROOT/bin/jg-teardown.sh" jg-cm1 >"$TD1_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "jg-teardown.sh failed for the primary-shaped operator jg-cm1"$'\n'"$(cat "$TD1_OUT")"
[ -f "$CM1_META" ] && fail "jg-teardown.sh did not remove jg-cm1's meta"
if herdr pane get "$CM1_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "jg-teardown.sh did not close jg-cm1's pane"
fi
if ! herdr pane get "$SM_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down jg-cm1 must not have closed the squad_lead's OWN pane (wrong tab closed)"
fi
if ! herdr pane get "$CM2_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down jg-cm1 must not have closed jg-cm2's pane (wrong tab closed)"
fi
WT1=
pass "real herdr E2E: tearing down jg-cm1 closes only its own tab - the squad_lead's and jg-cm2's tabs survive untouched"

TD2_OUT="$TMP_ROOT/td2.out"
JG_ROOT_OVERRIDE="$ROOT" JG_STATE_OVERRIDE="$SM_HOME/state" JG_DATA_OVERRIDE="$SM_HOME/data" \
  JG_CONFIG_OVERRIDE="$SM_HOME/config" \
  "$ROOT/bin/jg-teardown.sh" jg-cm2 >"$TD2_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "jg-teardown.sh failed for the squad-lead-owned operator jg-cm2"$'\n'"$(cat "$TD2_OUT")"
[ -f "$CM2_META" ] && fail "jg-teardown.sh did not remove jg-cm2's meta"
if herdr pane get "$CM2_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "jg-teardown.sh did not close jg-cm2's pane"
fi
if ! herdr pane get "$SM_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down jg-cm2 must not have closed the squad_lead's OWN pane (wrong tab closed)"
fi
WT2=
pass "real herdr E2E: tearing down jg-cm2 closes only its own tab - the squad_lead's own tab (same workspace) survives untouched"

jg_backend_herdr_kill "$SESSION:$SM_PANE"

cleanup_all
trap - EXIT

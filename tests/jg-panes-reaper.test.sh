#!/usr/bin/env bash
# tests/jg-panes-reaper.test.sh - the panes reaper (core/tmp-reaper/panes.sh, armed by core/tmp-reaper/wiring.sh) closes a
# shell pane that no task record owns once it has stood idle past its limit, in a workspace that a record of the home
# names, and touches no other pane: not an owned pane, not a pane that runs something, not a pane of a workspace no record
# names, not a pane of a child home's workspace. Runs against a REAL Herdr server in its own named lab session, driven only
# through bin/jg-herdr-lab.sh (never the default session).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

LAB=$ROOT/bin/jg-herdr-lab.sh
SESSION=$("$LAB" name panes-reaper) || fail "could not name a lab session"
TMP_ROOT=$(jg_test_tmproot jg-panes-reaper)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
cleanup() { herdr_safe_stop_and_delete "$SESSION" >/dev/null 2>&1; }
trap cleanup EXIT
"$LAB" provision "$SESSION" >/dev/null 2>&1 || fail "could not provision the lab session"
jg_herdr_lab_runtime_env "$SESSION" || fail "could not enter the lab runtime"
hd() { "$LAB" run "$SESSION" "$@"; }

H=$TMP_ROOT/home
mkdir -p "$H/state" "$H/config" "$H/bin"
for f in "$ROOT"/bin/*; do ln -s "$f" "$H/bin/${f##*/}"; done
ln -sn "$ROOT/core" "$H/core"   # the herdr answer reader (core/herdr) is built from the home's own tree
# shellcheck disable=SC2031 # shellcheck reads the lab provisioning below as a subshell; this home is the test's own.
export JG_HOME=$H
unset JG_STATE_OVERRIDE
export JG_PANE_REAPER_LIMIT_SEC=60
# The clock is a file of the first-seen epoch: the test moves it back to pass the limit without a sleep.
age_clocks() { local f; for f in "$H"/state/orphan-panes/"$SESSION"/*.seen; do [ -f "$f" ] && printf '%s\n' $(( $(date +%s) - $1 )) > "$f"; done; }

# A workspace and a split pane in it: ids are read from Herdr's own answers.
workspace() { hd workspace create --label "$1" --no-focus | jq -r '.result.root_pane.workspace_id + " " + .result.root_pane.pane_id + " " + .result.root_pane.tab_id'; }
split() { hd pane split "$1" --direction down --no-focus | jq -r '.result.pane.pane_id'; }
has_pane() { hd pane list | jq -e --arg p "$1" '.result.panes | any(.pane_id == $p)' >/dev/null; }
meta() {  # <id> <kind> <workspace> <tab> <pane>
  printf 'backend=herdr\nkind=%s\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' \
    "$2" "$SESSION" "$3" "$4" "$5" > "$H/state/$1.meta"
}

# The fleet's workspace (a record names it and its root pane), a workspace no record names, and a child home's workspace.
read -r FW FROOT FTAB <<< "$(workspace fleet)"
read -r OW OROOT _ <<< "$(workspace other)"
read -r CW CROOT CTAB <<< "$(workspace child)"
[ -n "$FW" ] && [ -n "$OW" ] && [ -n "$CW" ] || fail "the lab workspaces were not created"
meta t-owned ship "$FW" "$FTAB" "$FROOT"
meta t-child squad_lead "$CW" "$CTAB" "$CROOT"
ORPHAN=$(split "$FROOT")          # fleet workspace, no record, an idle shell: the one to close
BUSY=$(split "$FROOT")            # fleet workspace, no record, runs a command: never closed
STRANGER=$(split "$OROOT")        # a workspace no record names
CHILD_EXTRA=$(split "$CROOT")     # a workspace that a squad_lead record names: that home's to reap
for p in "$ORPHAN" "$BUSY" "$STRANGER" "$CHILD_EXTRA"; do [ -n "$p" ] || fail "a lab pane was not created"; done
hd pane run "$BUSY" "sleep 600" >/dev/null || fail "could not start the command in the busy pane"
sleep 1

env -u JG_STATE_OVERRIDE bash "$ROOT/core/tmp-reaper/wiring.sh" "$H" >/dev/null 2>&1 || fail "wiring did not arm the checks"
CHECK=$H/state/panes-reaper.check.sh
[ -x "$CHECK" ] || fail "wiring left no state/panes-reaper.check.sh"
tick() { bash "$CHECK"; }

# 1. Inside its limit the orphan stays and is named; the clock starts.
tick
has_pane "$ORPHAN" || fail "an orphan inside its limit was closed"
out=$(bash "$ROOT/core/tmp-reaper/panes.sh" list "$H")
case $out in *"orphan $SESSION $ORPHAN $FW "*) ;; *) fail "the orphan was not named: $out" ;; esac
case $out in *"$BUSY"*|*"$STRANGER"*|*"$CHILD_EXTRA"*|*"$FROOT"*) fail "list named a pane that is not an orphan: $out" ;; esac
pass "an orphan shell inside its limit is named and kept"

# 2. A dry run past the limit closes nothing.
age_clocks 120
out=$(bash "$ROOT/core/tmp-reaper/panes.sh" --dry-run check "$H")
case $out in *"would close $SESSION $ORPHAN"*) ;; *) fail "the dry run did not name the pane: $out" ;; esac
has_pane "$ORPHAN" || fail "a dry run closed a pane"
pass "a dry run names the pane and closes nothing"

# 3. Past its limit the orphan is closed and every other pane is left.
tick
has_pane "$ORPHAN" && fail "the orphan was still open past its limit"
for p in "$FROOT" "$BUSY" "$OROOT" "$STRANGER" "$CROOT" "$CHILD_EXTRA"; do has_pane "$p" || fail "pane $p was closed and is not an orphan"; done
assert_grep "closed $SESSION $ORPHAN workspace=$FW" "$H/state/panes-reaper.log" "the close was not logged"
ls "$H"/state/orphan-panes/"$SESSION"/*.seen >/dev/null 2>&1 && fail "the clock of a closed pane was kept"
pass "an orphan past its limit is closed; owned, busy, other-workspace and child-home panes are untouched"

# 4. A pane that runs a command has no clock; once idle it has one, and a task record that names it ends that clock.
tick
ls "$H"/state/orphan-panes/"$SESSION"/*.seen >/dev/null 2>&1 && fail "a pane that runs a command got a clock"
hd pane send-keys "$BUSY" C-c >/dev/null 2>&1
for _ in $(seq 40); do tick; ls "$H"/state/orphan-panes/"$SESSION"/*.seen >/dev/null 2>&1 && break; sleep 0.25; done
ls "$H"/state/orphan-panes/"$SESSION"/*.seen >/dev/null 2>&1 || fail "a pane that went idle got no clock"
meta t-claim ship "$FW" "$FTAB" "$BUSY"
age_clocks 120; tick
has_pane "$BUSY" || fail "a pane with a task record was closed"
ls "$H"/state/orphan-panes/"$SESSION"/*.seen >/dev/null 2>&1 && fail "the clock of a pane that got a record was kept"
pass "a pane that runs a command or has a task record is never closed"

# 5. A session that cannot be read changes nothing and reports nothing.
printf 'backend=herdr\nkind=ship\nherdr_session=jg-lab-nobody-home\nherdr_workspace_id=w9\nherdr_tab_id=w9:t1\nherdr_pane_id=w9:p1\n' > "$H/state/t-lost.meta"
out=$(tick 2>&1); [ -z "$out" ] || fail "a check with an unreadable session printed: $out"
pass "an unreadable session is skipped silently"

env -u JG_STATE_OVERRIDE bash "$ROOT/core/tmp-reaper/unwiring.sh" "$H" >/dev/null 2>&1 || fail "unwiring failed"
[ ! -e "$CHECK" ] || fail "unwiring left the panes check"
pass "unwiring removes the panes check"

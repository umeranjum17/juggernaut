#!/usr/bin/env bash
# tests/jg-tmp-reaper.test.sh - jg-* scratch never piles up in the temp directory:
# a signalled script removes its own scratch, the heartbeat cycle leaves the entry count flat,
# and bin/jg-tmp-reaper.sh removes what no trap could (bin/jg-tmp-reaper.sh, bin/jg-timeout-lib.sh).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-tmp-reaper)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
REAPER="$ROOT/bin/jg-tmp-reaper.sh"
HOME_DIR=$TMP_ROOT/home
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"

count() { find "$1" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '; }

# --- the reaper ---------------------------------------------------------------
T=$TMP_ROOT/reap-tmp
mkdir -p "$T/jg-old-dir" "$T/jg-young" "$T/keep-old" "$T/jg-in-use" "$T/jg-readonly/sub" "$T/outside"
: > "$T/jg-old-dir/f"; : > "$T/jg-old-file"; : > "$T/jg-young/f"; : > "$T/keep-old/f"; : > "$T/jg-in-use/f"
: > "$T/jg-readonly/sub/f"; : > "$T/outside/f"
ln -s "$T/outside" "$T/jg-old-link"
for p in jg-old-dir keep-old jg-in-use outside jg-readonly/sub; do touch -d '3 hours ago' "$T/$p/f"; done
for p in jg-old-dir jg-old-file keep-old jg-in-use jg-readonly/sub jg-readonly outside; do touch -d '3 hours ago' "$T/$p"; done
chmod 555 "$T/jg-readonly/sub" "$T/jg-readonly"
touch -h -d '3 hours ago' "$T/jg-old-link"
touch -d '3 hours ago' "$T/jg-old-dir"
# A process whose working directory is inside the old tree keeps it.
bash -c 'cd "$1" && exec sleep 600' _ "$T/jg-in-use" </dev/null >/dev/null 2>&1 &
HOLDER=$!
sleep 0.5

out=$(TMPDIR=$T JG_HOME=$HOME_DIR JG_TMP_ALERT_PCT=100 "$REAPER" check 2>&1)
[ -z "$out" ] || fail "reaper check below the alert level printed: $out"
assert_absent "$T/jg-old-dir" "an old unused jg- directory was kept"
assert_absent "$T/jg-old-file" "an old unused jg- file was kept"
assert_absent "$T/jg-readonly" "a read-only jg- tree was kept"
assert_present "$T/jg-young" "a young jg- directory was removed"
assert_present "$T/keep-old" "an old entry without the jg- prefix was removed"
assert_present "$T/jg-in-use" "a tree a live process works in was removed"
assert_present "$T/jg-old-link" "a symlink was removed or followed"
assert_present "$T/outside/f" "the reaper followed a symlink"
assert_grep "reaped $T/jg-old-dir" "$HOME_DIR/state/tmp-reaper.log" "the removal was not logged"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
out=$(TMPDIR=$T JG_HOME=$HOME_DIR JG_TMP_ALERT_PCT=100 "$REAPER" check 2>&1)
assert_absent "$T/jg-in-use" "a released old tree was kept"
pass "reaper removes only old, unused, own jg-* entries"

# --- a task temp root is never reaped ---------------------------------------------
# /tmp/jg-<task-id>/gotmp is Go's build temp; Go will not recreate it, so an old, empty, unheld root must stay.
R=$TMP_ROOT/root-tmp
HASH=$(printf 'a%.0s' $(seq 1 64))
mkdir -p "$R/jg-task-a/gotmp" "$R/jg-task-b+$HASH" "$R/jg-task-c" "$R/jg-plain-leak"
: > "$HOME_DIR/state/task-c.meta"
for p in jg-task-a/gotmp jg-task-a "jg-task-b+$HASH" jg-task-c jg-plain-leak; do touch -d '3 hours ago' "$R/$p"; done
TMPDIR=$R JG_HOME=$HOME_DIR JG_TMP_ALERT_PCT=100 "$REAPER" check >/dev/null 2>&1
assert_present "$R/jg-task-a/gotmp" "the reaper removed a live task's GOTMPDIR"
assert_present "$R/jg-task-b+$HASH" "the reaper removed a task's launch root"
assert_present "$R/jg-task-c" "the reaper removed the root of a task with a state record"
assert_absent "$R/jg-plain-leak" "the reaper kept a plain old jg- entry"
pass "reaper never removes a task temp root"

# --- the alert ----------------------------------------------------------------
out=$(TMPDIR=$T JG_HOME=$HOME_DIR JG_TMP_ALERT_PCT=1 "$REAPER" check 2>&1)
assert_contains "$out" "is " "no alert at the threshold"
assert_contains "$out" "% full" "the alert does not name the use"
out=$(TMPDIR=$T JG_HOME=$HOME_DIR JG_TMP_ALERT_PCT=1 "$REAPER" check 2>&1)
[ -z "$out" ] || fail "the alert repeated while use stayed over the threshold: $out"
TMPDIR=$T JG_HOME=$HOME_DIR JG_TMP_ALERT_PCT=101 "$REAPER" check >/dev/null 2>&1
out=$(TMPDIR=$T JG_HOME=$HOME_DIR JG_TMP_ALERT_PCT=1 "$REAPER" check 2>&1)
assert_contains "$out" "% full" "the alert did not fire again after use dropped"
pass "alert fires once per crossing"

# --- a signalled script leaves nothing -----------------------------------------
# Run the command in its own session so TERM reaches the whole group, as the watcher's per-check kill does.
signalled_leaves_nothing() {  # <label> <env assignment or ''> <script text> <wait glob>
  local label=$1 d=$TMP_ROOT/sig-$1 pid
  mkdir -p "$d"
  # shellcheck disable=SC2086
  env TMPDIR=$d JG_HOME=$HOME_DIR JG_STATE_OVERRIDE=$HOME_DIR/state JG_DATA_OVERRIDE=$HOME_DIR/data \
    JG_CONFIG_OVERRIDE=$HOME_DIR/config PATH=$TMP_ROOT/shim:$PATH $2 setsid bash -c "$3" >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do
    compgen -G "$d/$4" >/dev/null && break
    sleep 0.1
  done
  compgen -G "$d/$4" >/dev/null || fail "$label: the script never made its scratch ($4)"
  kill -TERM -- "-$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  # A descendant that left the group (the crew-state read) finishes its own bounded call and cleans up itself.
  for _ in $(seq 1 50); do [ "$(count "$d")" = 0 ] && break; sleep 0.1; done
  [ "$(count "$d")" = 0 ] || fail "$label: TERM left $(find "$d" -mindepth 1 | tr '\n' ' ')"
  pass "$label: TERM leaves no scratch"
}

signalled_leaves_nothing timeout-lib '' ". '$ROOT/bin/jg-timeout-lib.sh'; jg_run_timed 60 sleep 60" 'jg-timeout-status.*'
signalled_leaves_nothing timeout-lib-bash JG_TIMEOUT_MECHANISM_OVERRIDE=bash \
  ". '$ROOT/bin/jg-timeout-lib.sh'; jg_run_timed 60 sleep 60" 'jg-bash-timeout-command.*'

# The snapshot is held after its transport directory exists by a jq that sleeps on the first --slurpfile call.
mkdir -p "$TMP_ROOT/shim"
REAL_JQ=$(command -v jq)
printf '#!/usr/bin/env bash\ncase " $* " in *" --slurpfile "*) sleep 60 ;; esac\nexec %q "$@"\n' "$REAL_JQ" > "$TMP_ROOT/shim/jq"
chmod +x "$TMP_ROOT/shim/jq"
signalled_leaves_nothing fleet-snapshot '' "exec '$ROOT/bin/jg-fleet-snapshot.sh' --json" 'jg-fleet-*'

# --- the heartbeat cycle leaves the entry count flat ----------------------------
F=$TMP_ROOT/flat-tmp
mkdir -p "$F"
rm -f "$TMP_ROOT/shim/jq"
cycle() {
  # shellcheck disable=SC2016  # The script text expands inside the child shell.
  env TMPDIR="$F" JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$HOME_DIR/state" JG_DATA_OVERRIDE="$HOME_DIR/data" \
    JG_CONFIG_OVERRIDE="$HOME_DIR/config" JG_TMP_ALERT_PCT=100 bash -c '
      . "$1/bin/jg-timeout-lib.sh"
      "$1/bin/jg-fleet-heartbeat.sh" check
      "$1/bin/jg-fleet-snapshot.sh" --json >/dev/null
      jg_run_timed 20 true
      JG_MAIL_CHECK_BUDGET=5 "$1/bin/jg-mail-check.sh" check
      "$1/bin/jg-tmp-reaper.sh" check' _ "$ROOT" >/dev/null 2>&1
}
cycle
before=$(count "$F")
for _ in $(seq 1 50); do cycle; done
after=$(count "$F")
assert_equals "$before" "$after" "the temp entry count grew over 50 heartbeat cycles"
[ "$after" = 0 ] || fail "the heartbeat cycle left $after entries: $(find "$F" -mindepth 1 | tr '\n' ' ')"
pass "50 heartbeat cycles leave the temp directory flat at $after entries"



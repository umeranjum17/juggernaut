#!/usr/bin/env bash
# tests/jg-tmp-reaper.test.sh - jg-* scratch never piles up in the temp directory:
# a signalled script removes its own scratch, the heartbeat cycle leaves the entry count flat,
# and bin/jg-tmp-reaper.sh removes what no trap could (bin/jg-tmp-reaper.sh, bin/jg-tmp-sandbox-lib.sh, bin/jg-timeout-lib.sh).
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

# --- a test sandbox older than its timeout is stopped and removed ---------------------
# jg-trunk.* and tmp.* roots holding a trunk-landing tree: the old one (its own 1 s timeout) loses its process and folder,
# the fresh one (default timeout) is untouched, and a live task root, a sandbox with a task-meta process and a plain tmp.* are untouched.
SB=$TMP_ROOT/sandbox-tmp
mkdir -p "$SB"
mk_sandbox() {  # <name>
  mkdir -p "$SB/$1/world/root/bin"
  : > "$SB/$1/world/root/bin/jg-trunk.sh"
}
mk_sandbox jg-trunk.old; printf '1\n' > "$SB/jg-trunk.old/.jg-sandbox-timeout"
mk_sandbox tmp.oldtmp; printf '1\n' > "$SB/tmp.oldtmp/.jg-sandbox-timeout"
mk_sandbox jg-trunk.fresh
mk_sandbox tmp.taskproc; printf '1\n' > "$SB/tmp.taskproc/.jg-sandbox-timeout"
mk_sandbox jg-livetask; printf '1\n' > "$SB/jg-livetask/.jg-sandbox-timeout"; mkdir -p "$SB/jg-livetask/gotmp"
mk_sandbox tmp.named; printf '1\n' > "$SB/tmp.named/.jg-sandbox-timeout"
mkdir -p "$SB/tmp.plain"; : > "$SB/tmp.plain/f"; printf '1\n' > "$SB/tmp.plain/.jg-sandbox-timeout"
: > "$HOME_DIR/state/sb-task.meta"
printf 'worktree=%s\n' "$SB/tmp.named" > "$HOME_DIR/state/sb-named.meta"
for d in jg-trunk.old tmp.oldtmp jg-trunk.fresh tmp.taskproc jg-livetask tmp.named tmp.plain; do
  touch -d '3 hours ago' "$SB/$d/world/root/bin/jg-trunk.sh" "$SB/$d/.jg-sandbox-timeout" 2>/dev/null
done
sb_hold() {  # <dir> [task id]: a process working in <dir>; its pid in SB_PID
  JG_TASK_ID=${2:-} bash -c 'cd "$1" && exec sleep 600' _ "$1" </dev/null >/dev/null 2>&1 &
  SB_PID=$!
  # On a loaded host the shell may not have reached its directory yet: wait until the process works in it.
  local n=0
  until [ "$(readlink "/proc/$SB_PID/cwd" 2>/dev/null)" = "$1" ] && [ "$(tr '\0' ' ' < "/proc/$SB_PID/cmdline" 2>/dev/null)" = "sleep 600 " ]; do
    n=$((n + 1)); [ "$n" -lt 200 ] || break; sleep 0.05
  done
}
sb_hold "$SB/jg-trunk.old"; P_OLD=$SB_PID
sb_hold "$SB/tmp.oldtmp"; P_OLDTMP=$SB_PID
sb_hold "$SB/jg-trunk.fresh"; P_FRESH=$SB_PID
sb_hold "$SB/tmp.taskproc" sb-task; P_TASK=$SB_PID
sb_hold "$SB/jg-livetask"; P_LIVE=$SB_PID
sb_hold "$SB/tmp.named"; P_NAMED=$SB_PID
sb_hold "$SB/tmp.plain"; P_PLAIN=$SB_PID
sleep 2.2
TMPDIR=$SB JG_HOME=$HOME_DIR JG_TMP_SANDBOX_GRACE_SEC=1 JG_TMP_ALERT_PCT=100 "$REAPER" check >/dev/null 2>&1
assert_absent "$SB/jg-trunk.old" "an old jg-trunk.* sandbox was kept"
assert_absent "$SB/tmp.oldtmp" "an old tmp.* sandbox was kept"
assert_present "$SB/jg-trunk.fresh" "a fresh sandbox was removed"
assert_present "$SB/tmp.taskproc" "a sandbox with a task-meta process was removed"
assert_present "$SB/jg-livetask" "a live task root was removed"
assert_present "$SB/tmp.named" "a folder a task meta names was removed"
assert_present "$SB/tmp.plain" "a tmp.* entry without a trunk-landing tree was removed"
alive() { local st; st=$(ps -o stat= -p "$1" 2>/dev/null | tr -d " "); [ -n "$st" ] && [ "${st%"${st#?}"}" != Z ]; }
alive "$P_OLD" && fail "the old sandbox's process kept running"
alive "$P_OLDTMP" && fail "the old tmp.* sandbox's process kept running"
alive "$P_FRESH" || fail "a fresh sandbox's process was stopped"
alive "$P_TASK" || fail "a task-meta process was stopped"
alive "$P_LIVE" || fail "a live task root's process was stopped"
alive "$P_NAMED" || fail "a process in a task-named folder was stopped"
alive "$P_PLAIN" || fail "a process in a plain tmp.* entry was stopped"
assert_grep "sandbox-reaped $SB/jg-trunk.old" "$HOME_DIR/state/tmp-reaper.log" "the sandbox removal was not logged"
for pid in "$P_FRESH" "$P_TASK" "$P_LIVE" "$P_NAMED" "$P_PLAIN"; do kill "$pid" 2>/dev/null; done
wait 2>/dev/null
pass "reaper stops and removes only test sandboxes older than their timeout"

# --- a stranger's task process never protects a sandbox --------------------------------
# The holder scan once overwrote its sandbox-path argument with the stat fields of the first holder it found, so a later
# process of any task (here: one with a recorded task meta and a bare "S" argument) was read as a holder of the sandbox.
mk_sandbox jg-trunk.stranger; printf '1\n' > "$SB/jg-trunk.stranger/.jg-sandbox-timeout"
touch -d '3 hours ago' "$SB/jg-trunk.stranger/world/root/bin/jg-trunk.sh" "$SB/jg-trunk.stranger/.jg-sandbox-timeout"
sb_hold "$SB/jg-trunk.stranger"; P_H1=$SB_PID
JG_TASK_ID=sb-task bash -c 'exec sleep 600' _ S </dev/null >/dev/null 2>&1 & P_D1=$!
sb_hold "$SB/jg-trunk.stranger"; P_H2=$SB_PID
JG_TASK_ID=sb-task bash -c 'exec sleep 600' _ S </dev/null >/dev/null 2>&1 & P_D2=$!
sleep 2.2
TMPDIR=$SB JG_HOME=$HOME_DIR JG_TMP_SANDBOX_GRACE_SEC=1 JG_TMP_ALERT_PCT=100 "$REAPER" check >/dev/null 2>&1
assert_absent "$SB/jg-trunk.stranger" "a task process that does not work in the sandbox kept it"
alive "$P_H1" && fail "the sandbox's first process kept running"
alive "$P_H2" && fail "the sandbox's second process kept running"
alive "$P_D1" || fail "a stranger's task process was stopped"
for pid in "$P_D1" "$P_D2"; do kill "$pid" 2>/dev/null; done
wait 2>/dev/null
pass "a stranger's task process does not keep an old sandbox"

# --- the alert ----------------------------------------------------------------
out=$(TMPDIR=$T JG_HOME=$HOME_DIR JG_TMP_ALERT_PCT=1 "$REAPER" check 2>&1)
assert_contains "$out" "is " "no alert at the threshold"
assert_contains "$out" "% full" "the alert does not name the use"
assert_contains "$out" "alert host (P3)" "the line is not the host alert"
assert_grep 'state=open' "$HOME_DIR/state/alerts/host--tmp-reaper.rec" "the crossing recorded no open host alert"
out=$(TMPDIR=$T JG_HOME=$HOME_DIR JG_TMP_ALERT_PCT=1 "$REAPER" check 2>&1)
[ -z "$out" ] || fail "the alert repeated while use stayed over the threshold: $out"
TMPDIR=$T JG_HOME=$HOME_DIR JG_TMP_ALERT_PCT=101 "$REAPER" check >/dev/null 2>&1
assert_grep 'state=resolved' "$HOME_DIR/state/alerts/host--tmp-reaper.rec" "use back under the threshold left the host alert open"
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
  # Poll for that end - up to 30 s, leaving the moment the scratch is gone - not a fixed time a loaded host overruns.
  for _ in $(seq 1 300); do [ "$(count "$d")" = 0 ] && break; sleep 0.1; done
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



# --- leaked test processes ------------------------------------------------------
# The reaper stops a process a test started (it carries JG_TEST_FIXTURE_PROC) that names a jg-* path in the temp
# root and is old enough; a process without the mark, a marked one that names no jg-* path and a young one stay.
P=$TMP_ROOT/proc-tmp
mkdir -p "$P/jg-fix"
alive() { [ -d "/proc/$1" ] && ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$1/status" 2>/dev/null; }
JG_TEST_FIXTURE_PROC=4242 bash -c 'while :; do sleep 1; done' _ "$P/jg-fix" </dev/null >/dev/null 2>&1 &
LEAK=$!
JG_TEST_FIXTURE_PROC=4242 bash -c 'while :; do sleep 1; done' _ "$P/other-fix" </dev/null >/dev/null 2>&1 &
OTHER=$!
env -u JG_TEST_FIXTURE_PROC bash -c 'while :; do sleep 1; done' _ "$P/jg-fix" </dev/null >/dev/null 2>&1 &
UNMARKED=$!
sleep 2.5
proc_reap() { TMPDIR=$P JG_HOME=$HOME_DIR JG_TMP_ALERT_PCT=100 JG_TEST_PROC_GRACE_SEC=1 JG_TMP_TEST_PROC_AGE_SEC=$1 "$REAPER" check 2>&1; }
out=$(proc_reap 3600) || fail "reaper check failed with young test processes: $out"
alive "$LEAK" || fail "a test process under the age limit was stopped"
out=$(proc_reap 2) || fail "reaper check failed with old test processes: $out"
[ -z "$out" ] || fail "the process pass printed: $out"
alive "$LEAK" && fail "an old marked process naming a jg-* path was left running"
alive "$OTHER" || fail "a marked process that names no jg-* path was stopped"
alive "$UNMARKED" || fail "a process no test started was stopped"
grep -q "test-process-reaped pid $LEAK " "$HOME_DIR/state/tmp-reaper.log" || fail "the stop was not logged"
kill "$OTHER" "$UNMARKED" 2>/dev/null
pass "the reaper stops an old test process naming a jg-* path and leaves unmarked and young ones"

# A suite stops what it started when it exits, on a normal exit and on a signal, and nothing else.
JG_TEST_ROOT=$ROOT
for how in exit term; do
  pidfile=$TMP_ROOT/leak-$how.pid
  env -u JG_TEST_FIXTURE_PROC sleep 600 </dev/null >/dev/null 2>&1 &
  BY=$!
  case $how in
    exit) tail='' ;;
    term) tail='kill -TERM $$; sleep 5' ;;
  esac
  JG_TEST_SKIP_ORPHAN_REAP=1 bash -c '. "$1/tests/lib.sh"; sleep 600 </dev/null >/dev/null 2>&1 & echo $! > "$2"; '"$tail" _ "$JG_TEST_ROOT" "$pidfile" >/dev/null 2>&1
  LEFT=$(cat "$pidfile" 2>/dev/null) || fail "the $how suite did not start its process"
  alive "$LEFT" && fail "a suite left its own process running after a $how"
  alive "$BY" || fail "a suite exit stopped a process it did not start ($how)"
  kill "$BY" 2>/dev/null
done
pass "a suite stops the processes it started on exit and on a signal, and no other"

# --- host wiring arms the reaper in a home, and unwiring disarms it --------------
W=$TMP_ROOT/wired-home
mkdir -p "$W/state" "$W/data" "$W/config"
ln -sn "$ROOT/bin" "$W/bin"
env -u JG_STATE_OVERRIDE bash "$ROOT/core/tmp-reaper/wiring.sh" "$W" >/dev/null 2>&1 || fail "wiring did not arm the reaper"
env -u JG_STATE_OVERRIDE bash "$ROOT/core/tmp-reaper/wiring.sh" "$W" >/dev/null 2>&1 || fail "a second wiring run was refused"
[ -x "$W/state/tmp-reaper.check.sh" ] || fail "wiring left no state/tmp-reaper.check.sh"
env -u JG_STATE_OVERRIDE bash "$ROOT/core/tmp-reaper/unwiring.sh" "$W" >/dev/null 2>&1 || fail "unwiring failed"
[ ! -e "$W/state/tmp-reaper.check.sh" ] || fail "unwiring left the check shim"
pass "host wiring arms the reaper in a home and unwiring removes it"

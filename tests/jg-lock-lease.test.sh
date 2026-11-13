#!/usr/bin/env bash
# Tests for core/lock-lease/lock-lease.check.sh (slice H7): every trunk and landing lock has a holder record and a lease.
# Driven through the real callers: the holders take their lock with jg_lock_try_acquire (bin/jg-wake-lib.sh), the check runs as the
# tick runs it, the alert goes through bin/jg-alert.sh, and the last step takes the freed lock again the way a landing does.
#   (a) acquire writes the holder record (pid, since)         (b) a dead holder's lock is broken at once
#   (c) a live holder past the warn age: one alert names it   (d) a holder with a fresh beat is left alone
#   (e) a holder the tick did not start is never ended        (f) a tick-started holder past the end age is ended, its lock freed
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CHECK="$ROOT/core/lock-lease/lock-lease.check.sh"
TMP=$(jg_test_tmproot jg-lock-lease)
H=$TMP/home; S=$H/state
mkdir -p "$S" "$H/data" "$H/bin" "$H/core"
cp "$ROOT"/bin/*.sh "$H/bin/"; cp -R "$ROOT/core/machines" "$H/core/"
export JG_STATE_OVERRIDE=$S JG_HOME=$H JG_LOCK_LEASE_WARN_S=300 JG_LOCK_LEASE_END_S=600

# A holder script. Named like a detached landing job when $1 is trunk-landing.sh, so the check reads it as tick-started.
mk_holder() {  # <script-name> <lock>
  mkdir -p "$TMP/jobs"
  cat > "$TMP/jobs/$1" <<SH
#!/usr/bin/env bash
. "$ROOT/bin/jg-wake-lib.sh"
jg_lock_try_acquire "\$2" || exit 3
echo ready > "\$2.ready"
sleep 300
SH
}
start_holder() {  # <script-name> <lock>: prints the holder pid
  rm -f "$2.ready"
  setsid bash "$TMP/jobs/$1" run "$2" >/dev/null 2>&1 < /dev/null &
  local i=0; while [ ! -e "$2.ready" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  [ -e "$2.ready" ] || fail "holder $1 never took $2"
  cat "$2/pid"
}
run_at() { JG_LOCK_LEASE_NOW=$(( $(date +%s) + $1 )) bash "$CHECK" "$H"; }  # the check, run <n> seconds later
alive() { kill -0 "$1" 2>/dev/null && ! grep -q '^State:[[:space:]]*Z' "/proc/$1/status" 2>/dev/null; }
reap() { for p in "$@"; do kill -KILL -- "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null || true; done; }

mk_holder trunk-landing.sh x; mk_holder other-job.sh x

# (a) the holder record
L=$S/.trunk-run-a-1.lock
pid=$(start_holder trunk-landing.sh "$L")
[ -s "$L/since" ] && [ "$(cat "$L/pid")" = "$pid" ] || fail "(a) the lock holds no pid and since"
pass "(a) a lock taken through jg_lock_try_acquire records its holder pid and since"
out=$(bash "$CHECK" "$H"); [ -z "$out" ] || fail "(a) a fresh lock raised: $out"
alive "$pid" || fail "(a) a fresh holder was ended"

# (b) a dead holder: its lock is broken at once
reap "$pid"; sleep 0.3
[ -e "$L" ] || [ -L "$L" ] || fail "(b) fixture: the killed holder left no lock"
out=$(bash "$CHECK" "$H")
case $out in *"broke .trunk-run-a-1.lock"*) ;; *) fail "(b) no break line: $out" ;; esac
[ ! -e "$L" ] && [ ! -L "$L" ] || fail "(b) the dead holder's lock is still there"
pass "(b) a lock whose holder died is broken by the next check"

# (c) a live holder past the warn age: the alert names it, the lock stays
L=$S/.trunk-run-c-1.lock; pid=$(start_holder trunk-landing.sh "$L")
out=$(run_at 400); [ -z "$out" ] || fail "(c) the check ended or broke a holder inside its lease: $out"
rec=$(ls "$S"/alerts/slow-delivery--lock-trunk-run-c-1.lock.rec 2>/dev/null) || fail "(c) no alert record"
if ! grep -q "process $pid" "$rec" || ! grep -q 'lock-held' "$rec"; then fail "(c) the alert does not name the holder: $(cat "$rec")"; fi
alive "$pid" && [ "$(cat "$L/pid")" = "$pid" ] || fail "(c) the holder or its lock was touched"
pass "(c) a holder 400 s without a beat raises one alert naming its process and keeps the lock"

# (d) a fresh beat keeps the lease
L2=$S/.trunk-run-d-1.lock; pid2=$(start_holder trunk-landing.sh "$L2")
echo "$(( $(date +%s) + 880 ))" > "$L2/beat"
run_at 900 | grep -q 'd-1' && fail "(d) a holder with a fresh beat was ended"
alive "$pid2" || fail "(d) a holder with a fresh beat died"
pass "(d) a holder that beat inside its lease is left alone"
reap "$pid2"

# (e) not started by the tick: alert only, never ended
L3=$S/.trunk-run-e-1.lock; pid3=$(start_holder other-job.sh "$L3")
out=$(run_at 900); case $out in *"e-1"*) fail "(e) ended a holder the tick did not start: $out" ;; esac
alive "$pid3" || fail "(e) the holder died"
pass "(e) a holder the tick did not start is never ended, even past the end age"
reap "$pid3"

# (f) tick-started, past the end age: ended, and the next landing takes the lock
reap "$pid"; rm -rf "$L" "$S"/alerts
L=$S/.trunk-run-f-1.lock; fpid=$(start_holder trunk-landing.sh "$L")
out=$(run_at 700)
case $out in *"ended holder $fpid of .trunk-run-f-1.lock"*) ;; *) fail "(f) no end line: $out" ;; esac
alive "$fpid" && fail "(f) the holder is still alive"
[ ! -e "$L" ] && [ ! -L "$L" ] || fail "(f) the lock was not broken"
( . "$ROOT/bin/jg-wake-lib.sh"; jg_lock_try_acquire "$L" && jg_lock_release "$L" ) || fail "(f) a landing cannot take the freed lock"
pass "(f) a tick-started holder past 10 min without a beat is ended and the lock is free for the next landing"
reap "$fpid"
echo "lock-lease tests passed"

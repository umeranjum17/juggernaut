#!/usr/bin/env bash
# Integration: the sentinel records an old beacon, and the replay preserves uncertainty.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/jg-gap.XXXXXX")
trap 'rm -rf -- "$LAB"' EXIT
mkdir -p "$LAB/home/state" "$LAB/home/config" "$LAB/home/data" "$LAB/bin"
printf '#!/bin/sh\nexit 1\n' > "$LAB/bin/herdr"
chmod +x "$LAB/bin/herdr"
export PATH="$LAB/bin:$PATH" JG_HOME="$LAB/home" JG_GUARD_GRACE=30 JG_SENTINEL_TMP_SWEEP_SECS=0
export JG_STATE_OVERRIDE="$JG_HOME/state" HERDR_SESSION=jg-gap-test
unset HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_BIN_PATH
: > "$JG_HOME/state/test.meta"
touch -d '120 seconds ago' "$JG_HOME/state/.last-watcher-beat"
bash "$ROOT/bin/jg-sentinel.sh" tick > "$LAB/sentinel.out" 2>&1 || true
grep -q 'class=watcher-dead' "$JG_HOME/state/.supervision-gap" || { echo 'FAIL: sentinel did not record the dead watcher'; exit 1; }
printf 'dead watcher record: '; cat "$JG_HOME/state/.supervision-gap"
bash "$ROOT/bin/jg-sentinel.sh" tick > "$LAB/sentinel.out" 2>&1 || true
[ "$(wc -l < "$JG_HOME/state/.supervision-gap")" -eq 1 ] || { echo 'FAIL: duplicate gap'; exit 1; }
for ((i=0; i<80; i++)); do printf 'arm_pid=%s\tbeacon_age=301\tlock_before=pid:none\n' "$i"; done | bash "$ROOT/bin/jg-supervision-gap.sh" replay > "$LAB/replay"
[ "$(grep -c 'class=unknown-historical' "$LAB/replay")" -eq 80 ] || { echo 'FAIL: historical cause guessed'; exit 1; }
printf 'historical replay: 80 rows; sample: '; head -1 "$LAB/replay"
echo 'PASS: sentinel dead-watcher episode and historical replay'
# Start the real watcher in the isolated home and hold its registered check.
rm -f "$JG_HOME/state/test.meta" "$JG_HOME/state/.supervision-gap"
cat > "$JG_HOME/state/slow.check.sh" <<'SH'
#!/usr/bin/env bash
while [ ! -e "$JG_HOME/state/release-slow" ]; do sleep 0.1; done
SH
chmod 0700 "$JG_HOME/state/slow.check.sh"
export JG_WAKE_BUS_URL=nats://127.0.0.1:1 JG_STATE_BUS_URL=nats://127.0.0.1:1 JG_KV_URL=nats://127.0.0.1:1
export JG_POLL=1 JG_CHECK_INTERVAL=0 JG_CHECK_TIMEOUT=120 JG_GUARD_GRACE=30
printf 'off\n' > "$JG_HOME/config/wake-bus"
bash "$ROOT/bin/jg-check-register.sh" slow >/dev/null
bash "$ROOT/bin/jg-watch.sh" > "$LAB/watch.out" 2>&1 &
WATCH=$!
cleanup_watcher() { [ -z "${SOCK:-}" ] || kill -TERM "$SOCK" 2>/dev/null || true; kill -TERM "$WATCH" 2>/dev/null || true; wait "$WATCH" 2>/dev/null || true; rm -rf -- "$LAB"; }
trap cleanup_watcher EXIT
for ((i=0; i<300; i++)); do [ -f "$JG_HOME/state/.watch-progress" ] && grep -q 'check:slow' "$JG_HOME/state/.watch-progress" && break; sleep 0.1; done
grep -q 'check:slow' "$JG_HOME/state/.watch-progress" || { echo 'FAIL: watcher did not run the slow check'; cat "$LAB/watch.out"; exit 1; }
touch -d '120 seconds ago' "$JG_HOME/state/.last-watcher-beat" "$JG_HOME/state/.watch.lock/pid"
bash "$ROOT/bin/jg-sentinel.sh" tick > "$LAB/sentinel.out" 2>&1 || true
grep -q 'class=watcher-hung.*progress=check:slow' "$JG_HOME/state/.supervision-gap" || { echo 'FAIL: watcher progress not recorded'; cat "$LAB/sentinel.out" "$JG_HOME/state/.supervision-gap" 2>/dev/null; exit 1; }
printf 'hung watcher record: '; cat "$JG_HOME/state/.supervision-gap"
echo 'PASS: real watcher stalled in the slow check is named'
# A private socket and a status-only adapter let the real sentinel settle its
# alert without starting or controlling any Herdr server or session.
python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); time.sleep(120)' "$LAB/socket" &
SOCK=$!
for ((i=0; i<100; i++)); do [ -S "$LAB/socket" ] && break; sleep 0.1; done
cat > "$LAB/bin/herdr" <<SH
#!/bin/sh
case "\$1" in status) printf '%s\\n' '{"server":{"running":true,"socket":"$LAB/socket"}}';; *) exit 1;; esac
SH
chmod +x "$LAB/bin/herdr"
printf 'silent check sentinel-beacon-old *\nnow * * *\n' > "$LAB/routing"
JG_WAKE_ROUTING="$LAB/routing" bash "$ROOT/bin/jg-sentinel.sh" tick > "$LAB/sentinel.out" 2>&1 || true
grep -q 'Gap watcher-hung, last progress check:slow' "$JG_HOME/state/.wake-bus.events.jsonl" || { echo 'FAIL: alert did not name the gap and progress'; cat "$LAB/sentinel.out"; exit 1; }
printf 'settled alert: '; grep 'sentinel-beacon-old' "$JG_HOME/state/.wake-bus.events.jsonl"
kill -TERM "$SOCK"; wait "$SOCK" 2>/dev/null || true; SOCK=
printf '#!/bin/sh\nexit 1\n' > "$LAB/bin/herdr"
echo 'PASS: sentinel alert names the gap and progress'
# The child marker carries the real watcher's identity and an expired bound.
printf '%s %s\n' "$(( $(date +%s) - 1 ))" "$WATCH" > "$JG_HOME/state/.watcher-child"
touch -d '120 seconds ago' "$JG_HOME/state/.last-watcher-beat" "$JG_HOME/state/.watch.lock/pid"
bash "$ROOT/bin/jg-sentinel.sh" tick > "$LAB/sentinel.out" 2>&1 || true
grep -q 'class=child-overdue.*child_deadline=[0-9]' "$JG_HOME/state/.supervision-gap" || { echo 'FAIL: overdue child not recorded'; cat "$LAB/sentinel.out" "$JG_HOME/state/.supervision-gap" 2>/dev/null; exit 1; }
printf 'simulated overdue child record: '; cat "$JG_HOME/state/.supervision-gap"
echo 'PASS: the real watcher child bound is recorded'
touch "$JG_HOME/state/.last-watcher-beat"
bash "$ROOT/bin/jg-sentinel.sh" tick > "$LAB/sentinel.out" 2>&1 || true
if [ -e "$JG_HOME/state/.supervision-gap" ] || ! grep -q 'ended_at=' "$JG_HOME/state"/.supervision-gaps/*; then echo 'FAIL: recovered gap not closed'; exit 1; fi
printf 'closed episode: '; cat "$JG_HOME/state"/.supervision-gaps/*
echo 'PASS: recovery closes one episode'
# A second real arm waits for this first-scan holder. Stop the holder and let
# the sentinel identify the arm still waiting for that exact process.
export JG_WATCHER_STALL_BOUND=300 JG_GUARD_GRACE=30
touch "$JG_HOME/state/.last-watcher-beat"
bash "$ROOT/bin/jg-watch-arm.sh" > "$LAB/arm.out" 2>&1 &
ARM=$!
cleanup_all() { kill -CONT "$ARM" 2>/dev/null || true; kill -TERM "$ARM" "$WATCH" 2>/dev/null || true; wait "$ARM" 2>/dev/null || true; wait "$WATCH" 2>/dev/null || true; rm -rf -- "$LAB"; }
trap cleanup_all EXIT
for ((i=0; i<300; i++)); do [ -f "$JG_HOME/state/.watch-arms/$ARM" ] && grep -q $'\twaiting\t' "$JG_HOME/state/.watch-arms/$ARM" && break; sleep 0.1; done
grep -q $'\twaiting\t' "$JG_HOME/state/.watch-arms/$ARM" || { echo 'FAIL: real arm did not follow holder'; cat "$LAB/arm.out"; exit 1; }
kill -TERM "$WATCH"
wait "$WATCH" 2>/dev/null || true
WATCH=
export JG_GUARD_GRACE=30
touch -d '120 seconds ago' "$JG_HOME/state/.last-watcher-beat"
bash "$ROOT/bin/jg-sentinel.sh" tick > "$LAB/sentinel.out" 2>&1 || true
grep -q 'class=arm-wait-exited' "$JG_HOME/state/.supervision-gap" || { echo 'FAIL: arm waiting for exited holder not recorded'; cat "$LAB/sentinel.out" "$JG_HOME/state/.supervision-gap" 2>/dev/null; exit 1; }
printf 'arm waiting record: '; cat "$JG_HOME/state/.supervision-gap"
echo 'PASS: real arm waiting for an exited watcher is named'
# Attach a real arm to a healthy watcher, suspend that arm, and end the watcher.
kill -TERM "$ARM" 2>/dev/null || true
wait "$ARM" 2>/dev/null || true
ARM=
JG_HOME="$LAB/idle"; export JG_HOME
JG_STATE_OVERRIDE="$JG_HOME/state"; export JG_STATE_OVERRIDE
mkdir -p "$JG_HOME/state" "$JG_HOME/config" "$JG_HOME/data"
printf 'off\n' > "$JG_HOME/config/wake-bus"
cat > "$JG_HOME/state/quiet.check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod 0700 "$JG_HOME/state/quiet.check.sh"
bash "$ROOT/bin/jg-check-register.sh" quiet >/dev/null
export JG_GUARD_GRACE=30 JG_CHECK_TIMEOUT=3 JG_CHECK_INTERVAL=0
bash "$ROOT/bin/jg-watch.sh" > "$LAB/idle-watch.out" 2>&1 &
WATCH=$!
for ((i=0; i<300; i++)); do [ -f "$JG_HOME/state/.watch.lock/scan-complete" ] && break; sleep 0.1; done
[ -f "$JG_HOME/state/.watch.lock/scan-complete" ] || { echo 'FAIL: watcher did not finish its scan'; cat "$LAB/idle-watch.out"; exit 1; }
bash "$ROOT/bin/jg-watch-arm.sh" > "$LAB/idle-arm.out" 2>&1 &
ARM=$!
for ((i=0; i<300; i++)); do grep -q '^watcher: attached' "$LAB/idle-arm.out" && break; sleep 0.1; done
grep -q '^watcher: attached' "$LAB/idle-arm.out" || { echo 'FAIL: arm did not attach'; cat "$LAB/idle-arm.out"; exit 1; }
kill -STOP "$ARM"
kill -TERM "$WATCH"
wait "$WATCH" 2>/dev/null || true
WATCH=
touch -d '120 seconds ago' "$JG_HOME/state/.last-watcher-beat"
bash "$ROOT/bin/jg-sentinel.sh" tick > "$LAB/sentinel.out" 2>&1 || true
grep -q 'class=arm-idle' "$JG_HOME/state/.supervision-gap" || { echo 'FAIL: idle arm not recorded'; cat "$LAB/sentinel.out" "$JG_HOME/state/.supervision-gap" 2>/dev/null; kill -CONT "$ARM"; exit 1; }
printf 'idle arm record: '; cat "$JG_HOME/state/.supervision-gap"
kill -CONT "$ARM"
echo 'PASS: real idle arm is named'

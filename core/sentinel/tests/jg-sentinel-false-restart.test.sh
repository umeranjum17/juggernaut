#!/usr/bin/env bash
# core/sentinel/tests/jg-sentinel-false-restart.test.sh - a Herdr restart is reported, and
# the recovery pass runs, only when the session's socket identity changed since the
# sentinel's last look.
#
# Before: a pass that failed (a lane whose relaunch is refused) never recorded the new
# identity, so every tick saw the same two ids again, called it a restart and ran the
# recovery pass over every lane, every minute (ticket sentinel-false-restart).
#
# Hermetic, through the real caller (`jg-sentinel.sh tick`): a stub herdr names a socket
# file this test owns, so the identity is that socket's inode and mtime; a copy of bin/ holds a
# jg-control stand-in that counts relaunches and refuses them. The real Herdr is never read.
#   - the first look records the identity and runs no pass;
#   - the same identity again, twice, is no restart and runs no pass;
#   - a real change reports one restart and runs exactly one pass, even though its lane
#     relaunch failed; the repeat of that change runs none;
#   - a second real change runs exactly one more pass;
#   - a lane not settled yet keeps its episode's pass going each tick, with no restart
#     reported, until it settles.
#   - on a fresh Main home and one lead home, with a stepped clock, unchanged homes cost no
#     second delivery pass, a status append in the lead selects only the lead, and a missed
#     stop-detector deletion is reconciled by the lead's due repair. Passes are counted per
#     home through a fixture wrapper around the real jg-delivery-tick.sh.
set -u

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ENTRY=$REPO/core/sentinel/bin/jg-sentinel.sh
d=$(mktemp -d) || exit 1
trap 'rm -rf -- "$d"' EXIT

H=$d/home
S=$H/state
SESSION=jg-false-restart-lab

fail() {
  echo "FAIL: $*" >&2
  [ ! -f "$S/.sentinel.log" ] || tail -n 20 "$S/.sentinel.log" >&2
  exit 1
}
pass() { echo "ok: $*"; }

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

mkdir -p "$d/stub" "$d/tmproot" "$d/lab" "$d/wt" "$d/home-dir" "$H/data" "$H/config" "$S"
cp -a "$REPO/bin" "$H/bin"
ln -sn "$REPO/core" "$H/core"
: > "$d/settled"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/relaunch.log"\nexit 1\n' "$d" > "$H/bin/jg-control.sh"
# No lane is an open captain call; the hold record needs a Beads store this test has no use for.
printf '#!/usr/bin/env bash\nexit 1\n' > "$H/bin/jg-captain-hold.sh"
chmod +x "$H/bin/jg-control.sh" "$H/bin/jg-captain-hold.sh"

# The stub herdr reports the socket file named in $d/sock; its agent reads dead once
# $d/settled exists and unreadable without it.
cat > "$d/stub/herdr" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" status "*) printf '{"server":{"running":true,"socket":"%s"}}\n' "\$(cat '$d/sock')" ;;
  *" pane get "*) [ -e '$d/settled' ] || exit 1; printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1"}}}' ;;
  *" agent get "*) [ -e '$d/settled' ] || exit 1; printf '%s\n' '{"error":{"code":"agent_not_found"}}' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$d/stub/herdr"

# socket <name> <mtime-epoch>: a new socket file for the server, made current.
socket() {
  python3 - "$d/lab/$1" <<'PY' || fail "could not bind socket $1"
import socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()
PY
  touch -d "@$2" "$d/lab/$1"
  printf '%s\n' "$d/lab/$1" > "$d/sock"
}
identity() { printf '%s:%s\n' "$(stat -c %i "$d/lab/$1")" "$2"; }

now=$(date +%s)
cat > "$S/lane.meta" <<META
window=$SESSION:w1:p1
endpoint_task_id=lane
worktree=$d/wt
project=$d/wt
harness=claude
model=claude-sonnet-5-5
kind=ship
spawn_gen=s$((now - 7200)).1.1
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=w1
herdr_tab_id=w1:t1
herdr_pane_id=w1:p1
META
printf '%s\n' "working [at=$((now - 3600))]: implementing the brief" > "$S/lane.status"

tick() {
  PATH="$d/stub:$PATH" HOME="$d/home-dir" JG_HOME=$H JG_SENTINEL_HERDR_SESSION=$SESSION \
    JG_TMP_ROOT=$d/tmproot JG_SENTINEL_TMP_SWEEP_SECS=0 JG_SENTINEL_DELIVERY_TIMEOUT=30 \
    "$ENTRY" tick >/dev/null 2>&1
}
# count <pattern> <file>: matching lines; 0 when the file is not there yet.
count() { [ -f "$2" ] || { echo 0; return; }; grep -c -- "$1" "$2" || true; }
restarts() { count ' restarted (socket ' "$S/.sentinel.log"; }
passes() { count '^lane relaunch ' "$d/relaunch.log"; }
expect() {  # <label> <restart lines> <relaunch calls>
  [ "$(restarts)" = "$2" ] || fail "$1: $(restarts) restart lines, wanted $2"
  [ "$(passes)" = "$3" ] || fail "$1: $(passes) recovery relaunches, wanted $3"
}

# First look: the identity is recorded and nothing else runs.
socket a "$((now - 5000))"
tick
[ "$(cat "$S/.sentinel-herdr-identity" 2>/dev/null)" = "$(identity a "$((now - 5000))")" ] || fail "the first look did not record the identity"
expect "first look" 0 0
pass "the first look records the identity and runs no pass"

# The same ids again, twice: no restart, no pass.
tick; tick
expect "same ids" 0 0
pass "the same socket ids twice is no restart and no recovery pass"

# A real change: one restart, one pass; the lane's relaunch is refused, which is the
# case that used to repeat every tick.
socket b "$((now - 4000))"
tick
expect "real change" 1 1
[ "$(cat "$S/.sentinel-herdr-identity")" = "$(identity b "$((now - 4000))")" ] || fail "a failed pass left the old identity recorded"
[ -s "$S/.sentinel-wake-pending" ] || fail "the restart left no wake for the primary"
pass "a real change reports one restart and runs one recovery pass, though a lane failed"

# The repeat of that change, three ticks: nothing more.
tick; tick; tick
expect "repeat after a failed pass" 1 1
pass "the repeat of a failed pass's ids is no restart and runs no pass"

# A second real change: exactly one more.
socket c "$((now - 3000))"
tick
expect "second change" 2 2
tick
expect "repeat of second change" 2 2
pass "a second real change runs exactly one more pass"

# A lane not settled yet: its episode's pass continues each tick, with no restart reported.
# The restart is recent, so the 30-minute limit is not reached.
: > "$d/relaunch.log"; rm -f "$d/settled"
socket e "$((now - 100))"
tick
expect "unsettled start" 3 0
[ -f "$S/.sentinel-herdr-unsettled" ] || fail "an unsettled lane left no episode mark"
tick
expect "unsettled continues" 3 0
[ "$(grep -c 'lane: agent unreadable; not settled' "$S/.sentinel.log")" = 2 ] || fail "the unsettled episode's pass did not continue"
: > "$d/settled"
tick
expect "settled" 3 1
[ ! -e "$S/.sentinel-herdr-unsettled" ] || fail "a settled episode kept its mark"
tick
expect "after settle" 3 1
pass "an unsettled lane continues its episode without a restart report, then settles and stops"

# Delivery passes on a fresh Main home and one lead home, on a stepped clock. Only date +%s is
# shimmed; file mtimes keep the real clock. Main is slot 0, the lead slot 1 (repair 300s).
# Main and lead share one fixture bin: the real tick sits beside a wrapper that sets the
# target home's own trace file, then runs the real tick through bash.
M=$d/main2 L=$d/lead2
MT=$M/test-delivery-trace LT=$L/test-delivery-trace
mkdir -p "$M/data" "$M/config" "$M/state" "$L/data" "$L/config" "$L/state" "$d/shim"
cp -a "$REPO/bin" "$M/bin"; ln -sn "$REPO/core" "$M/core"; ln -sn "$M/bin" "$L/bin"
mv "$M/bin/jg-delivery-tick.sh" "$M/bin/jg-delivery-tick.real.sh"
cat > "$M/bin/jg-delivery-tick.sh" <<WRAP
#!/usr/bin/env bash
# Fixture wrapper: trace per target home, then the real tick beside this file.
here=\${BASH_SOURCE[0]%/*}
home=
for a in "\$@"; do
  case "\$a" in '$M'|'$L') home=\$a; break ;; esac
done
[ -n "\$home" ] || home=\${JG_HOME:-}
JG_DELIVERY_TICK_TRACE=\$home/test-delivery-trace
export JG_DELIVERY_TICK_TRACE
exec bash "\$here/jg-delivery-tick.real.sh" "\$@"
WRAP
chmod +x "$M/bin/jg-delivery-tick.sh"
printf -- '- lead (home: %s)\n' "$L" > "$M/data/squad_leads.md"
cat > "$d/shim/date" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = +%s ] && [ -n "\${FAKE_NOW:-}" ] && { echo "\$FAKE_NOW"; exit 0; }
exec $(printf '%q' "$(command -v date)") "\$@"
SH
chmod +x "$d/shim/date"
step() {  # <epoch>: one production sentinel tick for Main at that fake time; its status is returned
  FAKE_NOW=$1 JG_SENTINEL_DELIVERY_REPAIR_SECS=300 PATH="$d/shim:$d/stub:$PATH" HOME="$d/home-dir" JG_HOME=$M \
    JG_SENTINEL_HERDR_SESSION=$SESSION JG_TMP_ROOT=$d/tmproot JG_SENTINEL_TMP_SWEEP_SECS=0 \
    JG_SENTINEL_DELIVERY_TIMEOUT=30 "$ENTRY" tick >/dev/null 2>&1
}
traced() {  # <label> <main passes> <lead passes>: real delivery trace lines per home
  [ "$(count ' pass ' "$MT")" = "$2" ] || fail "$1: Main $(count ' pass ' "$MT") delivery passes, wanted $2"
  [ "$(count ' pass ' "$LT")" = "$3" ] || fail "$1: lead $(count ' pass ' "$LT") delivery passes, wanted $3"
}
T=$(( $(date +%s) / 300 * 300 ))
step "$T" || fail "baseline: the tick did not succeed"
traced "baseline" 1 1
step "$((T + 60))" || fail "+60: the tick did not succeed"
traced "unchanged +60" 1 1
pass "unchanged Main and lead homes each cost no second delivery pass"
sleep 0.1
printf 'working [at=%s]: Umer demo\n' "$T" >> "$L/state/umer-demo.status"
step "$((T + 120))" || fail "+120: the tick did not succeed"
traced "lead status append +120" 1 2
pass "a status append in only the lead selects only the lead"
REC=$L/state/.waiting-timers/.stops/umer.test
mkdir -p "$L/state/.stops" "$L/state/.waiting-timers/.stops"
: > "$L/state/.stops/umer.test"
printf 'test\t1\t0\t0\tk\t0\t0\n' > "$REC"
rm -f "$L/state/.stops/umer.test"
step "$((T + 180))" || fail "+180: the tick did not succeed"
traced "missed deletion before repair" 1 2
[ -e "$REC" ] || fail "the stop timer record was cleared before the repair was due"
step "$((T + 240))" || fail "+240: the tick did not succeed"
traced "lead repair +240" 1 3
[ ! -e "$REC" ] || fail "the lead's due repair did not reconcile the stop timer record"
pass "the due repair reconciles a stop detector deleted without a notification"
step "$((T + 300))" || fail "+300: the tick did not succeed"
traced "main repair +300" 2 3
pass "Main's own repair is due at +300s"

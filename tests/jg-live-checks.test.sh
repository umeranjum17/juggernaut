#!/usr/bin/env bash
# The ten live fleet checks (tests/live/, slice H20), run as the tick runs them: each check is a script on a lab home, once green and
# once with the fault of 12 Nov made in the lab, and the fault must turn its check red inside its bound.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
L=$ROOT/tests/live
T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
H=$T/home; mkdir -p "$H/state" "$H/data" "$H/config"
export JG_HOME=$H
fails=0
# want <PASS|RED> <check> [env...]: run one check on the lab home; it must print exactly one row that starts with the verdict.
want() {
  local exp=$1 name=$2 rc out want_rc; shift 2
  out=$(env JG_LIVE_NOW=10000 "$@" bash "$L/$name.sh" ${ARGS:+"$ARGS"} 2>&1); rc=$?
  want_rc=1; [ "$exp" = PASS ] && want_rc=0
  if [ "${out%% *}" = "$exp" ] && [ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && [ "$rc" = "$want_rc" ]; then
    echo "ok   $exp $name"
  else echo "FAIL $exp $name (rc=$rc): $out"; fails=$((fails + 1)); fi
}
script() { printf '#!/bin/sh\n%s\n' "$2" > "$T/$1"; chmod +x "$T/$1"; }
ARGS=''
# 1 gh shim: it answers, then it loops past the bound.
script gh-ok 'echo gh 1'; script gh-loop 'exec sleep 30'
want PASS gh-shim JG_LIVE_GH_CMD="$T/gh-ok"
want RED gh-shim JG_LIVE_GH_CMD="$T/gh-loop" JG_LIVE_GH_S=1
# 2 lock lease: a fresh beat, then a holder that stopped beating.
mkdir "$H/state/.trunk-a.lock"; echo 9900 > "$H/state/.trunk-a.lock/beat"
want PASS lock-lease
echo 100 > "$H/state/.trunk-a.lock/beat"
want RED lock-lease
# 3 model turn: every pair answers, then one pair does not.
script turn "[ \"\$2\" = good ]"
printf '# pairs\nacct-a good\n' > "$H/config/live-pairs"
want PASS model-turn JG_LIVE_TURN_CMD="$T/turn"
printf 'acct-a good\nacct-b broken\n' > "$H/config/live-pairs"
want RED model-turn JG_LIVE_TURN_CMD="$T/turn"
# 4 ready vs free: a ticket waits beside a free lane, first seen, then past the bound; then nothing is ready.
script ready 'echo t1'; script ready0 'true'; echo 3 > "$H/config/lane-target"
want PASS ready-vs-free JG_LIVE_READY_CMD="$T/ready"
want RED ready-vs-free JG_LIVE_READY_CMD="$T/ready" JG_LIVE_NOW=10400
want PASS ready-vs-free JG_LIVE_READY_CMD="$T/ready0"
# 5 plan rows: a plan that validates, then one that does not.
script validate "[ \"\$1\" = good ]"
ARGS=good want PASS plan-rows JG_LIVE_VALIDATE_CMD="$T/validate"
ARGS=bad want RED plan-rows JG_LIVE_VALIDATE_CMD="$T/validate"; ARGS=''
# 6 steer read: a steer is read (moved to handled/), then one sits unread.
mkdir -p "$T/box/handled"
want PASS steer-read JG_LIVE_INBOXES="$T/box"
echo steer > "$T/box/001.msg"; touch -d @9000 "$T/box/001.msg"
want RED steer-read JG_LIVE_INBOXES="$T/box"
# 7 load and memory: roomy host, then a loaded one, then one short of memory.
echo '0.10 0.10 0.10 1/1 1' > "$T/load-ok"; echo '999.0 1 1 1/1 1' > "$T/load-bad"
printf 'MemAvailable: 8388608 kB\n' > "$T/mem-ok"; printf 'MemAvailable: 1024 kB\n' > "$T/mem-bad"
want PASS load-memory JG_LIVE_LOADAVG="$T/load-ok" JG_LIVE_MEMINFO="$T/mem-ok"
want RED load-memory JG_LIVE_LOADAVG="$T/load-bad" JG_LIVE_MEMINFO="$T/mem-ok"
want RED load-memory JG_LIVE_LOADAVG="$T/load-ok" JG_LIVE_MEMINFO="$T/mem-bad"
# 8 stranded release: ready for a short time, then past 4 h.
mkdir -p "$H/data/release-readiness"
printf '{"at":1,"state":"open"}\n{"at":9000,"state":"ready"}\n' > "$H/data/release-readiness/state.jsonl"
want PASS stranded-release
want RED stranded-release JG_LIVE_NOW=30000
# 9 landed lane: a landed lane with no agent, then one whose agent still runs after 10 min.
mkdir -p "$H/data/jg-trunk-landing"; : > "$H/state/lane1.meta"
echo 'landed abc' > "$H/data/jg-trunk-landing/lane1.abc.state"; touch -d @9900 "$H/data/jg-trunk-landing/lane1.abc.state"
script gone 'echo "state: unknown · source: none"'; script live 'echo "state: working · source: pane"'
want PASS landed-agent JG_LIVE_AGENT_CMD="$T/live"
touch -d @9000 "$H/data/jg-trunk-landing/lane1.abc.state"
want PASS landed-agent JG_LIVE_AGENT_CMD="$T/gone"
want RED landed-agent JG_LIVE_AGENT_CMD="$T/live"
# 10 approval verify: a lead home that reaches Main's key, then one that is cut off.
openssl genpkey -algorithm ed25519 -out "$T/k.pem" 2>/dev/null && openssl pkey -in "$T/k.pem" -pubout -out "$H/config/owner-rules-proof.pub" 2>/dev/null
mkdir -p "$T/lead/config"; printf 'schema=1\nroute=local\nparent_home=%s\n' "$H" > "$T/lead/.jg-squad-lead-parent"
printf -- '- lead (a lead; (home: %s; scope: x; projects: y; added 2026-11-01)\n' "$T/lead" > "$H/data/squad_leads.md"
want PASS approval-verify
printf 'schema=1\nroute=local\nparent_home=%s\n' "$T/nowhere" > "$T/lead/.jg-squad-lead-parent"
want RED approval-verify
if [ "$fails" = 0 ]; then echo "all ten live checks: ok"; else echo "$fails failed"; exit 1; fi

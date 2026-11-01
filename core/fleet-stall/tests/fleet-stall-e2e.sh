#!/usr/bin/env bash
# fleet-stall e2e: the real check against a fixture fleet - Main's home
# (JG_STALL_ROOT) with lead records for muxr and writeboost, their two homes
# (JG_STALL_BASE) with live lanes paused for more than 45 min, and a stub herdr
# on PATH that shows both leads idle. No jg-flow-check or jg-tasks-axi exists in
# the fixture until the last case, so the zero-busy guard stays out of the way
# before it. A worker on its own
# local CI and two workers on their own emulator runs, all behind example home
# paths, no longer count; "waiting on juggernaut for the decision" and
# "awaiting main instruction" still do.
# FLEET_STALL_BIN runs another copy of the check against the same fixture.
# Needs bash and python3 on PATH; no real home, herdr or lead is touched.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -u

here=$(cd "$(dirname "$0")" && pwd) || exit 1
bin=${FLEET_STALL_BIN:-$here/../fleet-stall-check}
[ -x "$bin" ] || { echo "not ok - $bin is missing"; exit 1; }
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
export JG_STALL_ROOT=$work/main JG_STALL_BASE=$work/homes
mkdir -p "$work/stub" "$JG_STALL_ROOT/state"
cat > "$work/stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo '{"result":{"agents":[{"pane_id":"w8:p1","agent_status":"idle"},{"pane_id":"w4:p1","agent_status":"done"}]}}'
EOF
chmod +x "$work/stub/herdr"
export PATH=$work/stub:$PATH
echo window=default:w8:p1 > "$JG_STALL_ROOT/state/muxr.meta"
echo window=default:w4:p1 > "$JG_STALL_ROOT/state/writeboost.meta"

old=$(($(date +%s) - 3000))
lane() { # lane <home-number> <task> <last status line>: a live lane paused >45m
  local d=$JG_STALL_BASE/$1/juggernaut/state
  mkdir -p "$d"
  : > "$d/$2.meta"
  printf '%s\n' "$3" > "$d/$2.status"
  touch -d "@$old" "$d/$2.status"
}
lane 8 rd-local-ci "paused [at=1792181100]: local CI (./ci.sh) on my candidate running; resumes when it exits; evidence=/home/you/.treehouse/fleet/8/juggernaut/data/rd-local-ci/ci.log"
lane 4 ov-f6a-real-writer-proof "paused [at=1792177868]: own run: rebuild then one queued emulator-5630 lock hold (JG_DEVICE_WAIT=10800) for preflight+full live Go writer legs; /home/you/.treehouse/fleet/4/juggernaut/data/ov-f6a-real-writer-proof/status/queued.status"
lane 4 ov-live-writer-proof-1015 "paused [at=1792179350]: APK rebuilt at 31bce97; chunk a (Go connect+workspace pick, one real draft, ov-pm-12) queued on emulator-5630 lock (3h wait); completes at status/go-legs.status chunk a rc. Evidence: /home/you/.treehouse/fleet/4/juggernaut/data/ov-live-writer-proof-1015/status/go-legs.status"

fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }
run() { # homes the check names, e.g. "muxr(1) writeboost(1)"; the 45 min mark is cleared first
  rm -f "$JG_STALL_ROOT/state/.fleet-stall.last"
  "$bin" | sed -n 's/^fleet-stall: .*>45m: \(.*\) - send a go order$/\1/p'
}

is "workers waiting on their own runs behind juggernaut paths do not count" "$(run)" ""

lane 8 rd-decision "paused [at=1792181200]: waiting on juggernaut for the decision"
lane 4 ov-instruction "paused [at=1792181300] [key=ov-next]: awaiting main instruction"
is "lead waits still count, path-only matches still do not" "$(run)" "muxr(1) writeboost(1)"

# Zero-busy guard, the 2026-10-18 muxr shape: the idle lead's lane runs its own no-mistakes run under a paused: stamp, and
# crew-state reads that run as working. The feature's real flow check must count it busy, so muxr raises no 0-busy line.
# The fixture Main gets that check, a 3-item ready queue and a crew-state stub that reads working only for lanes under working/.
export JG_MAIN_HOME=$JG_STALL_ROOT
mkdir -p "$JG_STALL_ROOT/config" "$JG_STALL_ROOT/bin" "$JG_STALL_ROOT/working"
ln -s "${FLEET_FLOW_CHECK:-$here/../../fleet-flow/bin/jg-flow-check.sh}" "$JG_STALL_ROOT/config/jg-flow-check.sh"
cat > "$JG_STALL_ROOT/bin/jg-tasks-axi.sh" <<'EOF'
#!/usr/bin/env bash
echo "count: 3"; echo "ready[3]{id,state}:"; echo "  item-1,queued"; echo "  item-2,queued"; echo "  item-3,queued"
EOF
cat > "$JG_STALL_ROOT/bin/jg-crew-state.sh" <<'EOF'
#!/usr/bin/env bash
if [ -e "$JG_STALL_ROOT/working/$1" ]; then echo "state: working · source: run-step · execution active"; else echo "state: paused · source: status-log"; fi
EOF
chmod +x "$JG_STALL_ROOT/bin/"*.sh
lane 8 own-run "paused [at=$(date +%s)]: own run: no-mistakes fix round executing on fm/own-run"
echo kind=ship > "$JG_STALL_BASE/8/juggernaut/state/own-run.meta"
: > "$JG_STALL_ROOT/working/own-run"
rm -f "$JG_STALL_ROOT/state/.fleet-stall.last"
is "a paused own-run lane keeps muxr out of the zero-busy guard" "$("$bin" | grep -c 'muxr(0-busy' || true)" 0

exit "$fails"

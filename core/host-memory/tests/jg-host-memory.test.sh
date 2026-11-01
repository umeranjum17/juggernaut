#!/usr/bin/env bash
# Integration: real fork watcher/guard journeys, relocated sampler, then absent feature.
# Usage: bash host-memory/tests/jg-host-memory.test.sh <read-only-fork-checkout>
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
[ "$#" -eq 1 ] || { echo 'usage: jg-host-memory.test.sh <fork-checkout>' >&2; exit 2; }
addons=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
# Independent clone, never a shared worktree and never an edit to the supplied fork.
git clone -q --no-hardlinks "$1" "$d/fork"
mkdir -p "$d/home" "$d/tmp" "$d/config" "$d/data" "$d/run"
export HOME="$d/home" TMPDIR="$d/tmp" XDG_CONFIG_HOME="$d/config" XDG_DATA_HOME="$d/data" XDG_RUNTIME_DIR="$d/run"
export JG_TEST_SKIP_ORPHAN_REAP=1 JG_ADDONS_DIR="$addons" JG_BACKEND=tmux TMUX=''
unset JG_HOME JG_ROOT_OVERRIDE JG_STATE_OVERRIDE JG_CONFIG_OVERRIDE JG_TEST_LIB_SOURCED
cd "$d/fork"
# Apply prospective sampler seams ONLY in our scratch clone; tests assert behavior, not source bytes.
python3 - "$addons" <<'PY'
import pathlib
import sys

p = pathlib.Path('bin/jg-watch.sh')
s = p.read_text()
s = s.replace('. "$SCRIPT_DIR/jg-host-memory-sampler.sh"',
    'if [ -f "${JG_ADDONS_DIR:-$JG_HOME/projects/juggernaut-addons}/host-memory/bin/jg-host-memory-lib.sh" ]; then . "${JG_ADDONS_DIR:-$JG_HOME/projects/juggernaut-addons}/host-memory/bin/jg-host-memory-lib.sh"; fi')
s = s.replace('[ "$owns_lock" -ne 1 ] || jg_memory_sampler_stop',
    'if declare -F jg_memory_sampler_stop >/dev/null && [ "$owns_lock" -eq 1 ]; then jg_memory_sampler_stop; fi')
for verb in ('start', 'restart'):
    line = f'jg_memory_sampler_ensure || triage_log "host memory sampler failed to {verb}"'
    s = s.replace(line, f'if declare -F jg_memory_sampler_ensure >/dev/null; then {line}; fi')
p.write_text(s)
# Older fork tests source the old public path to drive tick publication failures.
# Keep that entrypoint in the scratch clone, but run the feature implementation.
pathlib.Path('bin/jg-host-memory-sampler.sh').write_text(
    '. "${JG_ADDONS_DIR}/host-memory/bin/jg-host-memory-lib.sh"\n')
PY
export JG_ADDON_TEST_ROOT="$addons" JG_ADDON_ABSENT_ROOT="$d/absent-addons"
echo '=== ordinary watcher check with present and absent feature ==='
bash -s <<'SH'
set -u
# shellcheck source=/dev/null
. "$PWD/tests/wake-helpers.sh"
TMP_ROOT=$(jg_test_tmproot jg-addon-absent)
for mode in present absent; do
  if [ "$mode" = present ]; then export JG_ADDONS_DIR="$JG_ADDON_TEST_ROOT"; else export JG_ADDONS_DIR="$JG_ADDON_ABSENT_ROOT"; fi
  case=$(make_case "Umer-$mode")
  mkdir -p "$case/proc/pressure"
  printf 'MemAvailable: 41943040 kB\n' > "$case/proc/meminfo"
  printf 'some avg10=0 avg60=0 avg300=0 total=0\n' > "$case/proc/pressure/memory"
  cat > "$case/state/ordinary.check.sh" <<'CHECK'
#!/usr/bin/env bash
if [ -f "$JG_HOME/state/.host-memory-sampler.pid" ]; then
  read -r pid _ < "$JG_HOME/state/.host-memory-sampler.pid"
  ps -ww -p "$pid" -o args= > "$JG_HOME/sampler-command"
fi
echo 'Umer check completed'
CHECK
  chmod 700 "$case/state/ordinary.check.sh"
  JG_HOME="$case" JG_STATE_OVERRIDE="$case/state" "$ROOT/bin/jg-check-register.sh" ordinary >/dev/null || fail 'custom check registration failed'
  rc=0
  env PATH="$case/fakebin:$PATH" JG_HOME="$case" JG_ROOT_OVERRIDE="$ROOT" \
    JG_HOST_MEMORY_PROC="$case/proc" JG_HOST_MEMORY_CGROUP_ROOT="$case/no-cgroup" \
    JG_POLL=1 JG_SIGNAL_GRACE=0 JG_CHECK_INTERVAL=1 JG_HEARTBEAT=999999 \
    JG_SQUAD_LEAD_LIVENESS_SECS=99999999 timeout 20 "$ROOT/bin/jg-watch.sh" > "$case/out" 2> "$case/err" || rc=$?
  [ "$rc" -eq 0 ] || fail "$mode feature watcher exited $rc: $(<"$case/err")"
  assert_contains "$(<"$case/out")" 'Umer check completed' "$mode feature keeps ordinary watcher behavior"
  if [ "$mode" = present ]; then
    assert_contains "$(<"$case/sampler-command")" "$JG_ADDON_TEST_ROOT/host-memory/bin/jg-host-memory-sampler.sh run" 'the running sampler comes from the feature'
    [ -s "$case/state/host-memory.tsv" ] || fail 'relocated sampler did not record a sample'
  else
    for f in "$case/state"/*host-memory* "$case/state"/.*host-memory*; do
      [ ! -e "$f" ] || fail "absent feature created sampler state: $f"
    done
  fi
  [ ! -s "$case/err" ] || fail "$mode feature emitted an error: $(<"$case/err")"
  pass "$mode feature: ordinary check succeeds with correct sampler presence"
done
SH
echo 'PASS current fork, relocated lifecycle and absent feature integration'

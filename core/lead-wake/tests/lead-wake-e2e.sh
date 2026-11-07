#!/usr/bin/env bash
# Integration proof of the lead-wake seam. JG_TEST_FORK names a read-only Juggernaut
# checkout; its bin/ and tests/ are copied privately and only the proposed step-B replacements
# are applied to the copy (tests/stage-step-b.py). The real watcher then runs the fork's lead-wake cases (tests/jg-lead-wake.test.sh):
# feature present = the fork's lead-wake behavior, feature absent = Kun's (no wake, no error).
# Needs the backlog, bash, python3.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
addons=$(cd "$(dirname "$0")/../.." && pwd)
: "${JG_TEST_FORK:?set JG_TEST_FORK to a Juggernaut checkout}"
d=$(mktemp -d)
watchers=()  # watcher pids this run started, stopped before the fixture is removed
cleanup() {
  rc=$?
  local pid
  # A watcher leaves a detached helper running that can recreate a fixture's
  # state directory, so stop the watchers this run started and let the removal
  # absorb any late write before the tree goes.
  for pid in ${watchers[@]+"${watchers[@]}"}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  if [ "$rc" -eq 0 ]; then bash "$addons/lead-wake/tests/fixture-cleanup.sh" "$d"; else printf 'fixture retained: %s\n' "$d" >&2; fi
  exit "$rc"
}
trap cleanup EXIT
export HOME=$d/user XDG_CONFIG_HOME=$d/xdg-config XDG_DATA_HOME=$d/xdg-data TMPDIR=$d/tmp
mkdir -p "$HOME" "$TMPDIR" "$d/fork" "$d/fakebin" "$d/empty"
# The fork checkout carries what its watcher reads and builds from its own core
# tree: the escalation ladder definition ($ROOT/core/bus/workflows) and the Go
# command behind bin/jg-bus.sh, which the wake-queue observation builds on first
# use inside the home's state directory, plus the Go window inventory behind
# bin/jg-watch-core.sh, which every watcher cycle reads, plus the Go wake-queue
# reader behind bin/jg-wake-core.sh, which the drain and the watcher ask what is
# queued. Without them every tick
# dies and writes that failure to stderr, which the absent-feature case below
# reads.
mkdir -p "$d/fork/core/bus" "$d/fork/core/watch" "$d/fork/core/wake"
cp -a "$JG_TEST_FORK/bin" "$JG_TEST_FORK/tests" "$JG_TEST_FORK/toolchain.versions" "$d/fork/"
mkdir -p "$d/lib"; cp -a "$addons/lib/beads-test-env.sh" "$d/lib/"
cp -a "$JG_TEST_FORK/core/bus/." "$d/fork/core/bus/"
cp -a "$JG_TEST_FORK/core/watch/." "$d/fork/core/watch/"
cp -a "$JG_TEST_FORK/core/wake/." "$d/fork/core/wake/"
rm -f -- "$d/fork/core/bus/jg-bus"
python3 "$addons/lead-wake/tests/stage-step-b.py" "$d/fork/bin"
cp "$addons/lead-wake/tests/jg-lead-wake.test.sh" "$addons/lead-wake/tests/lead-wake-harness.sh" "$d/fork/tests/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$d/fakebin/tmux"
printf '#!/usr/bin/env bash\necho "state: unknown · source: none · fake default"\n' > "$d/fakebin/jg-crew-state.sh"
chmod +x "$d/fakebin/"*

. "$d/lib/beads-test-env.sh"
fail() { echo "not ok - $*" >&2; exit 1; }
ok() { echo "ok - $*"; }
tasks() { JG_HOME=$home "$d/fork/bin/jg-tasks-axi.sh" "$@" >/dev/null || fail "fixture: tasks $*"; }
newhome() {  # <name>
  home=$d/$1; state=$home/state
  mkdir -p "$state" "$home/config" "$home/data"
  core_beads_home "$d/fork" "$home"  # a real Beads store; bare fixture items for wake cases
  printf 'lead-1\n' > "$home/.jg-squad-lead-home"
}
# watch <addons-dir> <out> [wait-seconds]: run the real watcher; it exits on a wake.
watch() {
  local pid i=0 limit=${3:-100}
  rm -f "$state/.last-ready-work-check" "$state/.heartbeat-streak" "$state/.last-heartbeat"
  PATH="$d/fakebin:$PATH" JG_HOME="$home" JG_STATE_OVERRIDE="$state" JG_ADDONS_DIR="$1" \
    JG_CREW_STATE_BIN="$d/fakebin/jg-crew-state.sh" JG_POLL=1 JG_SIGNAL_GRACE=1 \
    JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=1 JG_SQUAD_LEAD_LIVENESS_SECS=99999999 \
    bash "$d/fork/bin/jg-watch.sh" > "$2" 2>"$2.err" &
  pid=$!
  watchers+=("$pid")
  while [ "$i" -lt "$limit" ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; return 1; fi
  wait "$pid" 2>/dev/null || true
}

# The fixture cleanup itself, on the exact race that used to fail a green run.
bash "$addons/lead-wake/tests/fixture-cleanup.test.sh" || fail "fixture cleanup under a late writer"

# Present: the fork's lead-wake cases on the staged watcher. Absent: Kun's ring text.
JG_ADDONS_DIR=$addons bash "$d/fork/tests/jg-lead-wake.test.sh" || fail "fork lead-wake cases with the feature present"
JG_ADDONS_DIR=$d/empty RING_TEXT="Drain pending rows in this home's wake queue, then resume idle supervision." \
  bash "$d/fork/tests/jg-lead-wake.test.sh" ring || fail "absent feature: Kun's drain ring"

# Absent feature: Kun behavior - no ready-work wake, no error.
newhome absent
tasks add jg-alpha-one "first ready item"
watch "$d/empty" "$d/o5" 30 || true
! grep -q 'ready work waiting' "$d/o5" || fail "absent feature still woke the lead: $(cat "$d/o5")"
[ ! -s "$d/o5.err" ] || fail "absent feature wrote stderr: $(cat "$d/o5.err")"
[ ! -e "$state/.ready-work-surfaced" ] || fail "absent feature recorded a ready-work surfacing"
ok "absent: no ready-work wake and no error (Kun behavior)"

# lane-target inheritance hook.
inherit() { JG_HOME=$home JG_ADDONS_DIR=$1 bash -c '. "$1/jg-config-inherit-lib.sh"; printf "%s\n" "$JG_INHERITABLE_CONFIG"' _ "$d/fork/bin"; }
case " $(inherit "$addons") " in *" lane-target "*) ok "present: lane-target is inheritable" ;; *) fail "lane-target not inheritable" ;; esac
case " $(inherit "$d/empty") " in *" lane-target "*) fail "absent feature still inherits lane-target" ;; *) ok "absent: Kun's inheritable list" ;; esac

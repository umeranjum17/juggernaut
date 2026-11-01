#!/usr/bin/env bash
# Model-outage observer reached through the step-B loader and guarded tick, over
# fixture lanes: present -> grouped wake, absent -> kun behavior (no function, no
# wake, exit 0 under set -e). JG_TEST_FORK names a read-only Juggernaut checkout;
# the watcher itself is never run.
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
cleanup() {
  rc=$?
  if [ "$rc" -eq 0 ]; then rm -rf -- "$d"; else printf 'fixture retained: %s\n' "$d" >&2; fi
}
trap cleanup EXIT
export HOME=$d/user TMPDIR=$d/tmp
mkdir -p "$HOME" "$TMPDIR" "$d/fork"
cp -a "$JG_TEST_FORK/bin" "$d/fork/bin"
rm -f "$d/fork/bin/jg-model-outage-lib.sh"   # step B deletes the fork-only copy
# The observer reads the backend and busy verdict through sibling libraries run
# in a bounded subshell; fake only those two, as the fork's own fixtures do.
cat > "$d/fork/bin/jg-backend.sh" <<'FAKE'
jg_backend_agent_state() { printf alive; }
jg_backend_visible_capture_supported() { return 0; }
jg_backend_visible_capture() { printf 'Upstream request failed: region denied\n'; }
FAKE
cat > "$d/fork/bin/jg-busy-lib.sh" <<'FAKE'
jg_busy_classify_semantic() { printf 'idle opencode-plugin\n'; }
FAKE

# shellcheck disable=SC2317,SC2329,SC2030 # the watcher helpers are called by the sourced library
# run <addons-dir> <wake-file>: the exact step-B watcher lines over two idle lanes
# that fail with the same provider error.
run() {
  local ad=$1 wakes=$2 state
  state=$d/state-$(basename "$wakes")
  mkdir -p "$state" "$d/live"
  (
    set -e
    export JG_HOME=$d/fork SCRIPT_DIR=$d/fork/bin STATE=$state JG_ADDONS_DIR=$ad
    # shellcheck source=/dev/null
    [ ! -r "${JG_ADDONS_DIR:-$JG_HOME/projects/juggernaut-addons}/alerts/bin/jg-model-outage-lib.sh" ] || . "${JG_ADDONS_DIR:-$JG_HOME/projects/juggernaut-addons}/alerts/bin/jg-model-outage-lib.sh"
    jg_busy_token_valid() { return 0; }
    jg_backend_visible_capture_supported() { return 0; }
    jg_busy_current_gen() { cat "$1/$2.busy-gen"; }
    jg_meta_get() { printf opencode; }
    jg_backend_target_of_meta() { printf 'fake:%s' "${1##*/}"; }
    jg_backend_of_meta() { printf fake; }
    hash_pane() { md5sum | cut -c1-12; }
    jg_wake_append() { printf '%s\n' "$3" >> "$wakes"; }
    wake() { :; }
    triage_log() { printf '%s\n' "$*" >> "$d/triage.log"; }
    for id in alpha bravo; do : > "$state/$id.meta"; printf 'g1\n' > "$state/$id.busy-gen"; done
    if declare -F jg_model_outage_tick >/dev/null; then jg_model_outage_tick || triage_log "model-error observation failed"; fi
  )
}

run "$addons" "$d/present.wakes"
grep -q 'check: model outage affected=\[alpha,bravo\]: Upstream request failed: region denied' "$d/present.wakes" \
  || { echo "FAIL: present feature must raise one grouped outage wake" >&2; cat "$d/present.wakes" >&2 || true; exit 1; }
[ "$(wc -l < "$d/present.wakes")" -eq 1 ] || { echo "FAIL: exactly one wake expected" >&2; exit 1; }

run "$d/no-addons" "$d/absent.wakes"
[ ! -e "$d/absent.wakes" ] || { echo "FAIL: absent feature must raise no wake" >&2; exit 1; }
[ ! -e "$d/triage.log" ] || { echo "FAIL: absent feature must log nothing" >&2; cat "$d/triage.log" >&2; exit 1; }
# Push-transition hook: cursor and open-captain-call tasks suppress, others do not.
# shellcheck disable=SC2031,SC2317,SC2329 # the sourced hook calls the stubs
(
  export JG_HOME=$d/fork SCRIPT_DIR=$d/fork/bin STATE=$d/state-push
  mkdir -p "$STATE"
  # shellcheck source=/dev/null
  . "$addons/alerts/bin/jg-model-outage-lib.sh"
  ! jg_alerts_push_suppress cursor-task || { echo "FAIL: hook suppressed without watcher helpers" >&2; exit 1; }
  jg_meta_get() { case $1 in *cursor-task.meta) printf cursor ;; *) printf claude ;; esac; }
  task_captain_call_open() { [ "$1" = call-task ]; }
  jg_alerts_push_suppress cursor-task || { echo "FAIL: cursor task must suppress" >&2; exit 1; }
  jg_alerts_push_suppress call-task || { echo "FAIL: open captain call must suppress" >&2; exit 1; }
  ! jg_alerts_push_suppress plain-task || { echo "FAIL: ordinary task must not suppress" >&2; exit 1; }
)
echo "ok: alerts observer present -> grouped wake; absent -> kun behavior"

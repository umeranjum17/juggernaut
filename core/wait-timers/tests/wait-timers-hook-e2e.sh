#!/usr/bin/env bash
# Run the post-step-B fork journey with the feature installed, then verify the
# optional hooks remain a no-op when it is absent.
# JG_TEST_FORK names a read-only Juggernaut checkout.
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
mkdir -p "$HOME" "$TMPDIR" "$d/fork" "$d/addons"
cp -a "$addons/." "$d/addons/"
cp -a "$JG_TEST_FORK/bin" "$JG_TEST_FORK/tests" "$d/fork/"
# Step B moved the journey into this feature; restore its test without changing
# the post-step-B fork sources.
cp "$addons/wait-timers/tests/jg-wait-timers.test.sh" "$d/fork/tests/"

# Present: the unmodified fork journey over the feature library.
(cd "$d/fork" && env -u JG_TASK_ID JG_WAIT_TIMERS_MAIN_ESCALATION_ONLY=1 JG_HOME="$d/fork" JG_ADDONS_DIR="$d/addons" bash tests/jg-wait-timers.test.sh) > "$d/present.out" 2>&1 \
  || { echo "FAIL: wait-timer journey with the feature present" >&2; tail -20 "$d/present.out" >&2; exit 1; }

# Absent: a Main-owned overdue episode cannot enqueue its check wake without
# the optional timer hook. Use the same durable episode shape as the real journey.
( set -e
  JG_HOME="$d/fork" JG_ADDONS_DIR="$d/none"
  mkdir -p "$d/fork/state"
  printf 'blocked [key=wait]: external condition\\n' > "$d/fork/state/fixture.status"
  lib="${JG_ADDONS_DIR:-$JG_HOME/projects/juggernaut-addons}/wait-timers/bin/jg-wait-timers-lib.sh"
  task=fixture
  # shellcheck source=/dev/null
  [ ! -r "$lib" ] || . "$lib"
  if declare -F jg_wait_timers_tick >/dev/null; then jg_wait_timers_tick; fi
  if [ -n "$task" ] && declare -F jg_wait_timer_push_delivered >/dev/null; then jg_wait_timer_push_delivered "$task" window; fi
  ! declare -F jg_wait_timers_tick >/dev/null
  ! declare -F jg_wait_timer_push_delivered >/dev/null
  [ ! -e "$d/fork/state/.waiting-timers/fixture" ] ) \
  || { echo "FAIL: absent feature must not escalate the wait" >&2; exit 1; }
echo "ok: Main-owned escalation with feature; absent feature does not escalate"

#!/usr/bin/env bash
# tests/jg-unit-claim.test.sh - the machine's four long-running Juggernaut
# services belong to Main (bin/jg-unit-claim.sh).
#
# A throwaway HOME, a throwaway XDG config dir and a lab `systemctl` stand in for
# the user manager, so the real one is never read or changed. The lab reads each
# unit's own Environment= line, which is the fact the claim is judged on, and it
# starts a unit only when it is restarted.
#
# Coverage:
#   - a real session start in a home whose own copy has the four units pointing
#     at another home claims all four, the units then name this home, the
#     bootstrap banner prints no UNIT_HOME line, and a second session start says
#     nothing about claiming (idempotent);
#   - status names a unit that is installed but not running and one that serves
#     another home, and stays silent for a unit that is absent or serves here -
#     this is the line the watcher's fast check alerts with;
#   - a Squad Lead home is refused by claim, by `jg-sentinel.sh unit` and by
#     `jg-stack.sh up`, with one plain reason, and its banner prints no
#     UNIT_HOME line and no move command at all;
#   - a checkout that is not the home's own copy never claims the units.
#
# The stand-in for the Go command's `unit` verb only has to produce a unit naming
# this home: the Go generator and bin/jg-stack.sh own the real unit text and are
# covered by their own suites.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BASE_PATH=${JG_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(jg_test_tmproot jg-unit-claim-tests)
JG_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap jg_test_cleanup EXIT

UNIT_LIST="jg-sentinel jg-wake-engine jg-wake-watcher jg-router"

# make_lab <name>: a lab dir with a stand-in user manager, a throwaway HOME, two
# homes ("mine" and "other") and a stand-in for the bus command. Echoes <dir>.
make_lab() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/home" "$d/other" "$d/mine/state" "$d/mine/data" "$d/mine/config" \
    "$d/xdg/systemd/user" "$d/fakebin" "$d/stand-in"
  cat > "$d/fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
set -u
dir=$JG_LAB_UNIT_DIR state=$JG_LAB_ACTIVE log=$JG_LAB_LOG
[ "${1:-}" = --user ] || { echo "lab systemctl: only --user" >&2; exit 1; }
shift
printf '%s\n' "$*" >> "$log"
case "${1:-}" in
  show-environment) exit 0 ;;
  show) sed -n 's/^Environment="\(JG_HOME=[^"]*\)".*$/\1/p' "$dir/$5.service" 2>/dev/null; exit 0 ;;
  is-enabled) [ -e "$dir/$3.service" ] ;;
  is-active) [ -e "$dir/$3.service" ] && grep -qx "$3" "$state" ;;
  daemon-reload|enable) exit 0 ;;
  restart) grep -qx "$2" "$state" || printf '%s\n' "$2" >> "$state"; exit 0 ;;
  *) echo "lab systemctl: unsupported: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$d/fakebin/systemctl"
  cat > "$d/stand-in/jg-bus" <<'SH'
#!/usr/bin/env bash
printf '[Service]\nEnvironment="JG_HOME=%s"\nExecStart=%s\n' "$JG_HOME" "$*"
SH
  chmod +x "$d/stand-in/jg-bus"
  printf '%s\n' "$d"
}

# units_serving <dir> <home>: the four units installed, active and naming <home>.
units_serving() {
  local d=$1 home=$2 unit
  : > "$d/active"
  for unit in $UNIT_LIST; do
    printf '[Service]\nEnvironment="JG_HOME=%s"\nExecStart=/bin/true\n' "$home" > "$d/xdg/systemd/user/$unit.service"
    printf '%s\n' "$unit" >> "$d/active"
  done
}

# lab_env <dir>: point this shell's lab at <dir>'s throwaway HOME and units.
lab_env() {
  local d=$1
  export JG_LAB_UNIT_DIR="$d/xdg/systemd/user" JG_LAB_ACTIVE="$d/active" JG_LAB_LOG="$d/log"
  export HOME="$d/home" XDG_CONFIG_HOME="$d/xdg" JG_BUS_BIN="$d/stand-in/jg-bus"
  : > "$d/log"
}

# served_by <dir> <unit>: the home the installed unit names.
served_by() {
  sed -n 's/^Environment="JG_HOME=\([^"]*\)".*$/\1/p' "$1/xdg/systemd/user/$2.service" 2>/dev/null
}

run_in_home() {  # <dir> <script> [args...]: one command with the lab's PATH and home
  local d=$1
  shift
  env -u CLAUDECODE -u PI_CODING_AGENT -u JG_PI_HARNESS -u HERDR_ENV -u HERDR_BIN_PATH \
    -u JG_STACK_SKIP HOME="$d/home" XDG_CONFIG_HOME="$d/xdg" JG_HOME="$d/mine" JG_ROOT_OVERRIDE="$d/mine" \
    JG_BUS_BIN="$d/stand-in/jg-bus" PATH="$d/fakebin:$BASE_PATH" "$@"
}

test_session_start_claims_the_machine_services() {
  local d out unit
  d=$(make_lab session)
  cp -a "$ROOT/bin" "$d/mine/bin"
  printf '%s\n' manual > "$d/mine/config/backlog-backend"
  # The home's own copy, so this is the home whose services they are.
  lab_env "$d"
  units_serving "$d" "$d/other"

  out=$(run_in_home "$d" "$d/mine/bin/jg-session-start.sh" 2>&1) \
    || fail "the session start should complete, got exit $?"
  assert_contains "$out" "claimed: jg-sentinel now serves $d/mine" "the session start must claim the sentinel"
  for unit in $UNIT_LIST; do
    assert_equals "$d/mine" "$(served_by "$d" "$unit")" "session start must move $unit to this home"
    grep -qx "$unit" "$d/active" || fail "$unit must be running after the claim"
  done
  assert_not_contains "$out" "UNIT_HOME:" "a claimed home has no wrong-unit banner to print"

  out=$(run_in_home "$d" "$d/mine/bin/jg-session-start.sh" 2>&1) \
    || fail "the second session start should complete, got exit $?"
  assert_not_contains "$out" "claimed:" "a second session start must claim nothing"
  assert_not_contains "$out" "UNIT_HOME:" "a claimed home stays silent about the units"
  pass "session start: a home whose services serve another home claims all four and proves it"
}

test_status_names_a_dead_and_a_foreign_unit() {
  local d out
  d=$(make_lab status)
  cp -a "$ROOT/bin" "$d/mine/bin"
  lab_env "$d"
  units_serving "$d" "$d/other"
  # Two are wrong in each way, one already serves this home, one is not installed.
  printf '[Service]\nEnvironment="JG_HOME=%s"\nExecStart=/bin/true\n' "$d/mine" > "$d/xdg/systemd/user/jg-wake-watcher.service"
  rm -f "$d/xdg/systemd/user/jg-wake-engine.service"
  grep -vx jg-router "$d/active" > "$d/active.new" && mv "$d/active.new" "$d/active"

  out=$(run_in_home "$d" "$d/mine/bin/jg-unit-claim.sh" status) || fail "status must always exit 0"
  assert_contains "$out" "UNIT_HOME: jg-sentinel serves $d/other, not this home" "a unit serving another home must be named"
  assert_contains "$out" "UNIT_HOME: jg-router is installed but not running" "a dead unit must be named"
  assert_not_contains "$out" "jg-wake-watcher" "a unit serving this home is not a finding"
  assert_not_contains "$out" "jg-wake-engine" "a unit that was never installed is not a finding"
  pass "status: a dead unit and a unit serving another home are named, the rest stay quiet"
}

test_squad_lead_home_is_refused() {
  local d out rc
  d=$(make_lab refusal)
  cp -a "$ROOT/bin" "$d/mine/bin"
  printf '%s\n' manual > "$d/mine/config/backlog-backend"
  printf '%s\n' herdr > "$d/mine/config/backend"
  lab_env "$d"
  units_serving "$d" "$d/other"
  : > "$d/mine/.jg-squad-lead-home"

  rc=0; out=$(run_in_home "$d" "$d/mine/bin/jg-sentinel.sh" unit 2>&1) || rc=$?
  expect_code 2 "$rc" "jg-sentinel.sh unit in a Squad Lead home"
  assert_contains "$out" "jg-sentinel: unit refused: Main owns the machine services" "the sentinel refusal must name the owner"
  assert_contains "$out" "a Squad Lead home never installs or moves them" "the sentinel refusal must say why"

  rc=0; out=$(run_in_home "$d" "$d/mine/bin/jg-stack.sh" up 2>&1) || rc=$?
  expect_code 2 "$rc" "jg-stack.sh up in a Squad Lead home"
  assert_contains "$out" "jg-stack: up refused: Main owns the machine services" "the stack refusal must name the owner"

  rc=0; out=$(run_in_home "$d" "$d/mine/bin/jg-unit-claim.sh" claim 2>&1) || rc=$?
  expect_code 2 "$rc" "claim in a Squad Lead home"
  assert_contains "$out" "refused: Main owns the machine services" "the claim refusal must name the owner"

  # The banner in a Squad Lead home prints no line at all, so it offers no command to run.
  out=$(run_in_home "$d" env JG_BOOTSTRAP_NETWORK=skip "$d/mine/bin/jg-bootstrap.sh" 2>&1) || true
  assert_not_contains "$out" "UNIT_HOME:" "a Squad Lead home's banner names no unit"
  assert_not_contains "$out" "move it" "a Squad Lead home's banner offers no move command"
  grep -qx "jg-router" "$d/active" || fail "the refusal must not stop the units"
  assert_equals "$d/other" "$(served_by "$d" jg-sentinel)" "the refusal must not move a unit"
  pass "refusal: a Squad Lead home is turned away by every install path and claims nothing"
}

test_a_foreign_checkout_never_claims() {
  local d out
  d=$(make_lab foreign)
  lab_env "$d"
  units_serving "$d" "$d/other"
  # $ROOT is not this home's own copy: a test or throwaway home must never take
  # the machine's units over.
  out=$(env HOME="$d/home" XDG_CONFIG_HOME="$d/xdg" JG_HOME="$d/mine" \
    JG_BUS_BIN="$d/stand-in/jg-bus" PATH="$d/fakebin:$BASE_PATH" "$ROOT/bin/jg-unit-claim.sh" claim 2>&1) \
    || fail "claim from a foreign checkout must exit 0: $out"
  assert_equals "" "$out" "a foreign checkout claims silently"
  assert_equals "$d/other" "$(served_by "$d" jg-sentinel)" "a foreign checkout must not move a unit"
  out=$(env HOME="$d/home" XDG_CONFIG_HOME="$d/xdg" JG_HOME="$d/mine" \
    PATH="$d/fakebin:$BASE_PATH" "$ROOT/bin/jg-unit-claim.sh" status 2>&1)
  assert_equals "" "$out" "a foreign checkout reports nothing about the machine's units"
  pass "guard: only the home's own copy of Juggernaut reads, reports or moves the machine's units"
}

test_session_start_claims_the_machine_services
test_status_names_a_dead_and_a_foreign_unit
test_squad_lead_home_is_refused
test_a_foreign_checkout_never_claims

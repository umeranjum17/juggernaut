#!/usr/bin/env bash
# The host and fleet numbers on Prometheus plus node_exporter, in shadow
# (docs/metrics-shadow.md): both paths must report the same load, available
# memory, free disk and fleet shape over one instant, a deliberately tampered
# sample on the new path must make the same check fail, and a parity that did not
# run must never read as a green one.
#
# The test runs a throwaway Prometheus and node_exporter on two free ports, driven
# by the shadow's own config file, and never touches this machine's real
# Prometheus, a real home, or the fleet's records.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

PROM=${JG_PROMETHEUS_BIN:-$(command -v prometheus 2>/dev/null || true)}
NODE=${JG_NODE_EXPORTER_BIN:-$(command -v node_exporter 2>/dev/null || true)}
if [ -z "$PROM" ]; then
  echo "skip: prometheus not found (set JG_PROMETHEUS_BIN)"
  exit 0
fi
if [ -z "$NODE" ]; then
  echo "skip: node_exporter not found (set JG_NODE_EXPORTER_BIN)"
  exit 0
fi

DIR=$(jg_test_tmproot jg-metrics-shadow-parity)
HOME_DIR="$DIR/home"
STATE_DIR="$HOME_DIR/state"
SHADOW="$DIR/shadow"

# free_port <lower> <upper>: the first port in the range nothing answers on.
free_port() { # <lower> <upper>
  local p
  for p in $(seq "$1" "$2"); do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then printf '%s\n' "$p"; return 0; fi
  done
  return 1
}
PROM_PORT=$(free_port 29100 29199) || fail "no free port for prometheus"
NODE_PORT=$(free_port 29200 29299) || fail "no free port for node_exporter"

# A run that fails at any point still stops the two processes it started, so a
# failing suite can never leave a scraper listening on this host.
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() { declare -F shadow >/dev/null && shadow stop >/dev/null 2>&1; return 0; }
trap cleanup EXIT

# shadow <args...>: the shadow, scoped to this test's home, configured by file.
shadow() {
  JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE_DIR" JG_METRICS_SHADOW_DIR="$SHADOW" \
    bash "$ROOT/bin/jg-metrics-shadow.sh" "$@"
}

# The home's records: one lane working, one done, three ready, one open wait, and
# a beacon that just beat. That is a GAP verdict with waits, so every shape field
# the bridge carries is a number this test can name.
fixture() {
  mkdir -p "$STATE_DIR/.waiting-timers" "$HOME_DIR/config" || fail "cannot build the fixture home"
  printf 'ship\n' > "$STATE_DIR/lane-one.meta"
  printf 'working [at=1]: doing the work\n' > "$STATE_DIR/lane-one.status"
  printf 'ship\n' > "$STATE_DIR/lane-two.meta"
  printf 'done [at=2]: finished\n' > "$STATE_DIR/lane-two.status"
  printf '{"ready_work": 3}\n' > "$STATE_DIR/home-summary.json"
  printf '2\n' > "$HOME_DIR/config/lane-target"
  : > "$STATE_DIR/.waiting-timers/ep-one"
  : > "$STATE_DIR/.last-watcher-beat"
  printf 'prometheus-bin %s\nnode-exporter-bin %s\nscrape-interval 1s\nlisten 127.0.0.1:%s\nnode-listen 127.0.0.1:%s\n' \
    "$PROM" "$NODE" "$PROM_PORT" "$NODE_PORT" > "$HOME_DIR/config/metrics-shadow"
}

test_the_config_file_is_what_prometheus_runs() {
  local out config
  out=$(shadow start 2>&1) || fail "the shadow did not start: $out"
  assert_contains "$out" "started:" "start must report the two listeners it opened"
  config="$SHADOW/prometheus.yml"
  [ -f "$config" ] || fail "start did not render a Prometheus config file"
  assert_contains "$(cat "$config")" "scrape_interval: 1s" "the rendered config must carry the scrape interval from config/metrics-shadow"
  assert_contains "$(cat "$config")" "targets: [\"127.0.0.1:$NODE_PORT\"]" "the rendered config must scrape this shadow's own node_exporter"
  assert_contains "$(shadow status)" "prometheus	running" "the shadow must report the process it started"
  pass "prometheus is configured by the shadow's own file and scrapes its own node_exporter"
}

test_export_carries_the_fleet_shape() {
  local out textfile
  out=$(shadow export 2>&1) || fail "the export failed: $out"
  assert_contains "$out" "exported: 6 series for 1 home(s)" "one home must export its six shape series"
  textfile="$SHADOW/textfile/fleet-shape.prom"
  [ -f "$textfile" ] || fail "the export wrote no textfile for node_exporter to read"
  assert_contains "$(cat "$textfile")" 'jg_fleet_home_working{home="overwatch"} 1' "the working lanes must reach the bridge"
  assert_contains "$(cat "$textfile")" 'jg_fleet_home_target{home="overwatch"} 2' "the lane target must reach the bridge"
  assert_contains "$(cat "$textfile")" 'jg_fleet_home_ready{home="overwatch"} 3' "the ready count must reach the bridge"
  assert_contains "$(cat "$textfile")" 'jg_fleet_home_waits{home="overwatch"} 1' "the open waits must reach the bridge"
  assert_contains "$(cat "$textfile")" 'jg_fleet_home_verdict{home="overwatch",verdict="GAP"} 1' "the verdict must reach the bridge as a label"
  assert_contains "$(cat "$textfile")" 'jg_fleet_home_beacon_age_seconds{home="overwatch"}' "the beacon age must reach the bridge"
  pass "the shipped collector's rows reach node_exporter as shape series"
}

test_parity_reports_no_difference() {
  local out
  out=$(shadow parity 2>&1) || { printf '%s\n' "$out"; fail "parity failed on an untampered replay"; }
  assert_contains "$out" "load1" "the load average must be compared"
  assert_contains "$out" "mem_available_kib" "available memory must be compared"
  assert_contains "$out" "disk_avail_kib" "free disk on the root mount must be compared"
  assert_contains "$out" "fleet_overwatch_verdict" "the fleet verdict must be compared"
  assert_contains "$out" "fields_compared=9" "three host fields and six shape fields must be compared"
  assert_contains "$out" "differences=0" "both paths must agree within their tolerances"
  assert_contains "$out" "fields_skipped=0" "every field of this fixture must be comparable"
  pass "both paths report the same host numbers and the same fleet shape"
}

test_tampering_is_reported_and_healed() {
  local out status=0 after
  out=$(shadow parity --corrupt 2>&1) || status=$?
  [ "$status" -ne 0 ] || { printf '%s\n' "$out"; fail "parity passed after one exported sample was tampered with"; }
  assert_contains "$out" "corrupt: fleet_overwatch_waits moved by one" "the report must name the sample it tampered with"
  assert_equals 1 "$(printf '%s\n' "$out" | awk '$1 == "fleet_overwatch_waits" && $2 == 1 && $3 == 2 && $5 == "diff"' | wc -l)" \
    "the difference must name the field and both values"
  assert_not_contains "$out" "differences=0" "a tampered sample must never report no difference"
  after=$(shadow parity 2>&1) || { printf '%s\n' "$after"; fail "parity failed after the tampered sample was healed"; }
  assert_contains "$after" "differences=0" "the next comparison must see the true sample again, not the tampered one"
  pass "one tampered sample on the new path fails the same check, and the heal restores it"
}

test_an_unrun_parity_is_never_green() {
  local out status=0 saved
  saved=$(cat "$HOME_DIR/config/metrics-shadow")
  rm -f "$HOME_DIR/config/metrics-shadow" || fail "cannot clear the shadow config"
  out=$(shadow parity 2>&1) || status=$?
  [ "$status" -ne 0 ] || { printf '%s\n' "$out"; fail "parity passed with the shadow switched off"; }
  assert_contains "$out" "not run" "a parity that did not run must say so"
  printf '%s\n' "$saved" > "$HOME_DIR/config/metrics-shadow"
  printf 'prometheus-bin %s\nnode-exporter-bin /nonexistent\n' "$PROM" > "$HOME_DIR/config/metrics-shadow"
  status=0
  out=$(shadow parity 2>&1) || status=$?
  [ "$status" -ne 0 ] || { printf '%s\n' "$out"; fail "parity passed with no node_exporter to read"; }
  assert_contains "$out" "not run" "a parity with no exporter must say it did not run"
  printf '%s\n' "$saved" > "$HOME_DIR/config/metrics-shadow"
  pass "a parity that did not run exits non-zero instead of reporting a pass"
}

test_stop_leaves_nothing_running() {
  local out
  out=$(shadow stop 2>&1) || fail "the shadow did not stop: $out"
  assert_contains "$out" "stopped: prometheus" "stop must report the process it stopped"
  assert_contains "$out" "stopped: node_exporter" "stop must report the process it stopped"
  assert_contains "$(shadow status)" "prometheus	stopped" "status must not claim a stopped process is running"
  if (exec 3<>"/dev/tcp/127.0.0.1/$PROM_PORT") 2>/dev/null; then
    fail "the prometheus listener still answers after stop"
  fi
  pass "stop ends both processes and leaves no listener behind"
}

fixture
result=0
test_the_config_file_is_what_prometheus_runs || result=1
test_export_carries_the_fleet_shape || result=1
test_parity_reports_no_difference || result=1
test_tampering_is_reported_and_healed || result=1
test_an_unrun_parity_is_never_green || result=1
test_stop_leaves_nothing_running || result=1
exit "$result"

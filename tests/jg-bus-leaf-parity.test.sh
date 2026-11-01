#!/usr/bin/env bash
# A remote squad_lead home on the home bus over a NATS leaf node, in shadow
# (docs/bus-leaf-shadow.md): the same task, status and wake events must reach the
# same home in the same order over the SSH path and the leaf path, and one event
# deliberately corrupted on the leaf path must make that comparison fail, so a
# green replay is never vacuous.
#
# The test runs throwaway servers on free ports, writes both legs into their own
# directories under the test's temp root, and never touches this machine's bus, a
# real home, or a real SSH host: the ssh process boundary is a local executable
# that runs the same argv the transport produces, and it records that argv so the
# assertion can prove the replay really went through bin/jg-on.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NATS_SERVER=${JG_NATS_SERVER:-$(command -v nats-server 2>/dev/null || true)}
NATS_BIN=${JG_NATS_BIN:-$(command -v nats 2>/dev/null || true)}
if [ -z "$NATS_SERVER" ]; then
  echo "skip: nats-server not found (set JG_NATS_SERVER)"
  exit 0
fi
if [ -z "$NATS_BIN" ]; then
  echo "skip: nats client not found (set JG_NATS_BIN)"
  exit 0
fi

DIR=$(jg_test_tmproot jg-bus-leaf-parity)
MAIN_HOME="$DIR/main-home"
LEAD_HOME="$DIR/lead-home"
STATE_DIR="$MAIN_HOME/state"
PARITY_DIR="$DIR/parity"
FAKEBIN=$(jg_fakebin "$DIR/fakebin")
SSH_LOG="$DIR/ssh.log"
mkdir -p "$MAIN_HOME/data" "$MAIN_HOME/config/bus" "$STATE_DIR" "$LEAD_HOME/state"

# The home's bus file, as a home that runs its own bus has one: free ports, so the
# test never assumes 4222 or 7422 is free on the machine running it.
cat >"$MAIN_HOME/config/bus/nats.conf" <<'CONF'
host: "127.0.0.1"
port: -1
server_name: parity-hub
jetstream { store_dir: "./jetstream" }
CONF

# The leaf's own configuration file, which is the whole point of the step: the
# listener side and the remote side are read from a file, not a command line.
cat >"$MAIN_HOME/config/bus-leaf" <<'CONF'
set leaf-listen 127.0.0.1:-1
set hub-leaf-listen 127.0.0.1:-1
CONF

# A remote route in this home's registry. The host alias is what the ssh boundary
# receives; the root is this checkout, because the shim below runs the command on
# this host.
cat >"$MAIN_HOME/data/squad_leads.md" <<EOF
- lane - parity lead (host: remote-parity; root: $ROOT; home: $LEAD_HOME; scope: parity work; projects: alpha; added 2026-11-01)
EOF

# The ssh process boundary: the exact argv jg-on.sh hands ssh, executed here. It
# refuses a different host or entrypoint, so a replay that stopped using the real
# transport fails instead of quietly passing.
cat >"$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) printf 'unexpected ssh argument: %s\n' "$1" >&2; exit 90 ;;
  esac
done
[ "$#" -eq 6 ] || { printf 'unexpected ssh argv count: %s\n' "$#" >&2; exit 91; }
host=$1 entry=$2 proto=$3 root_b64=$4 home_b64=$5 argv_b64=$6
[ "$host" = remote-parity ] || exit 92
[ "$entry" = jg-remote-entrypoint.sh ] || exit 93
[ "$proto" = 1 ] || exit 94
printf '%s %s\n' "$host" "$entry" >> "$JG_FAKE_SSH_LOG"
root=$(printf '%s' "$root_b64" | base64 --decode 2>/dev/null || printf '%s' "$root_b64" | base64 -D)
home=$(printf '%s' "$home_b64" | base64 --decode 2>/dev/null || printf '%s' "$home_b64" | base64 -D)
printf '%s' "$argv_b64" | base64 --decode 2>/dev/null > "$JG_FAKE_SSH_DIR/argv.bin" \
  || printf '%s' "$argv_b64" | base64 -D > "$JG_FAKE_SSH_DIR/argv.bin"
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < "$JG_FAKE_SSH_DIR/argv.bin"
[ "${#args[@]}" -ge 1 ] || exit 95
command=${args[0]#*/}
case "$command" in jg-*.sh) ;; *) exit 96 ;; esac
JG_HOME=$home JG_ROOT_OVERRIDE=$root exec "$root/bin/$command" ${args[@]+"${args[@]:1}"}
SH
chmod +x "$FAKEBIN/fake-ssh"

leaf() { # the one command surface, scoped to this test's home and binaries
  JG_HOME="$MAIN_HOME" JG_STATE_OVERRIDE="$STATE_DIR" \
    JG_NATS_SERVER="$NATS_SERVER" JG_NATS_BIN="$NATS_BIN" \
    JG_SSH_BIN="$FAKEBIN/fake-ssh" JG_FAKE_SSH_LOG="$SSH_LOG" JG_FAKE_SSH_DIR="$DIR" \
    "$ROOT/bin/jg-bus-leaf.sh" "$@"
}

# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() {
  leaf stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

test_leaf_connects_configured_by_file() {
  local out hub_leaf
  out=$(leaf config hub-leaf-listen 2>&1) || fail "the leaf configuration was not readable: $out"
  assert_equals 127.0.0.1:-1 "$out" "the home's leaf configuration file must decide the listener"
  out=$(leaf serve hub 2>&1) || fail "the hub side did not start: $out"
  hub_leaf=$(cat "$STATE_DIR/bus-leaf/hub.leaf-url" 2>/dev/null) \
    || fail "the hub side never reported its leaf listener"
  out=$(JG_BUS_LEAF_HUB_LEAF_DIAL="$hub_leaf" leaf serve leaf 2>&1) \
    || fail "the leaf side did not start: $out"
  grep -q "nats-leaf://juggernaut-leaf:juggernaut-leaf@$hub_leaf" "$STATE_DIR/bus-leaf/leaf.conf" \
    || fail "the rendered leaf configuration did not dial the hub's leaf listener"
  out=$(timeout 20 sed -n 's/.*Leafnode connection created.*/connected/p' "$STATE_DIR/bus-leaf/hub.log" | head -n 1)
  [ "$out" = connected ] || fail "the hub never reported a leafnode connection"
  leaf stop >/dev/null 2>&1
  pass "one configuration file brings a remote home onto the home bus as a leaf node"
}

test_both_paths_agree_row_by_row() {
  local out rows
  out=$(leaf parity --route lane --state "$PARITY_DIR" 2>&1) || { echo "$out"; fail "parity failed on an uncorrupted replay"; }
  assert_contains "$out" "rows=7" "both paths must carry the whole event set"
  assert_contains "$out" "differences=0" "the two paths must agree row by row"
  rows=$(awk 'END { print NR }' "$PARITY_DIR/ssh/bus-leaf-view.tsv")
  assert_equals 7 "$rows" "the SSH leg must record every event it delivered"
  cmp -s "$PARITY_DIR/ssh/bus-leaf-view.tsv" "$PARITY_DIR/leaf/bus-leaf-view.tsv" \
    || fail "the two ordered views differ"
  assert_equals "$(cat "$PARITY_DIR/leaf/bus-leaf-view.tsv")" "$(leaf dump --state "$PARITY_DIR/leaf")" \
    "dump must print the ordered view the leg recorded"
  assert_grep 'remote-parity jg-remote-entrypoint.sh' "$SSH_LOG" "the replay did not go through the SSH transport"
  pass "the same seven events reach the same home in the same order over both paths"
}

test_every_event_lands_on_the_leads_own_surfaces() {
  local leg
  for leg in ssh leaf; do
    [ -f "$PARITY_DIR/$leg/lane-a.inbox/001.msg" ] \
      || fail "the $leg leg left no steering record for the first task event"
    assert_grep 'do the first thing' "$PARITY_DIR/$leg/lane-a.inbox/001.msg" \
      "the $leg leg's steering record does not carry its payload"
    assert_grep 'working: first step' "$PARITY_DIR/$leg/lane-a.status" \
      "the $leg leg did not append its status line"
    assert_grep 'signal: crew.remote' "$PARITY_DIR/$leg/.wake-queue" \
      "the $leg leg did not raise its wake row"
  done
  pass "each leg applies the events to the lead's own steering, status and wake records"
}

test_a_value_that_could_break_the_configuration_is_refused() {
  local out status=0
  out=$(JG_BUS_LEAF_LEAF_PASS='bad"pass' leaf serve leaf 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a configuration value that could close its string was accepted"
  assert_contains "$out" 'config key leaf-pass has an unsafe value' "the refusal must name the key"
  assert_not_contains "$out" 'nats-server not found' "the render reached the server instead of refusing"
  status=0
  out=$(leaf apply 1 task lane-a payload 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "apply without an explicit --state was accepted"
  assert_contains "$out" 'apply needs --state' "apply must refuse to guess the home it writes into"
  pass "an unsafe configuration value and an unstated home are both refused"
}

test_corruption_is_reported() {
  local out status=0
  out=$(leaf parity --route lane --state "$PARITY_DIR/corrupt" --corrupt 2>&1) || status=$?
  [ "$status" -ne 0 ] || { echo "$out"; fail "parity passed after one leaf event was corrupted"; }
  assert_contains "$out" "corrupted by the parity test" "the difference must name the corrupted payload"
  assert_not_contains "$out" "differences=0" "a corrupted event must never report no difference"
  pass "one corrupted event on the leaf path fails the same comparison"
}

result=0
test_leaf_connects_configured_by_file || result=1
test_both_paths_agree_row_by_row || result=1
test_every_event_lands_on_the_leads_own_surfaces || result=1
test_a_value_that_could_break_the_configuration_is_refused || result=1
test_corruption_is_reported || result=1
exit "$result"

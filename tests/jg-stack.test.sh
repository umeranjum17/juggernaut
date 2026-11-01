#!/usr/bin/env bash
# The one install command brings the whole stack up on a clean HOME and says so per part
# (bin/jg-stack.sh): a second run changes nothing, and a part that cannot start stops the run
# with one line naming it and what it blocks.
#
# It uses a throwaway HOME (so every tool installs fresh from its pinned release), its own
# ports and its own store, never this machine's real bus. It skips when the pinned releases
# cannot be reached or there is no Go toolchain to build the command; the CI bus lane has both.
#
# This is also the test that owns journeys/stack-install.sh (the done-done journey runs this file),
# so the changed-test map selects it for a change to that journey.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v go >/dev/null 2>&1 || { echo "skip: no go toolchain to build the bus command"; exit 0; }
curl -fsSI --max-time 15 https://github.com >/dev/null 2>&1 || { echo "skip: the pinned releases cannot be reached"; exit 0; }

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# The command this test runs is the one docs/bus-service.md tells a home to run.
grep -Fq 'bin/jg-stack.sh up ' "$ROOT/docs/bus-service.md" || fail "docs/bus-service.md no longer documents bin/jg-stack.sh up"
pass "stack: the documented one-install command is bin/jg-stack.sh up"

T=$(jg_test_tmproot jg-stack)
export HOME="$T/home" JG_HOME="$T/jg" JG_STACK_SUPERVISOR=detached
unset JG_STACK_SKIP JG_BUS_BIN JG_STATE_OVERRIDE JG_STATE JG_ROOT_OVERRIDE NPM_CONFIG_PREFIX XDG_CONFIG_HOME
export GOCACHE="$T/gocache" GOFLAGS=-mod=mod
mkdir -p "$HOME" "$JG_HOME/config/bus/dapr/components"
# The bare minimum PATH: no tool the install should provide may come from the host.
PATH="$(dirname "$(command -v go)"):/usr/bin:/bin"; export PATH
# Below the kernel's ephemeral range (32768+), so no outgoing connection can be sitting on a port a service binds.
free_port() { local p; for p in $(seq "$1" $(($1 + 90))); do (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null || { echo "$p"; return; }; done; }
NATS=$(free_port 26100) DAPR=$(free_port 26200) GRPC=$(free_port 26300) NTFY=$(free_port 26400)
cleanup() { "$ROOT/bin/jg-bus.sh" stop >/dev/null 2>&1; jg_test_cleanup; }
trap cleanup EXIT

printf 'set nats-url nats://127.0.0.1:%s\nset dapr-http-port %s\nset dapr-http-url http://127.0.0.1:%s\nset dapr-grpc-port %s\nset ntfy-server http://127.0.0.1:%s\n' \
  "$NATS" "$DAPR" "$DAPR" "$GRPC" "$NTFY" > "$JG_HOME/config/captain-channel"
sed "s/4222/$NATS/" "$ROOT/core/bus/nats.conf" > "$JG_HOME/config/bus/nats.conf"
sed "s/2586/$NTFY/g" "$ROOT/core/bus/ntfy.yml" > "$JG_HOME/config/bus/ntfy.yml"
sed "s/4222/$NATS/" "$ROOT/core/bus/dapr/components/pubsub.yaml" > "$JG_HOME/config/bus/dapr/components/pubsub.yaml"

first=$("$ROOT/bin/jg-stack.sh" up 2>&1); rc=$?
[ "$rc" = 0 ] || fail "the first run exited $rc: $first"
printf '%s\n' "$first" | grep -q '^jg-bus built, state ' || fail "the Go command was not reported built: $first"
[ -s "$ROOT/core/bus/accounts.conf" ] || fail "the accounts file is missing"
for part in nats dapr ntfy; do
  printf '%s\n' "$first" | grep -Eq "^$part +installed [0-9.]+, enabled .*, running pid [0-9]+, listening 127.0.0.1:" \
    || fail "$part was not reported installed, enabled, running with a pid and listening: $first"
done
printf '%s\n' "$first" | grep -Eq '^deliver +enabled .*, running pid [0-9]+, consuming CAPTAIN$' \
  || fail "the CAPTAIN stream consumer was not reported running with a pid: $first"
for part in wake-engine wake-watcher router; do
  printf '%s\n' "$first" | grep -Eq "^$part +installed jg-bus, enabled .*, running pid [0-9]+, consuming (JG_WAKE|CAPTAIN)/$part\$" \
    || fail "$part was not reported running with a pid and its consumer: $first"
done
pass "stack: the first run reports nats, dapr and ntfy installed, enabled, running with a pid, listening, and the stream consumers (deliver, wake engine, wake watcher, router) running"
printf '%s\n' "$first" | grep -q '^stream CAPTAIN exists' || fail "the CAPTAIN stream was not confirmed: $first"
for pid in $(printf '%s\n' "$first" | sed -n 's/.*running pid \([0-9]*\),.*/\1/p'); do
  kill -0 "$pid" 2>/dev/null || fail "reported pid $pid is not a live process"
done
pass "stack: every reported pid is a live process and the stream exists"

second=$("$ROOT/bin/jg-stack.sh" up 2>&1); rc=$?
[ "$rc" = 0 ] || fail "the second run exited $rc: $second"
[ "$first" = "$second" ] || fail "the second run changed something: $(diff <(printf '%s\n' "$first") <(printf '%s\n' "$second"))"
pass "stack: a second run prints the same lines and the same pids, changing nothing"

# The stack carries a real captain event bus -> ntfy: the probe publishes one through the sidecar, and
# exits 0 only when the stream count rose and both the delivery record and ntfy's own log name it.
probe=$("$ROOT/bin/jg-captain-probe.sh" 2>&1); rc=$?
[ "$rc" = 0 ] || fail "the live probe exited $rc: $probe"
printf '%s\n' "$probe" | grep -Eq '^probe: PASS bus -> ntfy, stream [0-9]+ -> [0-9]+, message [A-Za-z0-9]+$' || fail "the probe did not prove bus -> ntfy: $probe"
pass "stack: a real captain event travels the CAPTAIN stream to ntfy, with a delivery record and ntfy's own log line"

# A part that cannot run stops the run with one line naming it and what it blocks.
"$ROOT/bin/jg-bus.sh" stop >/dev/null 2>&1
printf 'this is not valid ntfy config: [\n' > "$JG_HOME/config/bus/ntfy.yml"
broken=$("$ROOT/bin/jg-stack.sh" up 2>&1); rc=$?
[ "$rc" = 1 ] || fail "a part that cannot start exited $rc, not 1: $broken"
[ "$(printf '%s\n' "$broken" | grep -c '^STACK_FAILED:')" = 1 ] || fail "not exactly one failure line: $broken"
printf '%s\n' "$broken" | grep -q '^STACK_FAILED: ntfy: .*; blocks delivery to the captain' || fail "the failure did not name ntfy and what it blocks: $broken"
printf '%s\n' "$broken" | grep -q '^stack: up' && fail "a failed run still claimed the stack is up: $broken"
pass "stack: a part that cannot start stops the run with one line naming it and what it blocks"

#!/usr/bin/env bash
# Behavior test for bin/jg-stray-nats-reap.sh - the reaper for leftover throwaway nats-servers.
# The stray-nats-reap journey of .done-done.yaml runs this test, so a change to it selects this test.
# It starts its own fake servers (an executable named nats-server that only waits for TERM) in a
# throwaway root, and proves: a dry run lists and stops nothing; --stop stops exactly the
# old servers whose config or store path is below the allowlist root, found by absolute path,
# by a path relative to the process's own directory, and by store directory alone; and a
# live home's bus server, a server outside the allowlist, a young server, and a process that
# is not named nats-server are all left running. --root confines every case to this test's root,
# so no real server on the machine can be listed as a candidate or stopped.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REAP=$ROOT/bin/jg-stray-nats-reap.sh
T=$(jg_test_tmproot jg-stray-nats)
OUT=$(jg_test_tmproot jg-stray-nats-out)
mkdir -p "$T/fake" "$OUT/fake"
for d in "$T/fake" "$OUT/fake"; do
  printf '#!/bin/bash\ntrap "exit 0" TERM\nwhile :; do sleep 0.2; done\n' >"$d/nats-server"
  chmod +x "$d/nats-server"
done
cp "$T/fake/nats-server" "$T/fake/other-server"

pids=()
cleanup() { local p; if [ "${#pids[@]}" -gt 0 ]; then for p in "${pids[@]}"; do kill -9 "$p" 2>/dev/null || true; done; fi; jg_test_cleanup; }
trap cleanup EXIT INT TERM
alive() { kill -0 "$1" 2>/dev/null; }
start() { # <dir> <program> <argv>...: run it with <dir> as its directory; the pid lands in $pid
  local dir=$1 prog=$2
  shift 2
  mkdir -p "$dir"
  (cd "$dir" && exec "$prog" "$@") >/dev/null 2>&1 </dev/null &
  pid=$! pids+=("$pid")
}

start "$T/old-abs" "$T/fake/nats-server" -c "$T/old-abs/bus.conf";          abs=$pid
start "$T/old-rel" "$T/fake/nats-server" -c bus.conf;                        rel=$pid
start "$T/old-store" "$T/fake/nats-server" -js -p 4999 -sd t1/store;         store=$pid
start "$T/old-dots" "$T/fake/nats-server" --config "$T/old-dots/x/../bus.conf"; dots=$pid
start "$T/home/state/bus" "$T/fake/nats-server" -c bus.conf;                 inhome=$pid
start "$T/jghome/state/bus" "$T/fake/nats-server" -c bus.conf;               envhome=$pid
start "$OUT/old" "$OUT/fake/nats-server" -c "$OUT/old/bus.conf";             outside=$pid
start "$T/not-nats" "$T/fake/other-server" -c "$T/not-nats/bus.conf";        other=$pid
mkdir -p "$T/home/bin" && : >"$T/home/bin/jg-bus.sh"
sleep 0.4

# Every fake must show up as a server in the process table, or the cases below prove nothing.
ps -o comm= -p "$abs" | grep -qx nats-server || fail "fixture: the fake server is not named nats-server in the process table"

# --- default age: every fake server is young, so nothing is a candidate ---------------
young=$("$REAP" --root "$T")
assert_contains "$young" "skip $abs too-young $T/old-abs/bus.conf" "a young server is skipped with its reason: $young"
assert_contains "$young" "0 stray nats-server(s)" "no candidate among young servers: $young"
pass "a server younger than the minimum age is left alone"

# --- dry run: lists, stops nothing ------------------------------------------------------
dry=$(JG_HOME="$T/jghome" "$REAP" --root "$T" --min-age-minutes 0)
assert_contains "$dry" "would stop $abs age=0m $T/old-abs/bus.conf" "absolute config path: $dry"
assert_contains "$dry" "would stop $rel age=0m $T/old-rel/bus.conf" "config path relative to the process directory: $dry"
assert_contains "$dry" "would stop $store age=0m $T/old-store/t1/store" "store directory alone: $dry"
assert_contains "$dry" "would stop $dots age=0m $T/old-dots/bus.conf" "dots in the path are collapsed: $dry"
assert_contains "$dry" "skip $inhome live-home $T/home/state/bus/bus.conf" "a real home's bus server is skipped inside the allowlist: $dry"
assert_contains "$dry" "skip $envhome live-home $T/jghome/state/bus/bus.conf" "the JG_HOME bus server is skipped: $dry"
assert_contains "$dry" "skip $outside outside-allowlist $OUT/old/bus.conf" "a server outside the allowlist is skipped: $dry"
assert_not_contains "$dry" "$other" "a process not named nats-server is not listed: $dry"
assert_contains "$dry" "4 stray nats-server(s)" "four candidates: $dry"
assert_contains "$dry" "dry run: nothing stopped" "the default is a dry run: $dry"
for p in "$abs" "$rel" "$store" "$dots" "$inhome" "$envhome" "$outside" "$other"; do alive "$p" || fail "the dry run stopped $p"; done
pass "the dry run lists the stray servers and the skipped ones and stops nothing"

# --- --stop: stops exactly the candidates -----------------------------------------------
go=$(JG_HOME="$T/jghome" "$REAP" --stop --root "$T" --min-age-minutes 0)
assert_contains "$go" "will stop $abs age=0m" "the full list is printed before anything stops: $go"
assert_contains "$go" "stopped $abs $T/old-abs/bus.conf" "stopped line: $go"
sleep 0.3
for p in "$abs" "$rel" "$store" "$dots"; do ! alive "$p" || fail "the stray server $p is still running"; done
for p in "$inhome" "$envhome" "$outside" "$other"; do alive "$p" || fail "the reaper stopped $p, which it must leave alone"; done
pass "--stop stops the stray servers and leaves the live home, the outside server and the other process running"

again=$(JG_HOME="$T/jghome" "$REAP" --stop --root "$T" --min-age-minutes 0)
assert_contains "$again" "0 stray nats-server(s)" "a second pass has nothing left to stop: $again"
pass "a second pass finds nothing"

"$REAP" --bogus >/dev/null 2>&1 && fail "an unknown flag must be refused"
"$REAP" --root rel/path >/dev/null 2>&1 && fail "a relative --root must be refused"
pass "bad arguments are refused"

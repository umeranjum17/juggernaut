#!/usr/bin/env bash
# One bus owner per machine: dapr is one per machine, so only the home that owns the machine's bus
# unit installs, enables and starts it, and retires the ntfy and consumer units an earlier release left.
# Any other home that runs `bin/jg-stack.sh up` reports it, names the owner, and changes nothing.
#
# It runs the real bin/jg-stack.sh in a copy of the repo's bin with a stand-in bus command (which
# answers `owner`), a stand-in tool installer and a systemctl that logs every call, so no service,
# unit directory or port of this machine is touched. The owner run in the same fixture proves the
# stand-ins make the install path run, so the non-owner's silence is not a vacuous pass.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v python3 >/dev/null 2>&1 || { echo "skip: no python3 for the listener"; exit 0; }

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(jg_test_tmproot jg-stack-owner)
mkdir -p "$T/repo/bin" "$T/repo/core/bus" "$T/fakebin" "$T/xdg" "$T/home" "$T/state"
cp "$ROOT/bin/jg-stack.sh" "$ROOT/bin/jg-pin-lib.sh" "$ROOT/bin/jg-lab-home-lib.sh" "$T/repo/bin/"
[ ! -f "$ROOT/bin/jg-compat.sh" ] || cp "$ROOT/bin/jg-compat.sh" "$T/repo/bin/"
cp "$ROOT/toolchain.versions" "$T/repo/"
printf '{"name": "CAPTAIN"}\n' > "$T/repo/core/bus/stream.json"

# One listener answers for every part's address.
python3 -c 'import socket,sys
s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(8)
open(sys.argv[1],"w").write(str(s.getsockname()[1]))
while True: s.accept()' "$T/port" >/dev/null 2>&1 &
LISTENER=$!
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
stop_listener() { kill "$LISTENER" 2>/dev/null || true; jg_test_cleanup; }
trap stop_listener EXIT
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
PORT=$(cat "$T/port"); [ -n "$PORT" ] || fail "the listener never started"

cat > "$T/repo/bin/jg-bus.sh" <<EOF
#!/usr/bin/env bash
echo "bus \$*" >> "$T/calls"
case "\$1" in
  owner) if [ -n "\${FIXTURE_OWNER:-}" ]; then echo "\$FIXTURE_OWNER"; exit 3; fi; echo self ;;
  config) case "\$2" in stream) echo CAPTAIN ;; dapr-http-port) echo $PORT ;; *) echo "http://127.0.0.1:$PORT" ;; esac ;;
  unit) printf '[Service]\n# %s\n' "\${2:-nats}" ;;
  *) : ;;
esac
EOF
cat > "$T/repo/bin/jg-bootstrap.sh" <<EOF
#!/usr/bin/env bash
case "\$1" in
  version) [ ! -e "$T/have-\$2" ] || echo 999.0.0 ;;
  install) echo "install \$2" >> "$T/calls"; : > "$T/have-\$2" ;;
esac
EOF
cat > "$T/fakebin/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$T/calls"
case "\$*" in
  *is-enabled*) echo enabled ;;
  *"show -p MainPID"*) echo "$LISTENER" ;;
esac
exit 0
EOF
chmod +x "$T"/repo/bin/*.sh "$T/fakebin/systemctl"

stack() {  # <owner or empty> -> output of one `up`; calls land in $T/calls
  : > "$T/calls"; [ -n "${KEEP_UNITS:-}" ] || rm -rf "$T/xdg/systemd"; rm -f "$T"/have-*; : > "$T/have-nats-server"; : > "$T/have-nats"
  env -u JG_STACK_SKIP PATH="$T/fakebin:$PATH" HOME="$T/home" XDG_CONFIG_HOME="$T/xdg" JG_HOME="$T/repo" JG_STATE_OVERRIDE="$T/state" \
    JG_STACK_SUPERVISOR=systemd FIXTURE_OWNER="${1:-}" "$T/repo/bin/jg-stack.sh" up 2>&1
}

owned=$(stack "")
assert_contains "$owned" "stack: up (systemd)" "the owner's run did not finish: $owned"
assert_contains "$(cat "$T/calls")" "systemctl --user enable jg-dapr.service" "the owner did not enable dapr"
[ -f "$T/xdg/systemd/user/jg-dapr.service" ] || fail "the owner did not write the dapr unit"
assert_contains "$(cat "$T/calls")" "install daprd" "the owner did not install daprd"
! grep -Eq 'install ntfy$|bus ntfy-provision' "$T/calls" || fail "the owner still installs or provisions ntfy"

other=$(stack "/another/home")
assert_contains "$other" "stack: up (systemd)" "the non-owner's run did not finish: $other"
assert_contains "$other" "dapr: owned by /another/home" "the non-owner was not told who owns dapr"
[ ! -e "$T/xdg/systemd/user/jg-dapr.service" ] || fail "a non-owner wrote the dapr unit"
! grep -Eq "systemctl --user (enable|start|restart) jg-dapr\.service" "$T/calls" || fail "a non-owner changed jg-dapr.service"
! grep -Eq 'install daprd$' "$T/calls" || fail "a non-owner installed a one-per-machine tool"
pass "stack: only the bus owner installs and starts dapr; any other home reports it and changes nothing"

# A home that still has the old ntfy wiring: the owner's run retires the units, a non-owner's leaves them.
old_wiring() {
  mkdir -p "$T/xdg/systemd/user"
  for part in ntfy deliver; do printf '[Service]\n' > "$T/xdg/systemd/user/jg-$part.service"; done
  mkdir -p "$T/state/bus"; : > "$T/state/bus/ntfy.log"; : > "$T/state/bus/deliver.pid"
}
old_wiring
other=$(KEEP_UNITS=1 stack "/another/home")
[ -f "$T/xdg/systemd/user/jg-ntfy.service" ] || fail "a non-owner removed the machine's ntfy unit"
old_wiring
owned=$(KEEP_UNITS=1 stack "")
assert_contains "$owned" "stack: up (systemd)" "a home with the old wiring did not end clean: $owned"
for part in ntfy deliver; do
  assert_contains "$(cat "$T/calls")" "systemctl --user disable --now jg-$part.service" "the old $part unit was not stopped"
  [ ! -e "$T/xdg/systemd/user/jg-$part.service" ] || fail "the old $part unit file is still there"
done
[ -z "$(find "$T/state/bus" -name 'ntfy*' -o -name 'deliver*')" ] || fail "runtime files of the old wiring are still there"
owned=$(KEEP_UNITS=1 stack "")
! grep -q 'retired' <<<"$owned" || fail "a second run retired something again: $owned"
pass "stack: a home with the old ntfy wiring ends clean, the retirement runs once, and a non-owner leaves the machine's units alone"

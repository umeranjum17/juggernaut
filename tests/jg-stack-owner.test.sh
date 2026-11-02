#!/usr/bin/env bash
# One bus owner per machine: dapr, ntfy and the CAPTAIN consumer are one per machine, so only the home
# that owns the machine's bus unit installs, enables and starts them and makes the ntfy logins.
# Any other home that runs `bin/jg-stack.sh up` reports them, names the owner, and changes nothing.
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
cp "$ROOT/bin/jg-stack.sh" "$ROOT/bin/jg-pin-lib.sh" "$T/repo/bin/"
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
  : > "$T/calls"; rm -rf "$T/xdg/systemd"; rm -f "$T"/have-*; : > "$T/have-nats-server"; : > "$T/have-nats"
  env -u JG_STACK_SKIP PATH="$T/fakebin:$PATH" HOME="$T/home" XDG_CONFIG_HOME="$T/xdg" JG_HOME="$T/repo" JG_STATE_OVERRIDE="$T/state" \
    JG_STACK_SUPERVISOR=systemd FIXTURE_OWNER="${1:-}" "$T/repo/bin/jg-stack.sh" up 2>&1
}

owned=$(stack "")
assert_contains "$owned" "stack: up (systemd)" "the owner's run did not finish: $owned"
for part in dapr ntfy deliver; do
  assert_contains "$(cat "$T/calls")" "systemctl --user enable jg-$part.service" "the owner did not enable $part"
  [ -f "$T/xdg/systemd/user/jg-$part.service" ] || fail "the owner did not write the $part unit"
done
assert_contains "$(cat "$T/calls")" "install daprd" "the owner did not install daprd"
assert_contains "$(cat "$T/calls")" "bus ntfy-provision" "the owner did not make the ntfy logins"

other=$(stack "/another/home")
assert_contains "$other" "stack: up (systemd)" "the non-owner's run did not finish: $other"
for part in dapr ntfy deliver; do
  assert_contains "$other" "$part: owned by /another/home" "the non-owner was not told who owns $part"
  [ ! -e "$T/xdg/systemd/user/jg-$part.service" ] || fail "a non-owner wrote the $part unit"
  ! grep -Eq "systemctl --user (enable|start|restart) jg-$part\.service" "$T/calls" || fail "a non-owner changed jg-$part.service"
done
! grep -Eq 'install (daprd|ntfy)$' "$T/calls" || fail "a non-owner installed a one-per-machine tool"
! grep -q 'bus ntfy-provision' "$T/calls" || fail "a non-owner made the ntfy logins"
pass "stack: only the bus owner installs, starts and provisions dapr, ntfy and the consumer; any other home reports them and changes nothing"

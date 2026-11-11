#!/usr/bin/env bash
# The machine's one bus comes up from the generated config and every home logs in:
#
#   1. install-service for TWO homes on one lab server: the account the server loads and
#      the login each home's client uses come from one function, so after the account
#      rename (#415) both homes pass `ensure` (stream created, authentication ok).
#      One home owns the machine unit. The other homes' bootstrap (`unit nats`, which
#      bin/jg-stack.sh up runs) and update (`install-service`) paths only add their account
#      and have the server reload it: the owner's unit file and bus.conf stay byte for byte
#      the same, nothing restarts, and the owner's client still authenticates. A home that
#      would push the account count past the caps is refused, naming the owner.
#      An account taken away restarts the server, because a reload keeps its JetStream
#      reservation, and a fixture home never reaches a real owner's accounts file.
#   2. the JetStream limits arithmetic with 21 accounts: the generated caps cover what the
#      21 accounts reserve plus headroom, and a real server starts on them. The 384Mb cap
#      the incident wrote (insufficient memory resources, 10028) is refused by
#      `check-limits` and by the generator, and the server itself refuses it.
#
# Everything runs in a lab: its own free random port, its own store directory, a fake
# systemctl that stands in for the user manager, and a unit name of its own. It never
# touches port 4222, the machine's service or the machine's state/bus files.
#
# This is also the test that owns journeys/bus-machine-service.sh (the done-done journey runs this
# file), so the changed-test map selects it for a change to that journey.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NATS_SERVER=${JG_NATS_SERVER:-$(command -v nats-server 2>/dev/null || true)}
NATS_BIN=${JG_NATS_BIN:-$(command -v nats 2>/dev/null || true)}
[ -n "$NATS_SERVER" ] || { echo "skip: nats-server not found (set JG_NATS_SERVER)"; exit 0; }
[ -n "$NATS_BIN" ] || { echo "skip: nats client not found (set JG_NATS_BIN)"; exit 0; }
if [ -z "${JG_BUS_BIN:-}" ] && ! command -v go >/dev/null 2>&1; then
  echo "skip: no go toolchain to build the bus command (set JG_BUS_BIN)"
  exit 0
fi

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Servers an earlier run left behind after its directory went (a hard kill skips every trap).
"$ROOT/bin/jg-bus-reap.sh" >/dev/null 2>&1 || true
D=$(jg_test_tmproot jg-bus-machine)
BUS="$ROOT/bin/jg-bus.sh"

free_port() {
  python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()' 2>/dev/null
}
PORT=$(free_port) || { echo "skip: no free local port for the lab"; exit 0; }
[ "$PORT" != 4222 ] || fail "the lab drew the machine's own bus port"

# The lab's tools: the real server and client, and a systemctl of its own, so the unit
# path runs end to end without the machine's user manager ever hearing of it.
LAB_BIN="$D/bin"; mkdir -p "$LAB_BIN" "$D/xdg" "$D/store" "$D/homes"
ln -sf "$NATS_SERVER" "$LAB_BIN/nats-server"
# The lab's nats records every argument list it is called with (what `ps` shows every user on
# the machine) before it runs the real client, so section 1d can prove no call carries a login.
cat > "$LAB_BIN/nats" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$D/nats-argv.log"
exec "$NATS_BIN" "\$@"
EOF
chmod +x "$LAB_BIN/nats"
cat > "$LAB_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
# Lab systemctl: only the verbs install-service and status use, over the lab's own
# units, run as plain processes.
unitdir="$XDG_CONFIG_HOME/systemd/user"
unit="$unitdir/$JG_BUS_UNIT"
pidfile="$LAB_DIR/service.pid"
alive() { [ -s "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; }
start() {
  local cwd
  cwd=$(sed -n 's/^WorkingDirectory=//p' "$unit")
  cd "$cwd" || exit 1
  eval "set -- $(sed -n 's/^ExecStart=//p' "$unit")"
  setsid "$@" > "$LAB_DIR/server.log" 2>&1 < /dev/null &
  echo $! > "$pidfile"
  for _ in $(seq 100); do (: < "/dev/tcp/127.0.0.1/$LAB_PORT") 2>/dev/null && return 0; sleep 0.1; done
  return 1
}
stop() { alive && kill "$(cat "$pidfile")"; for _ in $(seq 50); do alive || return 0; sleep 0.1; done; }
[ "${1:-}" != --user ] || shift
case "${1:-}" in
  show-environment|daemon-reload|enable-only) exit 0 ;;
  show) # `status` reads one unit's own state from the manager, and only that.
    name=${!#}
    if [ -f "$unitdir/$name" ]; then load=loaded; else load=not-found; fi
    if [ "$name" = "$JG_BUS_UNIT" ]; then
      alive && active=active || active=inactive
    elif [ -f "$LAB_DIR/units/$name.active" ]; then active=active
    else active=inactive; fi
    printf 'LoadState=%s\nActiveState=%s\n' "$load" "$active"
    ;;
  enable) alive || start ;;
  is-active) alive ;;
  restart) stop; start ;;
  kill) alive && kill -HUP "$(cat "$pidfile")" && echo reload >> "$LAB_DIR/systemctl.log" ;;
  *) echo "lab systemctl: unsupported: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$LAB_BIN/systemctl"
# Lab journalctl: the server's log since a reload, which reads as a failed JetStream
# restore only while the lab holds js-fail.
cat > "$LAB_BIN/journalctl" <<'EOF'
#!/usr/bin/env bash
[ ! -e "$LAB_DIR/js-fail" ] || echo "[ERR] Error enabling jetstream on configured accounts: insufficient memory resources available (10028)"
exit 0
EOF
chmod +x "$LAB_BIN/journalctl"
export LAB_DIR="$D" LAB_PORT="$PORT" XDG_CONFIG_HOME="$D/xdg" JG_STACK_UNIT_PREFIX="jg-lab-$$" \
  JG_BUS_UNIT="jg-lab-$$-bus.service"
PATH="$LAB_BIN:$PATH"; export PATH

# stop_lab: stop only the server this lab's systemctl started, by the pid it recorded.
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
stop_lab() {
  if [ -s "$D/service.pid" ]; then kill "$(cat "$D/service.pid")" 2>/dev/null || true; fi
  if [ -s "$D/solo.pid" ]; then kill "$(cat "$D/solo.pid")" 2>/dev/null || true; fi
  local f
  for f in "$D"/reap-*.pid; do
    [ ! -s "$f" ] || kill "$(cat "$f")" 2>/dev/null || true
  done
}
# The servers stop before the shared cleanup removes $D (and the pid files in it): a signal
# used to remove the directory first, so the stop found no pid and the server outlived the run.
# shellcheck disable=SC2329 # Registered by the traps below.
lab_exit() {
  stop_lab
  [ -z "${REAL:-}" ] || rm -rf -- "$REAL"
  jg_test_cleanup
}
trap lab_exit EXIT
trap 'lab_exit; exit 130' INT
trap 'lab_exit; exit 143' TERM
trap 'lab_exit; exit 129' HUP
trap 'lab_exit; exit 131' QUIT

make_home() { # <dir>
  mkdir -p "$1/state" "$1/data" "$1/config/bus"
  printf 'set nats-url nats://127.0.0.1:%s\n' "$PORT" > "$1/config/captain-channel"
  cat > "$1/config/bus/nats.conf" <<EOF
host: "127.0.0.1"
port: $PORT
server_name: jg-bus-machine-test
jetstream {
  store_dir: "$D/store"
  max_mem_store: 8Mb
  max_file_store: 8Mb
}
EOF
}
bus() { local h=$1; shift; JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" JG_DATA_OVERRIDE="$h/data" timeout 120 "$BUS" "$@"; }

# --- 1. two homes, one server, one owner ------------------------------------------
H1="$D/homes/one"; H2="$D/homes/two"; H3="$D/homes/three"; H4="$D/homes/four"; H5="$D/homes/five"
make_home "$H1"
# One of the registered Squad Leads is a real home, as on a machine: Main's registry names it,
# and it keeps no registry of its own.
LEAD2="$D/leads/lead-2"
make_home "$LEAD2"
# Four registered Squad Leads make the owner's machine six accounts, so the caps hold eight
# (six accounts, one of headroom, rounded up to a step of eight) and the ninth is refused.
for i in 1 2 3 4; do
  printf -- '- lead-%s - Lead %s (home: %s/leads/lead-%s; scope: s; projects: none; added 2026-11-01)\n' "$i" "$i" "$D" "$i" >> "$H1/data/squad_leads.md"
done

out1=$(bus "$H1" install-service 2>&1)
assert_contains "$out1" "bus: installed and started" "the first home must install and start the service: $out1"
UNIT="$XDG_CONFIG_HOME/systemd/user/$JG_BUS_UNIT"
snap() { sha256sum "$UNIT" "$H1/state/bus/bus.conf" | awk '{print $1}' | tr '\n' ' '; }
before=$(snap); pid_before=$(cat "$D/service.pid")
# Home two appears after the owner installed, as a home added to a running machine does.
make_home "$H2"
# A generated password may begin with a dash (base64url does that one time in 64); a client
# that passes it as a separate argument reads it as a flag. Home two's starts with one.
IFS=$'\t' read -r name2 cred2 < <(bus "$H2" account)
mkdir -p "$(dirname "$cred2")"; printf -- '-dash-first-password-for-%s\n' "$name2" > "$cred2"; chmod 600 "$cred2"
grep -q "JG_HOME=$H1" "$UNIT" || fail "the unit does not name its owner"

# The second home's update path (install-service) and bootstrap path (unit nats, what
# bin/jg-stack.sh up writes the unit from) join; neither touches the unit or the config.
out2=$(bus "$H2" install-service 2>&1)
assert_contains "$out2" "owned by $H1" "the second home must be told who owns the bus: $out2"
case "$out2" in *"cannot"*) fail "the second home could not join: $out2" ;; esac
printf '%s' "$(bus "$H2" unit nats 2>"$D/unit2.err")" > "$D/unit2.txt"
cmp -s "$D/unit2.txt" <(printf '%s' "$(cat "$UNIT")") || fail "a non-owner's unit text differs from the installed unit"
assert_contains "$(cat "$D/unit2.err")" "owned by $H1" "the bootstrap path must name the owner"
[ "$(snap)" = "$before" ] || fail "a non-owner changed the owner's unit file or bus.conf"
[ "$(cat "$D/service.pid")" = "$pid_before" ] || fail "a non-owner restarted the shared bus"
grep -q reload "$D/systemctl.log" || fail "the server was never asked to reload the new account"
# `owner` is what bin/jg-stack.sh asks before it installs dapr.
assert_equals "self" "$(bus "$H1" owner)" "the home that owns the unit is told it owns it"
other_owner=$(bus "$H2" owner); rc=$?
assert_equals "$H1" "$other_owner" "a joined home is told who owns the unit"
assert_equals "3" "$rc" "a joined home's owner answer exits 3"

for h in "$H1" "$H2"; do
  one=$(bus "$h" ensure 2>&1)
  assert_contains "$one" "bus: up nats://127.0.0.1:$PORT stream CAPTAIN" "$h must pass ensure: $one"
  bus "$h" stream || fail "the stream is not on the server for $h"
done
a1=$(bus "$H1" account | cut -f1); a2=$(bus "$H2" account | cut -f1)
case "$a1" in home-????????????) ;; *) fail "home one is not named by its unique id: $a1" ;; esac
[ "$a1" != "$a2" ] || fail "two homes share the account $a1"
for n in "$a1" "$a2"; do grep -q "user: $n," "$H1/state/bus/accounts.conf" || fail "the shared accounts have no account $n"; done
! grep -Eq 'authentication error|Authorization Violation|insufficient' "$D/server.log" \
  || { cat "$D/server.log"; fail "the server logged an authentication or resource refusal"; }

# --- 1a. a home the machine's registry names presents that name ---------------------
# The production refusal: Main's accounts file named this home by the id its registry holds,
# while the home's own client - it keeps no registry of its own - hashed its path and
# presented home-<hash>, so every stream create and publish was refused with Authorization
# Violation and Main fell back to the no-accounts config. A home's name must come from the
# one registry the accounts file is written from, so server and client cannot drift.
assert_equals "lead-2" "$(bus "$LEAD2" account | cut -f1)" \
  "a home the machine's registry names must present that name, not a hash of its path"
grep -q 'user: lead-2,' "$H1/state/bus/accounts.conf" || fail "the shared accounts have no account lead-2"
joined=$(bus "$LEAD2" install-service 2>&1)
case "$joined" in *"cannot"*) fail "the home the registry names could not join: $joined" ;; esac
wake() { # <home> <wake client arguments...>, on this lab's server
  local h=$1
  shift
  JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" JG_DATA_OVERRIDE="$h/data" \
    JG_WAKE_BUS_URL="nats://127.0.0.1:$PORT" timeout 120 "$ROOT/bin/jg-wake-bus.sh" "$@"
}
for h in "$H1" "$LEAD2"; do
  key="proof-$(basename "$h")"
  one=$(bus "$h" ensure 2>&1)
  assert_contains "$one" "bus: up nats://127.0.0.1:$PORT stream CAPTAIN" "$h must create its own stream: $one"
  wake "$h" raise check "$key" "check: one message from $(basename "$h")" now || fail "the raise from $h failed"
  [ ! -s "$h/state/.wake-bus.outbox.jsonl" ] \
    || fail "the bus refused the raise from $h: $(cat "$h/state/.wake-bus.outbox.jsonl")"
  wake "$h" ids check "$key" | grep -q . || fail "$h could not read its own raise back"
  IFS=$'\t' read -r ep_url ep_stream _ ep_user ep_cred < <(wake "$h" endpoint)
  [ -n "$ep_user" ] && [ -n "$ep_cred" ] || fail "$h's client published with no account at all"
  assert_equals "$(bus "$h" account | cut -f1)" "$ep_user" "$h's client logged in as a name the server does not hold"
  # The message really crossed to the server on that account: read the last event back with
  # the very credentials the client published with.
  last=$(NATS_USER=$ep_user NATS_PASSWORD=$(cat "$ep_cred") "$NATS_BIN" -s "$ep_url" \
    stream info "$ep_stream" --json | jq -r '.state.last_seq // 0')
  [ "${last:-0}" -ge 1 ] || fail "$h's message never reached the server"
  body=$(NATS_USER=$ep_user NATS_PASSWORD=$(cat "$ep_cred") "$NATS_BIN" -s "$ep_url" \
    stream get "$ep_stream" "$last" --json | jq -r '.data' | base64 -d)
  printf '%s' "$body" | grep -q "$key" || fail "$h could not read its own message off the server: $body"
done
! grep -Eq 'Authorization Violation|authentication error' "$D/server.log" \
  || { cat "$D/server.log"; fail "the server refused a home's own account"; }
# The production refusal itself, kept as the control it was reproduced with: the pre-fix
# client presented home-<hash> while the accounts file held the registry id, and the server
# refused it. A passing run above is only meaningful while this still fails.
if NATS_USER="home-0123456789ab" NATS_PASSWORD=$(cat "$LEAD2/state/bus/lead-2.pass") "$NATS_BIN" \
  -s "nats://127.0.0.1:$PORT" --timeout 10s stream list >/dev/null 2>"$D/mismatch.err"; then
  fail "the server accepted a client whose name its accounts file does not hold"
fi
grep -q 'Authorization Violation' "$D/mismatch.err" \
  || { cat "$D/mismatch.err"; fail "a mismatched name was not refused the way production refused it"; }
pass "a home the machine's registry names logs in as that account from every client, creates its stream and round-trips one message; the server refuses nothing, and still refuses a name its accounts file does not hold"

# --- 1d. a stream call logs in without its password on the command line ------------------
# The old live consumer ran `nats --password=...` for every 30-second wait, so any user on
# the machine read the password in `ps`. Home two's password begins with a dash, the case
# a flag parser misreads. A stream check from home two goes through the logging client, and
# no call any bus command made in this lab carried a password flag or value.
: > "$D/nats-argv.log"
bus "$H2" stream >/dev/null 2>&1 || fail "home two could not check its own stream"
grep -q -- 'stream info' "$D/nats-argv.log" || fail "the stream check never went through the lab client, so the check below would prove nothing"
! grep -q -- '--password' "$D/nats-argv.log" || fail "a nats call passed a password flag on its command line"
for p in "$D"/homes/*/state/bus/*.pass "$LEAD2"/state/bus/*.pass; do
  [ -s "$p" ] || continue
  ! grep -qF -- "$(tr -d '\n' < "$p")" "$D/nats-argv.log" || fail "a nats call carried the password in $p on its command line"
done
assert_equals "600" "$(stat -c %a "$H2/state/bus/nats-context.json" 2>/dev/null || stat -f %Lp "$H2/state/bus/nats-context.json")" \
  "the login file must be readable by its owner only"
pass "a stream call logs in with a 0600 context file, and no nats call any bus command made carried a password flag or value"

# The owner's own unchanged install touches nothing; a third home joins by reload too.
bus "$H1" install-service >/dev/null 2>&1
[ "$(cat "$D/service.pid")" = "$pid_before" ] || fail "an unchanged owner install restarted the shared bus"
make_home "$H3"
out3=$(bus "$H3" install-service 2>&1)
case "$out3" in *"cannot"*) fail "the third home could not join: $out3" ;; esac
[ "$(cat "$D/service.pid")" = "$pid_before" ] || fail "a joining home restarted the shared bus"
[ "$(snap)" = "$before" ] || fail "the third home changed the owner's unit file or bus.conf"
three=$(bus "$H3" ensure 2>&1)
assert_contains "$three" "bus: up nats://127.0.0.1:$PORT stream CAPTAIN" "the third home must pass ensure: $three"
bus "$H1" stream || fail "the owner lost its stream or its login when a home joined"

# The caps hold eight accounts (six, one of headroom, rounded up to a step): the eighth home
# still joins by reload; the ninth would push the machine past them and is refused, naming
# the owner, with the accounts file left as it was.
make_home "$H4"
bus "$H4" install-service 2>&1 | grep -q "added to the shared accounts" || fail "the eighth account did not join"
[ "$(cat "$D/service.pid")" = "$pid_before" ] || fail "a joining home restarted the shared bus"
make_home "$H5"
accounts_before=$(sha256sum "$H1/state/bus/accounts.conf")
out4=$(bus "$H5" install-service 2>&1)
assert_contains "$out4" "refusing the server config" "a home past the caps must be refused: $out4"
assert_contains "$out4" "owned by $H1" "the refusal must name the owner: $out4"
[ "$(sha256sum "$H1/state/bus/accounts.conf")" = "$accounts_before" ] || fail "a refused join changed the shared accounts"
[ "$(snap)" = "$before" ] || fail "a refused join changed the owner's unit file or bus.conf"
pass "one owner: other homes' bootstrap and update only add their account (reload), the owner's unit and bus.conf stay byte-identical, everyone authenticates, an over-cap join is refused"

# --- 1b. a lab home never reaches a machine's real registry -------------------------
# The owner's homes file IS this machine's registry. 452 temp and worktree fixture homes
# had reached a real one, because every suite's join landed in the owner's own list. A
# lab home with no registry of its own is refused and leaves that file byte-identical;
# the same home names its own list with JG_BUS_HOMES and is recorded there instead.
H6="$D/homes/six"; make_home "$H6"
OWNER_REGISTRY="$H1/state/bus/homes"
# What a real machine's list holds: one line a real home left there. Nothing a fixture
# does may change a byte of it. Its path is inside this lab so a refused join can never
# write outside the temp tree.
mkdir -p "$D/homes/registered-real/state"
printf '%s\t%s\n' "$D/homes/registered-real" "$D/homes/registered-real/state" > "$OWNER_REGISTRY"
registry_before=$(sha256sum "$OWNER_REGISTRY")
out5=$(env -u JG_BUS_HOMES JG_HOME="$H6" JG_STATE_OVERRIDE="$H6/state" JG_DATA_OVERRIDE="$H6/data" \
  timeout 120 "$BUS" install-service 2>&1)
[ "$(sha256sum "$OWNER_REGISTRY")" = "$registry_before" ] || fail "a lab home was added to the machine's real registry"
assert_contains "$out5" "never added to the machine registry" "a lab home with no registry of its own must be refused: $out5"
assert_contains "$out5" "JG_BUS_HOMES" "the refusal must name the way a lab home registers: $out5"
[ "$(cat "$D/service.pid")" = "$pid_before" ] || fail "a refused lab home restarted the shared bus"
LAB_REGISTRY="$D/lab-registry"
JG_BUS_HOMES="$LAB_REGISTRY" bus "$H6" install-service >/dev/null 2>&1
[ "$(awk -F '\t' -v h="$H6" '$1 == h { found = 1 } END { print found + 0 }' "$LAB_REGISTRY" 2>/dev/null)" = 1 ] \
  || fail "a lab home was not recorded in the registry JG_BUS_HOMES named"
[ "$(sha256sum "$OWNER_REGISTRY")" = "$registry_before" ] || fail "a lab home with its own registry still changed the machine's real one"
pass "a lab home is refused by the machine's real registry, which stays byte-identical; the registry JG_BUS_HOMES names holds it instead"

# --- 1e. an account taken away restarts the server ----------------------------------
# A reload drops a removed account but keeps its JetStream reservation until the server
# restarts. On a full machine the next new account was refused (10028), and that refusal
# ended the reload before JetStream was back on the accounts it had not reached, so homes
# that never left lost it at random. Each swap below takes one account away from a full
# machine and adds one, and every home that stayed must keep its stream and its raises.
rm -rf -- "$H5/state" "$H6/state" "$D/homes/registered-real/state"
stayers() { printf '%s\t%s\n' "$H2" "$H2/state" "$H3" "$H3/state" > "$1"; }
gone=$H4
for i in 1 2 3 4; do
  rm -rf -- "$gone/state"
  gone="$D/homes/swap-$i"; make_home "$gone"
  swap_pid=$(cat "$D/service.pid"); stayers "$D/swap-registry.$i"
  out6=$(JG_BUS_HOMES="$D/swap-registry.$i" bus "$gone" install-service 2>&1)
  assert_contains "$out6" "added to the shared accounts" "swap $i did not add its account: $out6"
  ! grep -q 'insufficient' "$D/server.log" \
    || { cat "$D/server.log"; fail "swap $i left the new account refused by a removed account's reservation"; }
  for h in "$gone" "$H1" "$H2" "$H3" "$LEAD2"; do
    one=$(JG_BUS_HOMES="$D/swap-registry.$i" bus "$h" ensure 2>&1)
    assert_contains "$one" "bus: up nats://127.0.0.1:$PORT stream CAPTAIN" "$h lost JetStream in swap $i: $one"
  done
  [ "$(cat "$D/service.pid")" != "$swap_pid" ] || fail "swap $i took an account away without a restart"
done
wake "$H1" raise check swap-proof "check: the owner after four swaps" now || fail "the raise after the swaps failed"
[ ! -s "$H1/state/.wake-bus.outbox.jsonl" ] || fail "the bus refused the raise: $(cat "$H1/state/.wake-bus.outbox.jsonl")"
wake "$H1" ids check swap-proof | grep -q . || fail "the owner could not read its raise back"
# The owner's own install takes the same path: its accounts shrink and the caps stay.
rm -rf -- "$gone/state"
swap_pid=$(cat "$D/service.pid"); conf_before=$(sha256sum "$H1/state/bus/bus.conf")
stayers "$D/swap-registry.owner"
JG_BUS_HOMES="$D/swap-registry.owner" bus "$H1" install-service >/dev/null 2>&1
[ "$(sha256sum "$H1/state/bus/bus.conf")" = "$conf_before" ] || fail "the owner's install moved the caps, so it proves nothing about the accounts"
[ "$(cat "$D/service.pid")" != "$swap_pid" ] || fail "the owner's install took an account away without a restart"
one=$(JG_BUS_HOMES="$D/swap-registry.owner" bus "$H2" ensure 2>&1)
assert_contains "$one" "bus: up nats://127.0.0.1:$PORT stream CAPTAIN" "a home lost JetStream in the owner's install: $one"
pass "an account taken away restarts the server, from a join and from the owner's install: no account is refused and every home that stayed keeps JetStream"

# --- 1e2. a reload that logs a JetStream failure is finished by a restart -----------
# A reload that cannot fit an account logs the error and still exits clean, leaving
# accounts without JetStream, so no acknowledgement reaches their wake rows.
touch "$D/js-fail"
reload_home="$D/homes/reload-fail"; make_home "$reload_home"
swap_pid=$(cat "$D/service.pid"); stayers "$D/reload-registry"
JG_BUS_HOMES="$D/reload-registry" bus "$reload_home" install-service >/dev/null 2>&1
rm -f -- "$D/js-fail"
[ "$(cat "$D/service.pid")" != "$swap_pid" ] || fail "a reload that logged a JetStream failure was not followed by a restart"
pass "a reload that logs a JetStream failure is finished by a restart"

# --- 1f. a fixture never reaches a real owner's accounts file -----------------------
# Every suite exports JG_BUS_HOMES, and a suite with no lab unit of its own reaches the
# machine's real unit. Its list used to replace the real one, so each run rewrote the real
# accounts file with fixture homes and reloaded the real server. The owner here stands
# outside every temp root, as a real one does; only the checkout's ignored state directory
# is sure to be, so a checkout under a temp root has nowhere to put it.
case "$ROOT/" in
  /tmp/* | /var/tmp/* | /dev/shm/* | "${TMPDIR:-/tmp}"/*)
    echo "note: the checkout is under a temp root, so section 1f has no real-looking owner to use"
    ;;
  *)
    mkdir -p "$ROOT/state"
    REAL=$(mktemp -d "$ROOT/state/jg-bus-owner.XXXXXX") || fail "cannot create the real-looking owner"
    OWNER="$REAL/owner"; make_home "$OWNER"; mkdir -p "$OWNER/state/bus"
    MEMBER="$D/real-member"; make_home "$MEMBER"
    cp "$H1/state/bus/bus.conf" "$OWNER/state/bus/bus.conf"
    printf 'system_account: SYS\n' > "$OWNER/state/bus/accounts.conf"
    printf '%s\t%s\n' "$MEMBER" "$MEMBER/state" > "$OWNER/state/bus/homes"
    REAL_UNIT="jg-lab-$$-real.service"
    printf '[Service]\nWorkingDirectory=%s\nEnvironment="JG_HOME=%s"\n' "$OWNER/state/bus" "$OWNER" \
      > "$XDG_CONFIG_HOME/systemd/user/$REAL_UNIT"
    real_snap() { sha256sum "$OWNER/state/bus/accounts.conf" "$OWNER/state/bus/homes" | awk '{print $1}' | tr '\n' ' '; }
    real_before=$(real_snap); reloads_before=$(grep -c reload "$D/systemctl.log")
    FIXTURE="$D/fixture/home"; make_home "$FIXTURE"
    out7=$(JG_BUS_UNIT="$REAL_UNIT" JG_BUS_HOMES="$D/fixture-registry" bus "$FIXTURE" unit nats 2>&1)
    [ "$(real_snap)" = "$real_before" ] || fail "a fixture rewrote a real owner's accounts or list: $out7"
    assert_equals "$reloads_before" "$(grep -c reload "$D/systemctl.log")" "a fixture signalled a real owner's server"
    assert_contains "$out7" "never added to the machine registry" "a fixture must be refused by a real owner: $out7"
    [ ! -e "$D/fixture-registry" ] || fail "a refused fixture was still recorded"
    # The real owner itself keeps its own list, whatever the shell it runs in exports.
    JG_BUS_UNIT="$REAL_UNIT" JG_BUS_HOMES="$D/fixture-registry" bus "$OWNER" unit nats >/dev/null 2>&1
    member=$(bus "$MEMBER" account | cut -f1)
    grep -q "user: $member," "$OWNER/state/bus/accounts.conf" || fail "a real owner read another list than its own"
    pass "a fixture is refused by a real owner, whose accounts and list stay byte-identical with no signal, and that owner keeps its own list"
    ;;
esac

# --- 1c. status reads the service manager itself ------------------------------------
# The probe used to call a service down unless this home had written its own pid file, so
# a machine whose four units were all active read three of them down: a reader chased a
# fault that was not there, and a real outage looked the same. It now reads each unit's
# own state from the manager. Active units read up, one stopped unit reads down on its own
# line with the others still up, and a manager that cannot be asked reads unknown.
UNITS="$XDG_CONFIG_HOME/systemd/user"; mkdir -p "$D/units"
: > "$UNITS/$JG_STACK_UNIT_PREFIX-dapr.service"
: > "$D/units/$JG_STACK_UNIT_PREFIX-dapr.service.active"
unit_of() { case $1 in nats) echo "$JG_BUS_UNIT" ;; *) echo "$JG_STACK_UNIT_PREFIX-$1.service" ;; esac; }
status_out=$(bus "$H1" status 2>&1)
for part in nats dapr; do
  assert_contains "$status_out" "$part: up (unit $(unit_of "$part"))" "an active $part unit must read up: $status_out"
done
rm -f -- "$D/units/$(unit_of dapr).active"
status_out=$(bus "$H1" status 2>&1)
assert_contains "$status_out" "dapr: down (unit $(unit_of dapr) inactive)" "a stopped unit must read down: $status_out"
assert_contains "$status_out" "nats: up (unit $(unit_of nats))" "one stopped unit must not read the other down: $status_out"
pass "status reads each service's unit state: active units read up, and a stopped one reads down alone"

# The manager is the only owner of that truth, so a probe that cannot ask it says unknown
# instead of guessing down - with the server stopped too, so nothing answers and a wrong
# down would be very plausible.
stop_lab
BLIND="$D/blind"; mkdir -p "$BLIND"
printf '#!/usr/bin/env bash\necho "Failed to connect to bus: no medium found" >&2\nexit 1\n' > "$BLIND/systemctl"
chmod +x "$BLIND/systemctl"
status_out=$(PATH="$BLIND:$PATH" bus "$H1" status 2>&1)
for part in nats dapr; do
  assert_contains "$status_out" "$part: unknown (cannot read the service manager for $(unit_of "$part"))" \
    "a probe that cannot ask the manager must say unknown for $part: $status_out"
done
case "$status_out" in *": down"*) fail "a probe that cannot read the manager guessed down: $status_out" ;; esac
pass "a probe that cannot read the service manager reports unknown, never down"
stop_lab
rm -f -- "$UNIT"   # the lab's unit: the 21-account home below installs a machine of its own

# --- 2. the limits arithmetic with 21 accounts -------------------------------------
# This lab installs its own unit, so it registers nothing; it still names its own list, so
# the homes the lab above registered cannot count as members of this one.
export JG_BUS_HOMES="$D/solo-registry"
H21="$D/solo/many"; make_home "$H21"
: > "$H21/data/squad_leads.md"
for i in $(seq 20); do
  printf -- '- lead-%02d - Lead %s (home: %s/leads/lead-%02d; scope: s; projects: none; added 2026-11-01)\n' "$i" "$i" "$D" "$i" >> "$H21/data/squad_leads.md"
done
bus "$H21" unit nats > "$D/unit.txt" 2> "$D/unit.err" || { cat "$D/unit.err"; fail "the 21-account config was refused: $(cat "$D/unit.err")"; }
CONF="$H21/state/bus/bus.conf"
ACC="$H21/state/bus/accounts.conf"
accounts=$(grep -c 'jetstream: { max_mem' "$ACC")
[ "$accounts" = 21 ] || fail "expected 21 accounts reserving JetStream, found $accounts"
# 21 accounts at 64Mb memory / 512Mb storage, plus one account of headroom (22), rounded up to
# a step of eight reservations (24).
assert_equals "max_mem_store: 1536Mb" "$(grep -o 'max_mem_store: [0-9]*Mb' "$CONF")" "memory cap is 24 x 64Mb"
assert_equals "max_file_store: 12288Mb" "$(grep -o 'max_file_store: [0-9]*Mb' "$CONF")" "storage cap is 24 x 512Mb"
grep -q '^include accounts.conf$' "$CONF" || fail "the server config does not include the accounts file"
bus "$H21" check-limits "$CONF" >/dev/null || fail "check-limits refused the generated config"

# The server really starts on it: JetStream up, no resource refusal.
# The pid is the server's own: `cd && cmd &` would background the whole list, and the pid file
# would name the subshell, so the stop below missed the server and it outlived the run.
( cd "$D" && exec setsid "$NATS_SERVER" -c "$CONF" > "$D/many.log" 2>&1 < /dev/null ) &
echo $! > "$D/solo.pid"
for _ in $(seq 100); do (: < "/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break; sleep 0.1; done
bus "$H21" ensure 2>&1 | grep -q "bus: up" || { cat "$D/many.log"; fail "the server did not come up on the generated 21-account config"; }
! grep -q 'insufficient' "$D/many.log" || fail "the server refused the generated caps"
grep -q 'Starting JetStream' "$D/many.log" || fail "JetStream did not start"
kill "$(cat "$D/solo.pid")" 2>/dev/null || true; rm -f "$D/solo.pid"
pass "21 accounts: caps cover 21 reservations plus headroom and a real server starts on them"

# --- 3. the incident config is refused, loudly --------------------------------------
cp "$ACC" "$D/accounts.conf"
sed -e 's/max_mem_store: [0-9]*Mb/max_mem_store: 384Mb/' "$CONF" > "$D/broken.conf"
if bus "$H21" check-limits "$D/broken.conf" > "$D/refuse.out" 2> "$D/refuse.err"; then fail "a 384Mb cap beside 21 accounts was accepted"; fi
assert_contains "$(cat "$D/refuse.err")" "refusing the server config: 21 accounts reserve 1344Mb memory" "the refusal must name the shortfall"
PORT2=$(free_port)
sed -i -e "s/^port: .*/port: $PORT2/" "$D/broken.conf"
( cd "$D" && timeout 20 "$NATS_SERVER" -c "$D/broken.conf" > "$D/broken.log" 2>&1 < /dev/null ) || true
grep -q 'insufficient' "$D/broken.log" || fail "the incident config no longer reproduces the server refusal"
pass "a config the server cannot start with is refused with the shortfall named (it reproduces 10028 on a real server)"

# --- 4. the reaper stops a stale lab server and nothing else -------------------------
# A server whose jg-bus-machine config directory is gone is stopped; a live one, and a server
# whose config path holds no jg-bus-machine directory (another home's bus) are left running,
# even with the config directory removed. The reaper is told to look only below the temp base.
REAP="$D/reap"
OTHER=$(jg_test_tmproot jg-reapother)
# Each server is waited on until it logs that it is ready, and its pid is the one it logs: before that
# it may still be a shell, or not running at all, so removing its directory earlier leaves nothing to reap.
reap_start() { # <config dir> <pid file>
  local i pid=''
  mkdir -p "$1"; printf 'host: "127.0.0.1"\nport: -1\n' > "$1/bus.conf"
  ( cd "$1" && exec setsid "$NATS_SERVER" -c "$1/bus.conf" > "$1/log" 2>&1 < /dev/null ) &
  # shellcheck disable=SC2034 # a bounded wait for the ready line, never read.
  for i in $(seq 1 1200); do
    pid=$(sed -n 's/^\[\([0-9][0-9]*\)\] .*Server is ready.*/\1/p' "$1/log" 2>/dev/null | head -n 1)
    [ -z "$pid" ] || break
    sleep 0.05
  done
  [ -n "$pid" ] || fail "the lab server in $1 never logged that it is ready: $(cat "$1/log" 2>/dev/null)"
  echo "$pid" > "$2"
}
reap_start "$REAP/jg-bus-machine.STALE1/state/bus" "$D/reap-stale.pid"
reap_start "$REAP/jg-bus-machine.LIVE01/state/bus" "$D/reap-live.pid"
reap_start "$OTHER/state/bus" "$D/reap-other.pid"
rm -rf -- "$REAP/jg-bus-machine.STALE1" "$OTHER/state"
reap_out=$("$ROOT/bin/jg-bus-reap.sh" --under "$(dirname "$D")")
assert_contains "$reap_out" "reaped $(cat "$D/reap-stale.pid") " "the reaper must stop the server whose directory is gone: $reap_out"
# shellcheck disable=SC2034 # a bounded wait for the reaped server to be gone, never read.
for i in $(seq 1 200); do kill -0 "$(cat "$D/reap-stale.pid")" 2>/dev/null || break; sleep 0.05; done
! kill -0 "$(cat "$D/reap-stale.pid")" 2>/dev/null || fail "the stale lab server is still running"
kill -0 "$(cat "$D/reap-live.pid")" 2>/dev/null || fail "the reaper stopped a live lab server"
kill -0 "$(cat "$D/reap-other.pid")" 2>/dev/null || fail "the reaper stopped a server that is not a jg-bus-machine lab"
assert_equals "" "$("$ROOT/bin/jg-bus-reap.sh" --under "$(dirname "$D")")" "a second pass has nothing left to stop"
kill "$(cat "$D/reap-live.pid")" "$(cat "$D/reap-other.pid")" 2>/dev/null || true
pass "the reaper stops a lab server whose directory is gone and leaves a live one and another home's server alone"

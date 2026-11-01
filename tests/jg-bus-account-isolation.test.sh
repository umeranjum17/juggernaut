#!/usr/bin/env bash
# One server, one account per home, named by the home's unique id and never by its
# folder: three homes whose folders are all called "firstmate" (Main and two
# registered Squad Leads) each get their own account, each publishes and consumes as
# itself, and none can read another's subject. The accounts come from the Go bus
# command, which is the only owner of that file.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRV=${JG_NATS_SERVER:-$(command -v nats-server 2>/dev/null || true)}
CLI=${JG_NATS_BIN:-$(command -v nats 2>/dev/null || true)}
[ -n "$SRV" ] || { echo "skip: nats-server not found"; exit 0; }
[ -n "$CLI" ] || { echo "skip: nats client not found"; exit 0; }
D=$(jg_test_tmproot jg-bus-isolation)
A="$D/a/firstmate"; B="$D/b/firstmate"; C="$D/c/firstmate"
mkdir -p "$A/state" "$A/data" "$B/state" "$C/state" "$D/store"
cat > "$A/data/squad_leads.md" <<EOF
- lead-b - Home B (home: $B; scope: b things; projects: none; added 2026-11-01)
- lead-c - Home C (host: h; root: /r; home: $C; scope: c things; projects: none; added 2026-11-01)
EOF
# The bus command is Go; without a toolchain there is nothing to prove here.
if [ -z "${JG_BUS_GO:-}" ]; then
  JG_BUS_GO=$(command -v go 2>/dev/null || true)
  [ -n "$JG_BUS_GO" ] || { echo "skip: no Go toolchain (set JG_BUS_GO)"; exit 0; }
fi
export JG_BUS_GO
bus() { local h=$1; shift; JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" JG_DATA_OVERRIDE="$A/data" timeout 240 bash "$ROOT/bin/jg-bus.sh" "$@"; }
# An install from before the change shared one "firstmate" account across these
# homes, so that password names no single home and is not inherited by any of them.
mkdir -p "$A/state/bus"; printf 'legacy-password\n' > "$A/state/bus/firstmate.pass"
bus "$A" accounts > "$D/accounts.conf" 2> "$D/accounts.err" || fail "the bus command did not produce the accounts file"
! grep -q 'legacy-password' "$D/accounts.conf" || fail "a shared basename credential was inherited"
# A home whose folder name is unique migrates its old account once, keeping the password.
S="$D/solo-home"; mkdir -p "$S/state/bus" "$D/nodata"; printf 'solo-password\n' > "$S/state/bus/solo-home.pass"
JG_HOME="$S" JG_STATE_OVERRIDE="$S/state" JG_DATA_OVERRIDE="$D/nodata" bash "$ROOT/bin/jg-bus.sh" accounts > "$D/solo.conf" 2> "$D/solo.err" || fail "solo accounts failed"
grep -q 'migrated' "$D/solo.err" && grep -q 'solo-password' "$D/solo.conf" && [ ! -e "$S/state/bus/solo-home.pass" ] || fail "the unique old account was not migrated once"
grep -q 'system_account' "$D/accounts.conf" || fail "no system account"
ia=$(bus "$A" account | cut -f1); ib=$(bus "$B" account | cut -f1); ic=$(bus "$C" account | cut -f1)
[ "$ib" = lead-b ] && [ "$ic" = lead-c ] || fail "Squad Leads are not named by their registry id: $ib $ic"
case "$ia" in home-????????????) ;; *) fail "Main is not named by a path hash: $ia" ;; esac
[ "$(grep -c '^  [A-Za-z0-9_-]* {' "$D/accounts.conf")" = 4 ] || fail "expected SYS plus three home accounts"
for n in "$ia" "$ib" "$ic"; do grep -q "user: $n," "$D/accounts.conf" || fail "no account for $n"; done
[ "$(grep -o 'password: "[^"]*"' "$D/accounts.conf" | sort -u | wc -l)" = 4 ] || fail "two accounts share a password"
# The permission rule: an account block must never carry a bare wildcard or a
# subject that is not the home's own prefix, which is what widening would look like.
if grep -Eq '^\s+(allow|exports|imports)' "$D/accounts.conf"; then fail "the accounts file exports or imports subjects"; fi
# A collision is refused with one line naming both homes.
printf -- '- lead-c - Dup (home: %s/x; scope: x; projects: none; added 2026-11-01)\n' "$D" >> "$A/data/squad_leads.md"
if bus "$A" accounts > /dev/null 2> "$D/collide.err"; then fail "a colliding account name was accepted"; fi
[ "$(wc -l < "$D/collide.err")" = 1 ] || fail "the refusal is not one line: $(cat "$D/collide.err")"
grep -q "$C" "$D/collide.err" || fail "the refusal does not name home C"
grep -q "$D/x" "$D/collide.err" || fail "the refusal does not name the second home"
head -n 2 "$A/data/squad_leads.md" > "$A/data/squad_leads.tmp" && mv "$A/data/squad_leads.tmp" "$A/data/squad_leads.md"
"$SRV" -js -a 127.0.0.1 -p -1 -sd "$D/store" -c "$D/accounts.conf" > "$D/nats.log" 2>&1 &
PID=$!
# shellcheck disable=SC2329
cleanup() { kill "$PID" 2>/dev/null || true; }
trap cleanup EXIT
port=
for _ in $(seq 200); do port=$(sed -n 's/.*Listening for client connections on 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$D/nats.log" | head -1); [ -n "$port" ] && break; sleep 0.05; done
[ -n "$port" ] || { cat "$D/nats.log"; fail "the server did not listen"; }
url="nats://127.0.0.1:$port"
pw() { cat "$A/state/bus/$1.pass"; }
# Each home publishes on its own prefix and consumes it as itself.
for n in "$ia" "$ib" "$ic"; do
  timeout 15 "$CLI" -s "$url" --user "$n" --password "$(pw "$n")" sub "jg.$n.wake.>" --count 1 --timeout 12s > "$D/got.$n" 2>&1 &
  sub=$!
  sleep 1
  timeout 20 "$CLI" -s "$url" --user "$n" --password "$(pw "$n")" pub "jg.$n.wake.raise" "hi-$n" >/dev/null 2>&1 \
    || fail "$n could not publish on its own prefix"
  wait "$sub" 2>/dev/null || true
  grep -q "hi-$n" "$D/got.$n" || fail "$n did not consume its own message"
done
# None can read another's subject, in either direction across all three.
for x in "$ia" "$ib" "$ic"; do for y in "$ia" "$ib" "$ic"; do
  [ "$x" != "$y" ] || continue
  if timeout 10 "$CLI" -s "$url" --user "$x" --password "$(pw "$x")" sub "jg.$y.wake.>" --count 1 --timeout 3s >/dev/null 2>&1; then
    fail "$x read $y's subjects"
  fi
done; done
pass "three homes with one folder name: own account each, publish and consume as itself, no cross-reads, collision refused, old account migrated only when unique"

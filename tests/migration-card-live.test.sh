#!/usr/bin/env bash
# The migration card's live parts are measured, never remembered: a real bus on a
# free port is found with its pid and one real message, a fresh server says plainly
# that it carries no wake stream yet and then carries one, the parts this machine
# does not have say so instead of staying blank, and the watcher's cadence pass
# keeps the card current without printing a line, so no wake and no model turn is
# spent on it. Gate-skips when the bus server or client is missing.
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
NATS_SERVER=${JG_NATS_SERVER:-$(command -v nats-server 2>/dev/null || true)}
NATS_BIN=${JG_NATS_BIN:-$(command -v nats 2>/dev/null || true)}
[ -n "$NATS_SERVER" ] || { echo "skip: nats-server not found (set JG_NATS_SERVER)"; exit 0; }
[ -n "$NATS_BIN" ] || { echo "skip: nats client not found (set JG_NATS_BIN)"; exit 0; }

T=$(jg_test_tmproot migration-card-live)
HOME_DIR=$T/home
DIR=$HOME_DIR/data/migration-card
BOARD=$T/board/board.json
ROWS=$DIR/live.tsv
SERVER_PID=
LOG=$T/bus.log
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() { [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true; }
trap cleanup EXIT

mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$T/bin" "$T/board" "$T/store"
"$NATS_SERVER" -js -a 127.0.0.1 -p -1 -sd "$T/store" >"$LOG" 2>&1 &
SERVER_PID=$!
PORT=
for _ in $(seq 1 200); do
  PORT=$(sed -n 's/.*Listening for client connections on 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$LOG" 2>/dev/null | head -n 1)
  [ -z "$PORT" ] || break
  sleep 0.05
done
[ -n "$PORT" ] || fail "the test bus did not start"
URL=nats://127.0.0.1:$PORT

export JG_HOME=$HOME_DIR PATH=$T/bin:$PATH FAKE_LOG=$T/calls.log
printf 'set nats-url %s\n' "$URL" >"$HOME_DIR/config/captain-channel"
printf '{"schema":2,"items":[]}\n' >"$BOARD"
printf 'branch=release/c-2\ntarget=100000\nboard=%s\ncard=migration-card\nbaseline-deleted=0\nbaseline-added=0\nfiler=test\nproject=Test\n' \
  "$BOARD" >"$HOME_DIR/config/migration-card"
cat >"$T/bin/sign-off-axi" <<'F'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
exit 0
F
chmod +x "$T/bin/sign-off-axi"

row() { awk -F'\t' -v p="$1" '$1 == p { printf "%s|%s", $2, $3 }' "$ROWS"; }
card_page() { find "$T/board/reports" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1; }
card_count() { find "$T/board/reports" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l; }

"$ROOT/bin/jg-migration-live.sh" --quiet >/dev/null || fail "the probe did not run"
assert_equals 15 "$(wc -l <"$ROWS")" "every part the captain named has a row"
for part in 'NATS server' 'per-home accounts' 'wake queue' 'task inbox' leases 'captain channel/ntfy' \
  Dapr 'Go daemons' 'merge gate' 'escalation ladder' 'five-minute merge' deletions 'rules JSON' \
  'juggernaut-axi' 'add-on removal'; do
  case $(awk -F'\t' -v p="$part" '$1 == p { print $2 }' "$ROWS") in
    live | pending | absent) ;;
    *) fail "part '$part' has no measured state, so the card would leave it blank" ;;
  esac
done

assert_contains "$(row 'NATS server')" "live|" "a server that answers is live"
assert_contains "$(row 'NATS server')" "pid " "the live server is named by pid"
assert_contains "$(row 'NATS server')" "a real message went out and came back" "the bus carried a real message"
assert_contains "$(row 'per-home accounts')" "pending|the server runs without accounts" "a server started without accounts is pending, and says why"
assert_contains "$(row 'wake queue')" "pending|the server carries no JG_WAKE stream" "a path with no stream on the server is pending"

"$NATS_BIN" -s "$URL" stream add JG_WAKE --subjects 'jg.wake.>' --storage file --defaults >/dev/null 2>&1 ||
  fail "the test could not create the wake stream"
"$NATS_BIN" -s "$URL" stream add JG_INBOX --subjects 'jg.inbox.>' --storage file --defaults >/dev/null 2>&1 ||
  fail "the test could not create the inbox stream"
"$ROOT/bin/jg-migration-live.sh" --quiet >/dev/null || fail "the second probe did not run"
assert_contains "$(row 'wake queue')" "live|the bus is the store, 0 records on JG_WAKE" "a wake stream on the server makes the queue live"

key=$("$ROOT/bin/jg-migration-card.sh" live)
page=$(card_page)
[ -n "$page" ] || fail "the card was not posted"
assert_contains "$key" "migration-card-" "live posts a card and names its key"
assert_contains "$(cat "$page/index.html")" "<h2>What runs on this machine</h2>" "the card carries the live section"
assert_contains "$(cat "$page/index.html")" "<td>NATS server</td><td>runs here</td>" "the card says a running part runs here"
assert_contains "$(cat "$page/index.html")" "<td>Dapr</td><td>not installed</td>" "a part this machine lacks says it is not installed"
assert_contains "$(cat "$page/index.html")" "Each line is a probe of this machine" "the card says where the lines come from"
assert_contains "$(cat "$page/index.html")" "<meta name=viewport" "the page keeps its viewport tag"

# The cadence: the watcher runs this shim every cycle it is due, and it prints
# nothing, so a refresh costs no wake and no model turn.
"$ROOT/bin/jg-migration-card.sh" arm >/dev/null || fail "the check did not arm"
[ -x "$HOME_DIR/state/migration-card.check.sh" ] || fail "arm wrote no check shim"
[ -f "$HOME_DIR/state/migration-card.check-trust" ] || fail "arm did not bind the check"
assert_contains "$(sed -n '2p' "$HOME_DIR/state/migration-card.check.sh")" "JG_CONFIG_OVERRIDE=$HOME_DIR/config " \
  "the shim names the config folder, not the card file"
cards=$(card_count)
out=$("$HOME_DIR/state/migration-card.check.sh" 2>&1)
assert_equals "" "$out" "a cadence pass with nothing changed prints nothing"
assert_equals "$cards" "$(card_count)" "a cadence pass with nothing changed posts no card"

printf '{"rules":[{"match":"a"},{"match":"b"}]}\n' >"$HOME_DIR/config/crew-dispatch.json"
out=$("$HOME_DIR/state/migration-card.check.sh" 2>&1)
assert_equals "" "$out" "a cadence pass that finds a change still prints nothing"
assert_equals "$((cards + 1))" "$(card_count)" "a changed part posts a fresh card"
assert_contains "$(cat "$(card_page)/index.html")" "config/crew-dispatch.json parses, 2 rule(s)" "the new card shows the new measurement"

"$ROOT/bin/jg-migration-card.sh" disarm >/dev/null || fail "disarm failed"
[ ! -e "$HOME_DIR/state/migration-card.check.sh" ] || fail "disarm left the check shim"
pass "the migration card measures every part on this machine and keeps itself current"

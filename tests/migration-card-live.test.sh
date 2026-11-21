#!/usr/bin/env bash
# The migration card's live parts are measured, never remembered: the wake queue, the task
# inboxes and the leases read this home's local files, the parts this machine does not have say
# so instead of staying blank, and the watcher's cadence pass keeps the card current without
# printing a line, so no wake and no model turn is spent on it.
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

T=$(jg_test_tmproot migration-card-live)
HOME_DIR=$T/home
DIR=$HOME_DIR/data/migration-card
BOARD=$T/board/board.json
ROWS=$DIR/live.tsv
MIGRATION_ORIGINAL_PATH=$PATH
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() {
  local pid=${BOT_PID:-}
  [ -z "$pid" ] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
  PATH=$MIGRATION_ORIGINAL_PATH jg_test_cleanup
}
trap cleanup EXIT

mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$T/bin" "$T/board"
MIGRATION_BASE=$(jg_test_base_path_sans "${JG_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" juggernaut-axi)
export JG_HOME=$HOME_DIR PATH=$T/bin:$MIGRATION_BASE FAKE_LOG=$T/calls.log
: >"$HOME_DIR/config/captain-channel"
printf '{"schema":2,"items":[]}\n' >"$BOARD"
printf 'branch=release/c-2\ntarget=100000\nboard=%s\ncard=migration-card\nbaseline-deleted=0\nbaseline-added=0\nfiler=test\nproject=Test\n' \
  "$BOARD" >"$HOME_DIR/config/migration-card"
# The open pull request list: number, url, title, the way the probe's own gh read prints it.
printf '%s\t%s\t%s\n' 7 https://example.test/o/r/pull/7 'Move the task inbox to local folders' \
  8 https://example.test/o/r/pull/8 'juggernaut-axi: lanes and wakes' >"$T/open-prs.tsv"
cat >"$T/bin/gh" <<'F'
#!/usr/bin/env bash
case "$*" in 'pr list'*) cat "$OPEN_PRS" ;; *) exit 1 ;; esac
F
chmod +x "$T/bin/gh"
export OPEN_PRS=$T/open-prs.tsv
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
assert_equals 16 "$(wc -l <"$ROWS")" "every part the captain named has a row"
for part in 'wake queue' 'task inbox' leases \
  'Go daemons' 'merge gate' 'escalation ladder' 'five-minute merge' deletions 'rules JSON' \
  'juggernaut-axi' 'add-on removal' 'Rego policy' 'pending-replies cleanup' 'lead-wake cleanup' \
  'line counts from git' 'captain chat (Telegram)'; do
  case $(awk -F'\t' -v p="$part" '$1 == p { print $2 }' "$ROWS") in
    live | pending | absent) ;;
    *) fail "part '$part' has no measured state, so the card would leave it blank" ;;
  esac
done

assert_contains "$(row 'wake queue')" "pending|no state/.wake-queue file" "a home with no wake queue file is pending, and says why"
assert_contains "$(row 'task inbox')" "pending|no task inbox folder" "a home with no task inbox folder is pending, and says why"
assert_contains "$(row 'leases')" "live|the store state/kv.db answers" "the lease store answers"

# The chat row: a home with no bot token is off and the probe starts nothing; with one, the row is
# whatever `jg-bus gateway status --row` measured, and a command that fails is pending, never live.
CHAT='captain chat (Telegram)'
assert_contains "$(row "$CHAT")" "absent|off: no bot token on this machine" "a home with no bot token reports the chat off"
mkdir -p "$HOME_DIR/config/captain-chat"
: >"$HOME_DIR/config/captain-chat/telegram.token"
cat >"$T/chat-stub.sh" <<'F'
#!/usr/bin/env bash
echo "$JG_HOME $*" >>"$FAKE_LOG.chat"
[ "${CHAT_STUB:-live}" = fail ] && exit 3
printf 'live\t6 of 6 legs, last 2026-11-03, 2 notes, 3 replies\n'
F
chmod +x "$T/chat-stub.sh"
JG_BUS_CMD=$T/chat-stub.sh "$ROOT/bin/jg-migration-live.sh" --quiet >/dev/null || fail "the chat probe did not run"
assert_equals "live|6 of 6 legs, last 2026-11-03, 2 notes, 3 replies" "$(row "$CHAT")" "the chat row is what the gateway measured"
assert_equals "$HOME_DIR gateway status --row" "$(tail -n 1 "$FAKE_LOG.chat")" "the probe asks the gateway for its row, in this home"
CHAT_STUB=fail JG_BUS_CMD=$T/chat-stub.sh "$ROOT/bin/jg-migration-live.sh" --quiet >/dev/null || fail "the failing chat probe did not run"
assert_equals "pending|the gateway status could not be read" "$(row "$CHAT")" "a gateway that cannot answer is pending, never live"
rm -f "$HOME_DIR/config/captain-chat/telegram.token"

printf 'one\ntwo\n' >"$HOME_DIR/state/.wake-queue"
"$ROOT/bin/jg-migration-live.sh" --quiet >/dev/null || fail "the second probe did not run"
assert_contains "$(row 'wake queue')" "live|the wake queue is the local file state/.wake-queue, 2 rows" "a wake queue file makes the queue live and counts its rows"

assert_contains "$(awk -F'\t' '$1 == "task inbox" { print $4 }' "$ROWS")" "https://example.test/o/r/pull/7" \
  "a pending part names its open pull request"
assert_contains "$(awk -F'\t' '$1 == "juggernaut-axi" { print $4 }' "$ROWS")" "https://example.test/o/r/pull/8" \
  "a part not installed names its open pull request"
assert_equals "-" "$(awk -F'\t' '$1 == "wake queue" { print $4 }' "$ROWS")" "a running part names no pull request"
assert_contains "$(awk -F'\t' '$1 == "Go daemons" { print $4 }' "$ROWS")" "no open pull request" \
  "a pending part with no open pull request says so"
printf '#!/usr/bin/env bash\nexit 1\n' >"$T/bin/gh"
"$ROOT/bin/jg-migration-live.sh" --quiet >/dev/null || fail "the probe without gh did not run"
assert_contains "$(awk -F'\t' '$1 == "task inbox" { print $4 }' "$ROWS")" "https://example.test/o/r/pull/7" \
  "a failed pull request read keeps the last list instead of blanking every link"

key=$("$ROOT/bin/jg-migration-card.sh" live)
page=$(card_page)
[ -n "$page" ] || fail "the card was not posted"
assert_contains "$key" "migration-card-" "live posts a card and names its key"
assert_contains "$(cat "$page/index.html")" "<h2>What runs on this machine</h2>" "the card carries the live section"
assert_contains "$(cat "$page/index.html")" "<td>wake queue</td><td>runs here</td>" "the card says a running part runs here"
assert_contains "$(cat "$page/index.html")" "<td>juggernaut-axi</td><td>not installed</td>" "a part this machine lacks says it is not installed"
assert_contains "$(cat "$page/index.html")" "Each line is a probe of this machine" "the card says where the lines come from"
assert_contains "$(cat "$page/index.html")" "<meta name=viewport" "the page keeps its viewport tag"
assert_contains "$(cat "$page/index.html")" '<a href="https://example.test/o/r/pull/7">#7</a>' "the card links the pull request that finishes a pending part"
assert_contains "$(cat "$page/index.html")" "parts run on this machine" "the card opens with the one-line answer"

# A fixture-installed CLI changes the measured state and removes its feature link.
printf '#!/usr/bin/env bash\nprintf "juggernaut-axi fixture\\n"\n' > "$T/bin/juggernaut-axi"
chmod +x "$T/bin/juggernaut-axi"
"$ROOT/bin/jg-migration-live.sh" --quiet >/dev/null || fail "the installed CLI probe did not run"
assert_contains "$(row 'juggernaut-axi')" "live|$T/bin/juggernaut-axi" "the installed CLI is measured live"
assert_equals "-" "$(awk -F'\t' '$1 == "juggernaut-axi" { print $4 }' "$ROWS")" "the installed CLI names no feature pull request"
rm -f "$T/bin/juggernaut-axi"
"$ROOT/bin/jg-migration-live.sh" --quiet >/dev/null || fail "the absent CLI probe did not run"

link=$("$ROOT/bin/jg-migration-live.sh" --link 2>/dev/null) || fail "--link found no card"
assert_contains "$link" "file://$T/board/reports/" "without a board address the link is the card page"
printf 'https://board.example.test/?token=abc#decide/x\n' >"$HOME_DIR/state/signoff-board.url"
assert_equals "https://board.example.test/?token=abc#reports/$(sed -n 's/^card=//p' "$HOME_DIR/config/migration-card")" \
  "$("$ROOT/bin/jg-migration-live.sh" --link)" "with a board address the link is the board deep link of the current card"

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

# The push: a row change reaches the captain's chat at once, a quiet day says so after
# push-hours, and a chat that refuses the message never costs the board its card.
# A stub probe prints fixed rows and a stub bus records its calls, so each pass is deterministic.
P=$T/push; PLOG=$T/push-calls.log; PUB=$T/published.log
mkdir -p "$P/config" "$P/state" "$P/data/migration-card" "$T/board2"
printf '{"schema":2,"items":[]}\n' >"$T/board2/board.json"
printf 'branch=release/c-2\ntarget=100000\nboard=%s/board2/board.json\ncard=push-card\nfiler=test\nproject=Test\ncritical=queue,accounts\n' "$T" >"$P/config/migration-card"
cat >"$T/probe-stub.sh" <<'F'
#!/usr/bin/env bash
case ${1-} in
  --quiet) cp "$STUB_ROWS" "$JG_HOME/data/migration-card/live.tsv" ;;
  queue) grep '^Queue server' "$STUB_ROWS" ;;
  accounts) grep '^per-home accounts' "$STUB_ROWS" ;;
esac
F
cat >"$T/bus-stub.sh" <<'F'
#!/usr/bin/env bash
case "$1 ${2-}" in
  'gateway push') [ -z "${BUS_REFUSES-}" ] || exit 2; printf '%s\n' "$3" | paste -s -d '|' >>"$PUBLISHED" ;;
esac
F
chmod +x "$T/probe-stub.sh" "$T/bus-stub.sh"
export STUB_ROWS=$T/stub-rows.tsv PUBLISHED=$PUB
set_rows() {  # <accounts-state>
  printf 'Queue server\tlive\tpid 1\t-\nper-home accounts\t%s\tthe server runs without accounts\thttps://example.test/o/r/pull/9\nwake queue\tpending\tno stream\t-\n' \
    "$1" >"$STUB_ROWS"
}
push_pass() { JG_HOME=$P FAKE_LOG=$PLOG JG_MIGRATION_LIVE_BIN=$T/probe-stub.sh JG_BUS_CMD=$T/bus-stub.sh JG_MIGRATION_CARD_NOW=$1 "$ROOT/bin/jg-migration-card.sh" live --quiet; }
posts() { grep -c '^post ' "$PLOG" 2>/dev/null || true; }
last_post() { awk '/^post /{b=""} /^dismiss /{next} {b=b $0 "\n"} END{printf "%s", b}' "$PLOG"; }
published() { grep -c . "$PUB" 2>/dev/null || true; }
T0=1000000000
set_rows pending
out=$(push_pass "$T0" 2>&1)
assert_equals "" "$out" "a push pass prints nothing"
assert_equals 1 "$(posts)" "a row change posts one card"
assert_equals 1 "$(published)" "a row change sends one chat message"
assert_contains "$(cat "$PUB")" "Queue server: live" "the digest names the first critical row"
assert_contains "$(cat "$PUB")" "per-home accounts: pending - the server runs without accounts https://example.test/o/r/pull/9" "a pending critical row carries its detail and pull request"
assert_contains "$(cat "$PUB")" "Other rows: 0 of 1 live." "the digest counts the rows that are not critical"
push_pass "$((T0 + 3600))"
assert_equals 1 "$(posts)" "a pass an hour later with no change posts no card"
assert_equals 1 "$(published)" "a pass an hour later with no change sends nothing"
push_pass "$((T0 + 86400))"
assert_equals 2 "$(posts)" "a quiet day posts one card"
assert_equals 2 "$(published)" "a quiet day sends one chat message"
assert_contains "$(tail -n 1 "$PUB")" "No migration row changed since 2001-09-09 01:46 UTC. Live: 1 of 2 critical rows. First pending: per-home accounts - the server runs without accounts." \
  "the quiet day says nothing moved, how many critical rows are live and what is first pending"
push_pass "$((T0 + 86400 + 3600))"
assert_equals 2 "$(published)" "the daily line restarts the quiet clock"
set_rows live
push_pass "$((T0 + 90000))"
assert_contains "$(tail -n 1 "$PUB")" "per-home accounts: live" "a row going live is pushed at once"
assert_equals "change daily change" "$(cut -f3 "$P/data/migration-card/push.tsv" | paste -s -d ' ')" "the push record keeps the kind of every push"
export BUS_REFUSES=1
set_rows pending
err=$(push_pass "$((T0 + 91000))" 2>&1 >/dev/null)
assert_contains "$err" "the captain chat refused the push" "a refused chat push is named on stderr"
assert_equals 3 "$(published)" "a refused push sends nothing"
assert_equals 4 "$(posts)" "the board card is still posted when the chat refuses"
assert_equals "change daily change change" "$(cut -f3 "$P/data/migration-card/push.tsv" | paste -s -d ' ')" "a refused push is still recorded, so the board gets one card per change"
unset BUS_REFUSES

# The chat push for real: the real bin/jg-bus.sh sends the table to the owner of a fake Bot API;
# a home with no token file sends nothing, prints nothing and still posts the card.
if [ -n "${JG_BUS_BIN:-}" ] || { command -v "${JG_BUS_GO:-go}" >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; }; then
  C=$T/chat; CALLS=$T/bot-calls.jsonl
  mkdir -p "$C/config/captain-chat" "$C/state" "$C/data/migration-card"
  cp "$P/config/migration-card" "$C/config/migration-card"
  cat >"$T/fake-bot.py" <<'F'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        open(sys.argv[2], "a").write(self.path.split("/")[-1] + " " + body.decode() + "\n")
        self.send_response(200); self.end_headers()
        self.wfile.write(b'{"ok":true,"result":{"message_id":501}}')
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
F
  BOT_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  python3 "$T/fake-bot.py" "$BOT_PORT" "$CALLS" &
  BOT_PID=$!
  printf 'set telegram-allow-user 4242\nset telegram-api-url http://127.0.0.1:%s\n' "$BOT_PORT" >"$C/config/captain-channel"
  # The suite library points every run at an off channel so no test reaches a real chat; this case owns its fake bot, so it takes the home's own channel file back.
  real_pass() { JG_CAPTAIN_CHANNEL='' JG_HOME=$C JG_STATE_OVERRIDE=$C/state FAKE_LOG=$T/chat-calls.log JG_MIGRATION_LIVE_BIN=$T/probe-stub.sh JG_MIGRATION_CARD_NOW=$1 \
    timeout 240 "$ROOT/bin/jg-migration-card.sh" live --quiet; }
  set_rows pending
  out=$(real_pass "$T0" 2>&1)
  assert_equals "" "$out" "no token file: the push pass prints nothing"
  [ ! -s "$CALLS" ] || fail "no token file: the chat was called"
  assert_equals 1 "$(grep -c '^post ' "$T/chat-calls.log")" "no token file: the board card is still posted"
  printf '123456:FAKE-token\n' >"$C/config/captain-chat/telegram.token"; chmod 600 "$C/config/captain-chat/telegram.token"
  set_rows live
  out=$(real_pass "$((T0 + 100))" 2>&1)
  assert_equals "" "$out" "the chat push pass prints nothing"
  assert_equals 1 "$(grep -c '^sendMessage ' "$CALLS")" "a row change sends one chat message"
  assert_contains "$(cat "$CALLS")" '"chat_id":4242' "the message goes to the paired owner"
  assert_contains "$(cat "$CALLS")" 'per-home accounts: live' "the message carries the live table"
  assert_equals 2 "$(grep -c '^post ' "$T/chat-calls.log")" "the board gets its card beside the chat message"
  real_pass "$((T0 + 100 + 3600))"
  assert_equals 1 "$(grep -c '^sendMessage ' "$CALLS")" "an hour with no change sends nothing"
  real_pass "$((T0 + 100 + 86400))"
  assert_equals 2 "$(grep -c '^sendMessage ' "$CALLS")" "a quiet day is a plain chat message"
  assert_contains "$(tail -n 1 "$CALLS")" "No migration row changed since" "a no-change day says so plainly"
  kill "$BOT_PID" 2>/dev/null || true
  wait "$BOT_PID" 2>/dev/null || true
  BOT_PID=
else
  echo "skip: the real chat push needs the Go toolchain (or JG_BUS_BIN) and python3"
fi

pass "the migration card measures every part on this machine and keeps itself current"

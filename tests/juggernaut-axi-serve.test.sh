#!/usr/bin/env bash
# Behavior test for `juggernaut-axi serve`: opt-in token, loopback bind, bearer auth, read-only
# routes with JSON/TOON parity, Host/Origin/method/body refusals, query validation, rate limits.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for tool in jq curl python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

AXI="$ROOT/bin/juggernaut-axi"
TMP_ROOT=$(jg_test_tmproot juggernaut-axi-serve)
H=$TMP_ROOT/home
mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects" "$TMP_ROOT/fixture-root"
# The backlog is a Beads store holding one queued task.
jg_test_beads_home "$H"
jg_test_backlog "$H" add q-1 '[feature] Queued one' --priority 1 --kind ship --repo juggernaut --body 'Fixture task q-1' >/dev/null \
  || fail "could not file the queued task"
export JG_HOME=$H JG_ROOT_OVERRIDE=$TMP_ROOT/fixture-root
TOKEN=0123456789abcdef0123456789abcdef0123456789

"$AXI" serve >/dev/null 2>"$TMP_ROOT/err" && fail "serve must refuse without a token"
assert_contains "$(cat "$TMP_ROOT/err")" "opt-in" "missing token names the opt-in"
printf '%s\n' "$TOKEN" > "$H/config/juggernaut-axi-token"; chmod 644 "$H/config/juggernaut-axi-token"
"$AXI" serve >/dev/null 2>"$TMP_ROOT/err" && fail "serve must refuse a group/world-readable token"
assert_contains "$(cat "$TMP_ROOT/err")" "owner-only" "loose token mode is refused"
chmod 600 "$H/config/juggernaut-axi-token"

"$AXI" serve --reads-per-minute 7 > "$TMP_ROOT/out" 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null' EXIT
for _ in $(seq 50); do grep -q listening "$TMP_ROOT/out" 2>/dev/null && break; sleep 0.1; done
PORT=$(sed -n 's#.*http://127.0.0.1:\([0-9]*\).*#\1#p' "$TMP_ROOT/out")
[ -n "$PORT" ] || fail "server did not report a loopback port: $(cat "$TMP_ROOT/out")"
B=http://127.0.0.1:$PORT
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
auth=(-H "Authorization: Bearer $TOKEN")

assert_equals 401 "$(code "$B/v1/status")" "no token is refused"
assert_equals 401 "$(code -H 'Authorization: Bearer wrong' "$B/v1/status")" "wrong token is refused"
assert_equals 200 "$(code "${auth[@]}" "$B/v1/status")" "good token reads status"
assert_equals juggernaut-axi.v1 "$(curl -s "${auth[@]}" "$B/v1/tickets" | jq -r .schema)" "JSON carries the schema"
assert_equals q-1 "$(curl -s "${auth[@]}" "$B/v1/tickets?repo=juggernaut&limit=5" | jq -r '.tickets[0].id')" "query filters apply"
assert_contains "$(curl -s "${auth[@]}" -H 'Accept: application/toon' "$B/v1/tickets")" "view: tickets" "TOON on request"
assert_equals 403 "$(code "${auth[@]}" -H 'Origin: http://evil.example' "$B/v1/status")" "Origin is refused"
assert_equals 403 "$(code "${auth[@]}" -H 'Host: evil.example' "$B/v1/status")" "foreign Host is refused"
assert_equals 405 "$(code "${auth[@]}" -X POST "$B/v1/status")" "writes are refused at this scope"
assert_equals 413 "$(code "${auth[@]}" -X GET -d x "$B/v1/status")" "bodies are refused"
assert_equals 400 "$(code "${auth[@]}" "$B/v1/tickets?limit=../x")" "bad query value is refused"
assert_equals 400 "$(code "${auth[@]}" "$B/v1/messages?task=guessed")" "unknown task is a client error"
assert_equals 404 "$(code "${auth[@]}" "$B/v1/spawn")" "unlisted routes do not exist"
assert_equals 429 "$(code "${auth[@]}" "$B/v1/status")" "reads are rate limited per token"
assert_not_contains "$(cat "$TMP_ROOT/out")" "$TOKEN" "the token is never logged"
pass "juggernaut-axi serve"

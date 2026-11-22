#!/usr/bin/env bash
# Drive the real API, CLI and steering inbox on an isolated installation.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
unset JG_CONFIG_OVERRIDE JG_DATA_OVERRIDE JG_STATE_OVERRIDE JG_CAPTAIN_CHANNEL
# shellcheck source=tests/lib.sh
. "$here/../../../tests/lib.sh"
T=$(jg_test_tmproot api-changes)
export HOME=$T/user XDG_CONFIG_HOME=$T/xdg-config XDG_DATA_HOME=$T/xdg-data
export XDG_STATE_HOME=$T/xdg-state XDG_CACHE_HOME=$T/xdg-cache TMPDIR=$T/tmp
export JG_HOME=$T/home JG_ROOT_OVERRIDE=$T/root JG_SEND_SETTLE=0
mkdir -p "$HOME" "$TMPDIR" "$JG_HOME"/{config,data,state,projects} "$JG_ROOT_OVERRIDE" "$T/bin"
cd "$JG_HOME"
unset JG_TASK_INBOX JG_TICKET
AXI=$ROOT/bin/juggernaut-axi
JG=$ROOT/bin/jg
jg_test_beads_home "$JG_HOME"
jg_write_meta "$JG_HOME/state/t1.meta" window=api-fixture:jg-t1 kind=ship harness=claude backend=tmux
# Record the actual inbox, with a stand-in for the best-effort terminal bell.
printf '#!/bin/sh\nexit 0\n' > "$T/bin/tmux"
chmod +x "$T/bin/tmux"
export PATH="$T/bin:$PATH"
read_secret=$(printf 'a%.0s' {1..40})
write_secret=$(printf 'b%.0s' {1..40})
read_file=$JG_HOME/config/juggernaut-axi-token
write_file=$JG_HOME/config/juggernaut-axi-write-token
read_auth=(-H "Authorization: Bearer $read_secret")
write_auth=(-H "Authorization: Bearer $write_secret")
json=(-H 'Content-Type: application/json')
post=/v1/radio/send
body='{"ticket":"t1","text":"Fixture message for Umer"}'

pid=
stop_server() {
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    pid=
  fi
}
trap 'stop_server; jg_test_cleanup' EXIT
start_server() {
  "$AXI" serve > "$T/server" 2>&1 &
  pid=$!
  local port=
  for _ in $(seq 100); do
    port=$(sed -n 's#^listening http://127.0.0.1:\([0-9]*\)$#\1#p' "$T/server")
    [ -z "$port" ] || break
    kill -0 "$pid" 2>/dev/null || break
    sleep .1
  done
  [ -n "$port" ] || fail "server did not start: $(cat "$T/server")"
  url=http://127.0.0.1:$port
}
request() {
  local expected=$1 route=$2 status
  shift 2
  status=$(curl -q --noproxy '*' --max-time 30 -sS -o "$T/response" -w '%{http_code}' "$@" "$url$route")
  assert_equals "$expected" "$status" "$route"
}
inbox_count() {
  local files=("$JG_HOME/state/t1.inbox/"*.msg)
  if [ -f "${files[0]}" ]; then printf '%s\n' "${#files[@]}"; else printf '0\n'; fi
}
token_file() { (umask 077; printf '%s\n' "$1" > "$2"); }
refuse_start() {
  if "$AXI" serve "$@" > "$T/refused" 2>&1; then fail 'serve accepted invalid configuration'; fi
}

refuse_start
token_file "$read_secret" "$read_file"
start_server
for route in status tickets decisions 'messages?task=t1' sitrep/lanes; do
  request 200 "/v1/$route" "${read_auth[@]}"
done
request 403 "$post" "${read_auth[@]}" "${json[@]}" --data "$body"
assert_equals 'changes are off on this installation' "$(jq -r .error "$T/response")" 'read-only upgrade'
assert_equals 0 "$(inbox_count)" 'no change without write opt-in'
stop_server

refuse_start --host 0.0.0.0
token_file "$read_secret" "$write_file"
refuse_start
assert_contains "$(cat "$T/refused")" 'different' 'identical write token refused'
token_file "$write_secret" "$write_file"
chmod 640 "$write_file"
refuse_start
assert_contains "$(cat "$T/refused")" '0600' 'loose write token permissions refused'
chmod 600 "$write_file"
start_server
request 200 /v1/status "${read_auth[@]}"
request 401 /v1/status "${write_auth[@]}"
request 403 "$post" "${read_auth[@]}" "${json[@]}" --data "$body"
request 401 "$post" "${json[@]}" --data "$body"
request 403 "$post" "${write_auth[@]}" -H 'Host: outside.example' "${json[@]}" --data "$body"
request 403 "$post" "${write_auth[@]}" -H 'Origin: http://outside.example' "${json[@]}" --data "$body"
request 405 /v1/status "${write_auth[@]}" --request POST
request 404 /v1/missing-route "${write_auth[@]}" --request POST
request 413 "$post" "${write_auth[@]}" "${json[@]}" --data "$(printf '%65537s' x)"
request 400 "$post" "${write_auth[@]}" "${json[@]}" --data '{"ticket":"t1","ticket":"t2"}'
assert_equals 0 "$(inbox_count)" 'refused requests wrote no messages'

message='Fixture message for Umer'
"$JG" radio send t1 "$message" --key from-cli > "$T/cli"
cp "$JG_HOME/state/t1.inbox/001.msg" "$T/first-message"
request 200 "$post" "${write_auth[@]}" "${json[@]}" -H 'Idempotency-Key: from-cli' --data "$body"
jq -e '.ok and .data.status == "already processed"' "$T/response" >/dev/null
assert_equals 1 "$(inbox_count)" 'CLI then HTTP with the same key produces one message'
cmp "$T/first-message" "$JG_HOME/state/t1.inbox/001.msg"
request 400 "$post" "${write_auth[@]}" "${json[@]}" -H 'Idempotency-Key: from-cli' \
  --data '{"ticket":"t1","text":"Fixture message for Umer","again":true}'
assert_equals 1 "$(inbox_count)" 'replay cannot also request a fresh send'

request 200 "$post" "${write_auth[@]}" "${json[@]}" -H 'Idempotency-Key: from-http' --data "$body"
cmp "$T/cli" "$T/response"
assert_equals 2 "$(inbox_count)" 'POST writes exactly one new durable message'
assert_contains "$(cat "$JG_HOME/state/t1.inbox/002.msg")" "$message" 'POST wrote the intended text'
"$JG" radio send t1 "$message" --key from-http > "$T/repeat"
jq -e '.ok and .data.status == "already processed"' "$T/repeat" >/dev/null
assert_equals 2 "$(inbox_count)" 'HTTP then CLI shares the same repeat record'
request 200 "$post" "${write_auth[@]}" "${json[@]}" --data '["t1","Another fixture message"]'
assert_equals 3 "$(inbox_count)" 'CLI word array reaches the same dispatcher'
assert_not_contains "$(cat "$T/server")" "$write_secret" 'write token is never logged'
pass 'contract API write opt-in, authorization, limits, dispatch and repeat keys'

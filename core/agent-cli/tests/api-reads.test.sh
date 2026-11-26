#!/usr/bin/env bash
# Contract API journey on a throwaway home.
set -eu
if [ -n "${DONE_DONE_EVIDENCE_ROOT:-}" ]; then
  exec > >(tee "$DONE_DONE_EVIDENCE_ROOT/api-reads.log") 2>&1
fi
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/../../../tests/wake-helpers.sh"
T=$(jg_test_tmproot api-reads)
H=$T/home
mkdir -p "$H"/{config,data,state,projects} "$T/root"
jg_test_beads_home "$H"
jg_test_backlog "$H" add q-1 '[feature] Fixture' --priority 1 --kind ship --repo alpha --body fixture >/dev/null
jg_write_meta "$H/state/w1.meta" window=sess:jg-w1 kind=ship harness=claude
export JG_HOME=$H JG_ROOT_OVERRIDE=$T/root JG_SNAPSHOT_NOW=2026-11-21T00:00:00Z JG_BEARINGS_NOW=2026-11-21T00:00:00Z
TOKEN=0123456789abcdef0123456789abcdef0123456789
printf '%s\n' "$TOKEN" > "$H/config/juggernaut-axi-token"
chmod 600 "$H/config/juggernaut-axi-token"
"$ROOT/bin/juggernaut-axi" serve --reads-per-minute 100 > "$T/server" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
for _ in $(seq 50); do grep -q listening "$T/server" && break; sleep .1; done
port=$(sed -n 's#.*127.0.0.1:\([0-9]*\).*#\1#p' "$T/server")
[ -n "$port" ] || fail 'server did not start'
url=http://127.0.0.1:$port
get() { curl -fsS -H "Authorization: Bearer $TOKEN" "$url$1"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
for pair in 'status:status' 'tickets:tickets' 'decisions:decisions' 'messages?task=w1:messages w1'; do
  route=${pair%%:*}; cmd=${pair#*:}
  # shellcheck disable=SC2086
  "$ROOT/bin/juggernaut-axi" $cmd --json > "$T/expected"
  get "/v1/$route" > "$T/actual"
  cmp -s "$T/expected" "$T/actual" || { diff -u "$T/expected" "$T/actual"; fail "$route differs from legacy CLI"; }
done
"$ROOT/bin/jg" sitrep lanes --json > "$T/expected"
get /v1/sitrep/lanes > "$T/actual"
cmp -s "$T/expected" "$T/actual" || fail 'sitrep lanes differs from dispatcher'
"$ROOT/bin/jg" sitrep lanes --state working --full --json > "$T/expected"
get '/v1/sitrep/lanes?state=working&full=true' > "$T/actual"
cmp -s "$T/expected" "$T/actual" || fail 'filter and flag differ from dispatcher'
[ "$(code -H "Authorization: Bearer $TOKEN" "$url/v1/sitrep/lanes?full=maybe")" = 400 ] || fail 'invalid flag accepted'
[ "$(code -H "Authorization: Bearer $TOKEN" "$url/v1/sitrep/lanes?state=x&state=y")" = 400 ] || fail 'duplicate parameter accepted'
"$ROOT/bin/jg" sitrep messages w1 --json > "$T/expected"
get '/v1/sitrep/messages?task-id=w1' > "$T/actual"
cmp -s "$T/expected" "$T/actual" || fail 'required argument differs from dispatcher'
[ "$(code -H "Authorization: Bearer $TOKEN" "$url/v1/sitrep/messages")" = 400 ] || fail 'missing argument accepted'
[ "$(code -H "Authorization: Bearer $TOKEN" "$url/v1/radio/send")" = 405 ] || fail 'POST route accepted'
[ "$(code "$url/v1/sitrep/lanes")" = 401 ] || fail 'missing token accepted'
[ "$(code -H 'Authorization: Bearer wrong' "$url/v1/sitrep/lanes")" = 401 ] || fail 'wrong token accepted'
pass 'contract API reads'

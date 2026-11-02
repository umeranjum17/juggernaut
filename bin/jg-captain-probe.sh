#!/usr/bin/env bash
# jg-captain-probe.sh - prove on THIS machine that a captain-bound event travels
# bus -> ntfy, with real traffic and a delivery record.
#
# It prints, in order:
#   1. the processes that make up the stack (nats-server, daprd, ntfy, the deliver consumer)
#   2. the CAPTAIN stream and the captain-ntfy consumer counts BEFORE
#   3. one real event published through the real path (`bin/jg-bus.sh publish probe ...`)
#      to the captain's own configured topic and nowhere else
#   4. the same counts AFTER
#   5. the delivery record line for the event (state/captain-channel-delivered.jsonl)
#   6. ntfy's own delivery log line for the same message id
# It waits for the delivery by blocking on the delivery record file (tail -F), never by
# sleeping or polling, and gives up after JG_PROBE_WAIT seconds (default 20).
#
#   7. with ntfy logins provisioned: the captain login reads the event over ntfy-server, and an
#      anonymous publish and the read-only login's publish are both refused
# Exit 0 only when the stream count rose, the consumer delivered, the record names the
# event and ntfy's own log names the same message id (and, with logins, step 7 holds); otherwise 1 with the missing proof.
# Env: JG_HOME, JG_STATE_OVERRIDE (the home probed), JG_PROBE_WAIT.
set -u
SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
export JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
BUS="$SCRIPT_DIR/jg-bus.sh"
export PATH=${NPM_CONFIG_PREFIX:-$HOME/.local}/bin:$PATH  # where bin/jg-stack.sh installs nats
RECORD=$STATE/captain-channel-delivered.jsonl
WAIT=${JG_PROBE_WAIT:-20}
command -v jq >/dev/null 2>&1 || { echo "probe: needs jq"; exit 1; }

stream=$("$BUS" config stream) || exit 1
nats_url=$("$BUS" config nats-url)
ntfy_server=$("$BUS" config ntfy-server)
topic=$("$BUS" config ntfy-topic)
auth=(); acct=$("$BUS" account 2>/dev/null | cut -f1)
[ -z "$acct" ] || [ ! -s "$STATE/bus/$acct.pass" ] || auth=(--user "$acct" --password "$(tr -d '\n' < "$STATE/bus/$acct.pass")")
nats_cli() { nats "${auth[@]}" -s "$nats_url" "$@"; }

counts() {  # one line: stream messages, consumer delivered / acked / pending
  local s c
  s=$(nats_cli stream info "$stream" --json 2>/dev/null | jq -r '.state.messages // "?"')
  c=$(nats_cli consumer info "$stream" captain-ntfy --json 2>/dev/null \
    | jq -r '"delivered=\(.delivered.stream_seq) acked=\(.ack_floor.stream_seq) pending=\(.num_pending) ack-pending=\(.num_ack_pending)"')
  echo "stream $stream messages=$s; consumer captain-ntfy ${c:-missing}"
}
stream_messages() { nats_cli stream info "$stream" --json 2>/dev/null | jq -r '.state.messages // 0'; }

echo "== processes (this home's: its unit main pids and its recorded pids)"
pids=$(cat "$STATE"/bus/*.pid 2>/dev/null)
for u in bus dapr ntfy deliver; do
  pids="$pids $(systemctl --user show -p MainPID --value "${JG_STACK_UNIT_PREFIX:-jg}-$u.service" 2>/dev/null)"
done
pids=$(echo "$pids" | tr -s ' ' '\n' | awk '$1 > 0' | paste -sd, -)
[ -z "$pids" ] || ps -o pid=,etimes=,args= -p "$pids" | awk '{ printf "pid %s up %ss  %s\n", $1, $2, substr($0, index($0, $3), 150) }'
echo "== before"
counts
before=$(stream_messages)
key="probe-$(date +%s)-$$"
lines=$({ cat "$RECORD" 2>/dev/null || true; } | wc -l)
echo "== publish: bin/jg-bus.sh publish probe $key (the captain's own topic $ntfy_server/$topic)"
"$BUS" publish probe "$key" "Captain channel probe $key: bus to ntfy is live." || exit 1
record=$(timeout "$WAIT" tail -n +$((lines + 1)) -F "$RECORD" 2>/dev/null | grep -m1 -F "\"key\":\"$key\"")
echo "== after"
counts
after=$(stream_messages)
ok=1
echo "== delivery record ($RECORD)"
if [ -n "$record" ]; then echo "$record"; else echo "MISSING: no delivery record for $key within ${WAIT}s"; ok=0; fi
[ "${after:-0}" -gt "${before:-0}" ] || { echo "MISSING: stream count did not rise ($before -> $after)"; ok=0; }
id=$(printf '%s' "$record" | jq -r '.ntfy_id // empty' 2>/dev/null)
echo "== ntfy's own log for message $id"
log=""
if [ -n "$id" ]; then
  log=$(grep -F "message_id=$id" "$STATE/bus/ntfy.log" 2>/dev/null | grep -m1 'Received message' | cut -c1-260)
  [ -n "$log" ] || log=$(journalctl --user -u "${JG_STACK_UNIT_PREFIX:-jg}-ntfy.service" --no-pager -o cat 2>/dev/null | grep -F "message_id=$id" | grep -m1 'Received message' | cut -c1-260)
fi
if [ -n "$log" ]; then echo "$log"; else echo "MISSING: ntfy's log has no Received message line for id '$id'"; ok=0; fi
# When the server has logins (bus owner's ntfy-provision), prove the three rights over the address his iPad
# uses: the captain login reads the event, and neither an anonymous request nor the read-only login can publish.
captain_pass=$STATE/bus/ntfy-captain.pass
if [ -s "$captain_pass" ]; then
  echo "== ntfy auth at $ntfy_server (the address the iPad reaches)"
  login=captain:$(tr -d '\n' < "$captain_pass")
  read_back=$(curl -sS --max-time 10 -u "$login" "$ntfy_server/$topic/json?poll=1&since=all" 2>&1 | grep -F "\"id\":\"$id\"" | cut -c1-200)
  if [ -n "$read_back" ]; then echo "captain login read the event: $read_back"; else echo "MISSING: the captain login could not read message '$id'"; ok=0; fi
  anon=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -d probe "$ntfy_server/$topic" 2>&1)
  reader=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -u "$login" -d probe "$ntfy_server/$topic" 2>&1)
  echo "anonymous publish: HTTP $anon; captain (read-only) publish: HTTP $reader"
  case $anon in 401|403) ;; *) echo "MISSING: an anonymous publish was not refused"; ok=0 ;; esac
  case $reader in 401|403) ;; *) echo "MISSING: the read-only login could publish"; ok=0 ;; esac
fi
[ "$ok" = 1 ] && echo "probe: PASS bus -> ntfy, stream $before -> $after, message $id" || echo "probe: FAIL"
[ "$ok" = 1 ]

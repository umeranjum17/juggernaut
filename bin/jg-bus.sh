#!/usr/bin/env bash
# jg-bus.sh - the captain channel's one command: the shadow bus tee, the three
# services it talks to, and the reply router.
#
# WHY THIS EXISTS (migration step 5a). The fleet reaches the captain through
# files and alerts scattered across the tree. The decided shape is one captain
# channel on a bus: the events that are his to see (a decision waiting, an
# outcome released with its proof link, a blocker, an alert) are published once,
# delivered to his iPad by ntfy, and his replies come back as events routed to
# the lead that owns them. This step puts that channel in SHADOW: every event is
# teed and none of today's delivery paths change, so nothing user-visible
# switches until this path's parity is proven.
#
# CONTRACT (this header is the one owner of the bus' shape).
#   config   defaults/captain-channel, then a home's config/captain-channel,
#            then JG_CAPTAIN_CHANNEL; the first file carrying a key wins, so an
#            override may set one key. Nothing here is hard-coded: addresses,
#            subjects, stream name, whether ntfy delivers, and the relay switch
#            are all in that file. `config <key>` prints the value in force.
#   record   $STATE/captain-channel.jsonl, one JSON event per line, appended
#            before anything is published. It is the shadow record: an event is
#            never lost to an unreachable bus or an absent service, and it is
#            what proves the tee saw every captain-facing event.
#   publish  Tee one event: record it, publish it to the bus through the Dapr
#            sidecar (the component file picks the backend; the code does not
#            know NATS from anything else), and fan it out to ntfy when the
#            config says ntfy delivers. A shadow tee never breaks its emitter:
#            every transport failure is logged once to $STATE/captain-channel.log
#            and the command still exits 0.
#   ntfy     Delivery to the captain. `set ntfy-deliver on` turns delivery on;
#            it is off by default so the shadow run changes nothing he sees.
#            `set ntfy-relay off` is the relay switch: off publishes only to the
#            configured local server, on sends the same event through
#            ntfy-relay-server. The captain has not answered the relay question,
#            so the shipped value is off and no code path needs it on.
#   reply    One captain reply event, JSON {"key","at","answer"[,"label"]}, on
#            stdin or in a file. Routing is NOT re-decided here: it is the route
#            bin/jg-board-answers.sh already keeps (state/board-routes/<card-key>)
#            and the same marked answer line and decision close it sends, so a
#            reply reaching the bus routes to the lead a board answer routes to.
#            An unrouted card is refused, exactly as today, and its answer stays
#            with Main.
#   serve    Start the three services from their files, every one of them read
#            as config and none re-implemented here: nats-server
#            (core/bus/nats.conf), the JetStream stream it carries
#            (core/bus/stream.json), the slim Dapr runtime over NATS
#            (core/bus/dapr/components/pubsub.yaml) and ntfy (core/bus/ntfy.yml).
#            A home may override any of them under config/bus/. Pids and logs
#            live in $STATE/bus/, so `stop` and `status` are per home.
#            A service whose binary is missing is named and not started; the
#            others still run, because the record never depends on them.
#
# Usage:
#   jg-bus.sh config [<key>]
#   jg-bus.sh publish <kind> <key> <text> [--link <url>]
#   jg-bus.sh reply [<event.json>]
#   jg-bus.sh serve | stop | status | bootstrap
set -u
export LC_ALL=C
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
RUNTIME=$STATE/bus
RECORD=$STATE/captain-channel.jsonl
LOG=$STATE/captain-channel.log
die() { printf 'jg-bus: %s\n' "$*" >&2; exit 2; }
say() { printf '%s\n' "$*" >&2; }

# The file a service reads, home override first.
bus_file() {  # <path under core/bus> -> prints the file in force
  if [ -f "$JG_HOME/config/bus/$1" ]; then printf '%s' "$JG_HOME/config/bus/$1"
  else printf '%s' "$ROOT/core/bus/$1"; fi
}

# One key from the channel config, first file that carries it wins.
cfg() {  # <key>
  local key=$1 file v
  for file in "${JG_CAPTAIN_CHANNEL:-}" "$JG_HOME/config/captain-channel" "$ROOT/defaults/captain-channel"; do
    [ -n "$file" ] && [ -f "$file" ] || continue
    v=$(awk -v k="$key" '$1 == "set" && $2 == k { sub(/^[[:space:]]*set[[:space:]]+[^[:space:]]+[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; exit }' "$file")
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  done
  return 1
}
is_on() { [ "$(cfg "$1" 2>/dev/null)" = on ]; }

# JSON string escaping for the record and the transported event. Multiline text
# becomes \n, so one event stays one line.
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'BEGIN{ORS=""} NR>1{print "\\n"} {print}'; }

note_failure() {  # <what> <detail>
  printf '%s failed: %s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-300)" >>"$LOG" 2>/dev/null || true
}

# The URL a delivery goes to: the local server, or the relay when the captain
# turns that switch on. One owner of the relay rule.
ntfy_url() {
  local server
  if is_on ntfy-relay; then server=$(cfg ntfy-relay-server); else server=$(cfg ntfy-server); fi
  printf '%s/%s' "${server%/}" "$(cfg ntfy-topic)"
}

post() {  # <url> <body> [curl args...]; prints curl's error, returns its status
  local url=$1 body=$2
  shift 2
  curl -sS -o /dev/null --max-time 5 -X POST --data-binary "$body" "$@" "$url" 2>&1
}

cmd_config() {
  local key=${1:-}
  if [ -n "$key" ]; then cfg "$key" || die "no '$key' in the channel config"; return 0; fi
  printf 'channel config in force:\n'
  while read -r tag key _; do
    [ "${tag:-}" = set ] || continue
    printf '  %-18s %s\n' "$key" "$(cfg "$key")"
  done < "$ROOT/defaults/captain-channel"
}

# Tee one captain-facing event. Never fails its emitter: this is a shadow path.
cmd_publish() {
  local kind=${1-} key=${2-} text=${3-} link='' json subject title out
  [ "$#" -ge 3 ] || die "publish needs <kind> <key> <text>"
  shift 3
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --link) link=${2:-}; shift 2 || die "publish --link needs a url" ;;
      *) die "publish: unknown flag $1" ;;
    esac
  done
  is_on shadow || return 0
  subject="$(cfg subject-prefix).$kind"
  json=$(printf '{"at":%s,"kind":"%s","key":"%s","subject":"%s","text":"%s"%s}' \
    "$(date +%s)" "$(esc "$kind")" "$(esc "$key")" "$(esc "$subject")" "$(esc "$text")" \
    "${link:+,\"link\":\"$(esc "$link")\"}")
  mkdir -p "$STATE" 2>/dev/null
  printf '%s\n' "$json" >>"$RECORD" 2>/dev/null || note_failure record "$json"
  if ! out=$(post "$(cfg dapr-http-url)/v1.0/publish/$(cfg dapr-pubsub)/$subject" "$json"); then
    note_failure "bus $subject" "${out:-unreachable}"
  fi
  if is_on ntfy-deliver; then
    title=$(printf '%s' "$text" | head -n 1 | cut -c1-120)
    if ! out=$(post "$(ntfy_url)" "$text" -H "Title: $title" -H "Tags: $(cfg ntfy-tag)"); then
      note_failure "ntfy" "${out:-unreachable}"
    fi
  fi
  return 0
}

# Route one captain reply event by the rule in force: the board's own route.
cmd_reply() {
  local src=${1:--} event key at answer label
  command -v jq >/dev/null 2>&1 || die "reply needs jq to read a reply event"
  if [ "$src" = - ]; then event=$(cat); else [ -f "$src" ] || die "no such reply event file: $src"; event=$(cat "$src"); fi
  [ -n "$event" ] || die "no reply event on stdin"
  key=$(printf '%s' "$event" | jq -r '.key // empty') || die "the reply event is not JSON"
  at=$(printf '%s' "$event" | jq -r '.at // empty')
  answer=$(printf '%s' "$event" | jq -r '.answer // empty')
  label=$(printf '%s' "$event" | jq -r '.label // empty')
  [ -n "$key" ] && [ -n "$answer" ] || die "a reply event needs a card key and the answer"
  JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/jg-board-answers.sh" route-answer \
    "$key" "${at:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" "$answer" "$label"
}

start_one() {  # <name> <command...>; CWD is the runtime dir
  local name=$1 pid
  shift
  [ -f "$RUNTIME/$name.pid" ] && kill -0 "$(cat "$RUNTIME/$name.pid")" 2>/dev/null && { say "$name: already running"; return 0; }
  "$@" >"$RUNTIME/$name.log" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >"$RUNTIME/$name.pid"
  say "$name: started ($pid), log $RUNTIME/$name.log"
}

wait_port() {  # <host> <port>
  local _
  for _ in $(seq 100); do
    (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null && { exec 3>&- 2>/dev/null; return 0; }
    sleep 0.1
  done
  return 1
}

# The JetStream stream, from its file. Needs the nats client; without it the
# event record still holds every event, so this is a reported skip, not a stop.
cmd_bootstrap() {
  local conf=$ROOT/core/bus/stream.json name
  name=$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$conf" | head -1)
  if ! command -v nats >/dev/null 2>&1; then
    say "stream: not created, no nats client on PATH (the event record still holds every event)"
    return 0
  fi
  nats -s "$(cfg nats-url)" stream add --config "$conf" >"$RUNTIME/stream.log" 2>&1 && say "stream: $name ready"
}

cmd_serve() {
  local nats_url hostport
  mkdir -p "$RUNTIME" || die "cannot create $RUNTIME"
  nats_url=$(cfg nats-url)
  hostport=${nats_url#*://}
  cd "$RUNTIME" || die "cannot enter $RUNTIME"
  if command -v nats-server >/dev/null 2>&1; then
    start_one nats nats-server -c "$(bus_file nats.conf)"
    if wait_port "${hostport%%:*}" "${hostport##*:}"; then
      say "nats: listening on $nats_url"
      cmd_bootstrap
    else
      say "nats: did not start; see $RUNTIME/nats.log"
    fi
  else
    say "nats: not started, no nats-server on PATH"
  fi
  if command -v daprd >/dev/null 2>&1; then
    local components
    components=$(dirname "$(bus_file dapr/components/pubsub.yaml)")
    start_one dapr daprd --app-id "$(cfg dapr-app-id)" --dapr-http-port "$(cfg dapr-http-port)" \
      --dapr-grpc-port "$(cfg dapr-grpc-port)" --enable-metrics=false \
      --resources-path "$components"
  else
    say "dapr: not started, no daprd on PATH"
  fi
  if command -v ntfy >/dev/null 2>&1; then
    start_one ntfy ntfy serve -c "$(bus_file ntfy.yml)"
  else
    say "ntfy: not started, no ntfy on PATH"
  fi
  return 0
}

cmd_stop() {
  local name pid
  for name in nats dapr ntfy; do
    [ -f "$RUNTIME/$name.pid" ] || continue
    pid=$(cat "$RUNTIME/$name.pid")
    kill "$pid" 2>/dev/null && say "$name: stopped"
    rm -f "$RUNTIME/$name.pid"
  done
  return 0
}

cmd_status() {
  local name pid state events=0
  [ -f "$RECORD" ] && events=$(wc -l <"$RECORD" | tr -d ' ')
  printf 'shadow %s, ntfy delivery %s, relay %s\n' \
    "$(cfg shadow)" "$(cfg ntfy-deliver)" "$(cfg ntfy-relay)"
  printf 'record %s: %s event(s)\n' "$RECORD" "$events"
  for name in nats dapr ntfy; do
    state=down
    if [ -f "$RUNTIME/$name.pid" ]; then
      pid=$(cat "$RUNTIME/$name.pid")
      kill -0 "$pid" 2>/dev/null && state="up ($pid)"
    fi
    printf '%s: %s\n' "$name" "$state"
  done
}

case "${1:-status}" in
  config) shift; cmd_config "$@" ;;
  publish) shift; cmd_publish "$@" ;;
  reply) shift; cmd_reply "$@" ;;
  serve) shift; cmd_serve "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  bootstrap) shift; mkdir -p "$RUNTIME" && cd "$RUNTIME" && cmd_bootstrap "$@" ;;
  status) cmd_status ;;
  *) die "unknown command: $1" ;;
esac

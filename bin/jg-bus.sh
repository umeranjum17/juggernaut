#!/usr/bin/env bash
# jg-bus.sh - the captain channel's one command: the live tee, the three
# services it talks to, the reply router, and the parity replay.
#
# WHY THIS EXISTS (migration step 5a, switched live). The fleet reaches the
# captain through files and alerts scattered across the tree. The decided shape
# is one captain channel on a bus: the events that are his to see (a decision
# waiting, an outcome released with its proof link, a blocker, an alert) are
# published once, delivered to his iPad by ntfy, and his replies come back as
# events routed to the lead that owns them. That channel ran in shadow while its
# parity was proven; `set mode live` is the shipped value now, so a change of
# state reaches the captain by this path.

# CONTRACT (this header is the one owner of the bus' shape).
#   config   defaults/captain-channel, then a home's config/captain-channel,
#            then JG_CAPTAIN_CHANNEL; the first file carrying a key wins, so an
#            override may set one key. Nothing here is hard-coded: addresses,
#            subjects, stream name, the mode, and the relay switch are all in
#            that file. `config <key>` prints the value in force.
#   mode     `set mode live` is the one switch that decides what this path does,
#            and live is what ships:
#              live    record it, publish it, and deliver it to his iPad.
#              shadow  record and publish only, so the path observes and nothing
#                      he sees changes. This is the one-step reversal.
#              off     do nothing at all.
#            The shadow tee's own two keys, `shadow` and `ntfy-deliver`, are gone
#            with it: the mode replaced both, so nothing can turn delivery on
#            without also turning the path live.
#   record   $STATE/captain-channel.jsonl, one JSON event per line, appended
#            before anything is published. An event is never lost to an
#            unreachable bus or an absent service, and it is what a replay and a
#            resend read.
#   publish  Tee one event: record it, publish it to the bus through the Dapr
#            sidecar (the component file picks the backend; the code does not
#            know NATS from anything else), and, when the mode is live, deliver
#            it to the captain. It never breaks its emitter, because the two
#            callers are today's own delivery paths: every transport failure is
#            logged once to $STATE/captain-channel.log and the command still
#            exits 0.
#   undelivered  A live delivery that fails is also appended, with its error, to
#            $STATE/captain-channel-undelivered.jsonl, and `status` counts them.
#            A live path must not lose an event it was going to deliver without
#            saying so. Nothing retries on its own: the record holds the event
#            and this file names the one that did not arrive.
#   parity   Replay every recorded event through the builder the live path sends
#            with and compare it with the event the record holds: what he would
#            have seen and what he will get are one diff. The delivery target is
#            the one decision the switch flips, so parity reports it instead of
#            diffing it. `--corrupt` tampers with one replayed event on the new
#            side only, which the same diff must then report, so a green run is
#            never vacuous.
#   ntfy     Delivery to the captain, at the configured topic. `set ntfy-relay
#            off` is the relay switch: off delivers only to the configured local
#            server, on sends the same event through ntfy-relay-server. The
#            captain has not answered the relay question, so the shipped value is
#            off and no code path needs it on.
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
#   jg-bus.sh parity [--record <file>] [--corrupt]
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
UNDELIVERED=$STATE/captain-channel-undelivered.jsonl
LOG=$STATE/captain-channel.log
CORRUPT=0
die() { printf 'jg-bus: %s\n' "$*" >&2; exit 2; }
say() { printf '%s\n' "$*" >&2; }

# The file a service reads, home override first.
bus_file() {  # <path under core/bus> -> prints the file in force
  if [ -f "$JG_HOME/config/bus/$1" ]; then printf '%s' "$JG_HOME/config/bus/$1"
  else printf '%s' "$ROOT/core/bus/$1"; fi
}

# The channel config files, most specific first.
CHANNEL_FILES=("${JG_CAPTAIN_CHANNEL:-}" "$JG_HOME/config/captain-channel" "$ROOT/defaults/captain-channel")

# One key out of one config file, or nothing.
file_get() {  # <file> <key>
  [ -n "${1-}" ] && [ -f "$1" ] || return 0
  awk -v k="$2" '$1 == "set" && $2 == k { sub(/^[[:space:]]*set[[:space:]]+[^[:space:]]+[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; exit }' "$1"
}

# One key from the channel config, first file that carries it wins.
cfg() {  # <key>
  local key=$1 file v
  for file in "${CHANNEL_FILES[@]}"; do
    v=$(file_get "$file" "$key")
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  done
  return 1
}
is_on() { [ "$(cfg "$1" 2>/dev/null)" = on ]; }

# What this path does: live, shadow or off, decided by `mode` alone.
channel_mode() {
  local file v
  for file in "${CHANNEL_FILES[@]}"; do
    v=$(file_get "$file" mode)
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  done
  printf 'live'
}

# JSON string escaping for the record and the transported event. Multiline text
# becomes \n, so one event stays one line.
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'BEGIN{ORS=""} NR>1{print "\\n"} {print}'; }

note_failure() {  # <what> <detail>
  printf '%s failed: %s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-300)" >>"$LOG" 2>/dev/null || true
}

# One event document. The record, the bus and a replay all build the event here,
# so what went out and what a replay rebuilds cannot drift apart.
event_json() {  # <at> <kind> <key> <text> [<link>]
  printf '{"at":%s,"kind":"%s","key":"%s","subject":"%s","text":"%s"%s}' \
    "$1" "$(esc "$2")" "$(esc "$3")" "$(esc "$(cfg subject-prefix).$2")" "$(esc "$4")" \
    "${5:+,\"link\":\"$(esc "$5")\"}"
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
  if [ -n "$key" ]; then cfg "$key" || die "no '$key' in the channel config"; printf '\n'; return 0; fi
  printf 'channel config in force:\n'
  while read -r tag key _; do
    [ "${tag:-}" = set ] || continue
    printf '  %-18s %s\n' "$key" "$(cfg "$key")"
  done < "$ROOT/defaults/captain-channel"
}

# Tee one captain-facing event. It never fails its emitter, because both callers
# are today's own delivery paths; in live mode a delivery that does not arrive is
# named in $UNDELIVERED so nothing is lost quietly.
cmd_publish() {
  local kind=${1-} key=${2-} text=${3-} link='' json subject title out mode
  [ "$#" -ge 3 ] || die "publish needs <kind> <key> <text>"
  shift 3
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --link) link=${2:-}; shift 2 || die "publish --link needs a url" ;;
      *) die "publish: unknown flag $1" ;;
    esac
  done
  mode=$(channel_mode)
  [ "$mode" = off ] && return 0
  json=$(event_json "$(date +%s)" "$kind" "$key" "$text" "$link")
  subject="$(cfg subject-prefix).$kind"
  mkdir -p "$STATE" 2>/dev/null
  printf '%s\n' "$json" >>"$RECORD" 2>/dev/null || note_failure record "$json"
  if ! out=$(post "$(cfg dapr-http-url)/v1.0/publish/$(cfg dapr-pubsub)/$subject" "$json"); then
    note_failure "bus $subject" "${out:-unreachable}"
  fi
  [ "$mode" = live ] || return 0
  title=$(printf '%s' "$text" | head -n 1 | cut -c1-120)
  if ! out=$(post "$(ntfy_url)" "$text" -H "Title: $title" -H "Tags: $(cfg ntfy-tag)"); then
    note_failure ntfy "${out:-unreachable}"
    printf '{"at":%s,"target":"%s","error":"%s","event":%s}\n' \
      "$(date +%s)" "$(esc "$(ntfy_url)")" "$(esc "$(printf '%s' "${out:-unreachable}" | tr '\n' ' ' | cut -c1-300)")" "$json" \
      >>"$UNDELIVERED" 2>/dev/null || true
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

# parity [--record <file>] [--corrupt]: replay every recorded event through the
# builder the live path sends with and compare it with the event the record
# holds, one row per event. What is sent has to be identical; where it goes is
# the one decision the switch flips, so parity reports the target and the
# delivery count instead of diffing them.
cmd_parity() {
  local rec=$RECORD file at kind key subject encoded link text rebuilt row
  local rows_a=0 events=0 instants=0 decisions=0 deliveries=0 differences=0 corrupt_at='' target=none
  local dir
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --record) rec=${2:-}; shift 2 || die "parity --record needs a file" ;;
      --corrupt) CORRUPT=1; shift ;;
      *) die "parity: unknown argument $1" ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || { say "skip: parity needs jq to read the record"; return 0; }
  [ -s "$rec" ] || {
    printf 'captain channel parity: record=%s events=0 instants=0 decisions=0 deliveries=0 differences=0\n' "$rec"
    return 0
  }
  [ "$(channel_mode)" = live ] && target=$(ntfy_url)
  dir=$(mktemp -d "${TMPDIR:-/tmp}/jg-captain-parity.XXXXXX") || return 1
  # One row per event, the text base64 so a row stays one line: at, kind, key,
  # subject, text, link. A row the record itself cannot parse is not compared.
  jq -Rr 'fromjson? | [(.at|tostring), .kind, .key, .subject, ((.text // "")|@base64), (.link // "-")] | join(" ")' \
    "$rec" > "$dir/recorded" 2>/dev/null || true
  : > "$dir/rebuilt"
  while read -r at kind key subject encoded link; do
    [ -n "${at:-}" ] || continue
    text=$(printf '%s' "$encoded" | base64 -d 2>/dev/null) || continue
    [ -n "$corrupt_at" ] || corrupt_at=$at
    # --corrupt tampers with the first replayed event on the new side only, so a
    # diff that still reported nothing would be a vacuous check.
    if [ "$CORRUPT" -eq 1 ] && [ "$at" = "$corrupt_at" ]; then
      rebuilt=$(event_json "$at" "$kind" "$key" "$text (corrupted on the new path)" "$link")
    else
      rebuilt=$(event_json "$at" "$kind" "$key" "$text" "$link")
    fi
    printf '%s' "$rebuilt" | jq -Rr 'fromjson? | [(.at|tostring), .kind, .key, .subject, ((.text // "")|@base64), (.link // "-")] | join(" ")' \
      >> "$dir/rebuilt" 2>/dev/null || continue
    rows_a=$((rows_a + 1))
  done < "$dir/recorded"
  events=$rows_a
  instants=$(awk '{ print $1 }' "$dir/recorded" | LC_ALL=C sort -u | awk 'END { print NR }')
  decisions=$((events * 2))
  [ "$target" = none ] || deliveries=$events
  if ! diff -u "$dir/recorded" "$dir/rebuilt" > "$dir/diff" 2>&1; then
    differences=$(grep -cE '^[+-][^+-]' "$dir/diff" || true)
    # The rows carry the text base64 so one row stays one line; the difference is
    # printed decoded, so a reader sees the words that changed.
    grep -E '^[+-][^+-]' "$dir/diff" | head -n 20 | while read -r row; do
      sign=${row:0:1}
      read -r at kind key subject encoded link <<< "${row:1}"
      printf '%s %s %s at %s: "%s"\n' "$sign" "$kind" "$key" "$at" \
        "$(printf '%s' "$encoded" | base64 -d 2>/dev/null | tr '\n' '|')"
    done
  fi
  if [ "$CORRUPT" -eq 1 ]; then
    printf 'captain channel parity --corrupt: tampered with the replayed event at %s on the new path: events=%s instants=%s decisions=%s deliveries=%s differences=%s (must be non-zero)\n' \
      "$corrupt_at" "$events" "$instants" "$decisions" "$deliveries" "${differences:-0}"
    rm -rf -- "$dir"
    [ "${differences:-0}" -ne 0 ]
    return
  fi
  printf 'captain channel parity: record=%s events=%s instants=%s decisions=%s deliveries=%s differences=%s\n' \
    "$rec" "$events" "$instants" "$decisions" "$deliveries" "${differences:-0}"
  printf 'captain channel parity: mode %s, so each event goes to %s\n' "$(channel_mode)" "$target"
  rm -rf -- "$dir"
  [ "${differences:-0}" -eq 0 ]
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
  local name pid state events=0 undelivered=0 target=none
  [ -f "$RECORD" ] && events=$(wc -l <"$RECORD" | tr -d ' ')
  [ -f "$UNDELIVERED" ] && undelivered=$(wc -l <"$UNDELIVERED" | tr -d ' ')
  [ "$(channel_mode)" = live ] && target=$(ntfy_url)
  printf 'mode %s, relay %s, delivery %s\n' "$(channel_mode)" "$(cfg ntfy-relay)" "$target"
  printf 'record %s: %s event(s), %s undelivered\n' "$RECORD" "$events" "$undelivered"
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
  parity) shift; cmd_parity "$@" ;;
  reply) shift; cmd_reply "$@" ;;
  serve) shift; cmd_serve "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  bootstrap) shift; mkdir -p "$RUNTIME" && cd "$RUNTIME" && cmd_bootstrap "$@" ;;
  status) cmd_status ;;
  *) die "unknown command: $1" ;;
esac

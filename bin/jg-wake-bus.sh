#!/usr/bin/env bash
# jg-wake-bus.sh - the wake queue and the task inboxes on NATS JetStream: the bus is
# the store, and this script is its one owner.
#
# A producer publishes a raise, a consumer's acknowledgement publishes another event,
# and one renderer folds the stream into the read model every other reader opens
# (state/.wake-queue, state/.wake-settled). docs/bus-live.md owns the contract and the
# one-step reversal; the shadow mirror that proved this path against the old file queue
# is gone.
#
# CONTRACT.
#   config   config/wake-bus may set `nats-url <url>`, or `off` to return the home to
#            the file behaviour; JG_WAKE_BUS_URL overrides the address. No file means
#            the bus is on.
#   streams  JG_WAKE carries jg.<home>.wake.> and JG_INBOX jg.<home>.inbox.> for every
#            home, file storage, kept JG_BUS_MAX_AGE (default 168h). One server serves
#            every home on the machine, so bus_ensure_stream adds this home's subject to
#            a stream an earlier build made for another home; a home reads only its own events
#            (the event's `home`).
#   outbox   an event the server refuses waits in state/.wake-bus.outbox.jsonl and is
#            published by the next render, so a bus that is briefly down loses no wake.
#
# Usage: jg-wake-bus.sh raise <kind> <key> <payload> <class> | settle <kind> <key> <payload>
#        | ack <id>... | ids <kind> <key> | ids-through <max-seq> [<seqs-file>] | count
#        | inbox-raise <task> <seq> <delivery> <body-sha> | inbox-settle | render
#   bin/jg-wake-bus-probe.sh measures the whole path on this machine.
#
# Env: JG_WAKE_BUS_URL, JG_NATS_BIN, JG_BUS_MAX_AGE.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-kv-lib.sh
. "$SCRIPT_DIR/jg-kv-lib.sh"

WAKE_STREAM=JG_WAKE
INBOX_STREAM=JG_INBOX
# One subject prefix per home on the machine's one server: jg.<home>.> owns the
# wakes, the inboxes and the captain channel of exactly one home, and the account
# that carries them can publish nowhere else (core/bus/accounts.conf).
SUBJECT_PREFIX=${JG_BUS_SUBJECT_PREFIX:-}
BUS_MAX_AGE=${JG_BUS_MAX_AGE:-168h}
CMD=
HOMES=()
ACK_IDS=()
INBOX_TASK='' INBOX_SEQ='' INBOX_DELIVERY='' INBOX_SHA=''

# config_get <home> <key>: the value in force, from JG_WAKE_BUS_<KEY>, then the
# home's config/wake-bus, then the default this function's caller names.
config_get() { # <home-dir> <key> <default>
  local var value
  var="JG_WAKE_BUS_$(printf '%s' "$2" | tr 'a-z-' 'A-Z_')"
  value=$(eval "printf '%s' \"\${$var:-}\"")
  if [ -z "$value" ] && [ -f "$1/config/wake-bus" ]; then
    value=$(awk -v k="$2" '$1 == k { sub(/^[^ ]+[ \t]+/, ""); print; exit }' "$1/config/wake-bus" 2>/dev/null)
  fi
  printf '%s\n' "${value:-$3}"
}

bus() { # one client call against the bus; the server address is always explicit
  [ -n "${BUS_NATS:-}" ] || return 1
  jg_kv_run "$BUS_NATS" "$BUS_URL" "$HOME_DIR/state" "$@"
}

# bus_gate: resolve the client and prove the server answers, or say why not. It
# never fails the caller: a home with no bus must behave exactly as before.
bus_gate() {
  if [ -n "${JG_NATS_BIN:-}" ]; then BUS_NATS=$JG_NATS_BIN; else BUS_NATS=$(command -v nats 2>/dev/null || true); fi
  if [ -z "${BUS_NATS:-}" ]; then
    printf 'skip: nats client not found (set JG_NATS_BIN)\n'
    return 1
  fi
  if ! bus stream ls >/dev/null 2>&1; then
    printf 'skip: no bus at %s\n' "$BUS_URL"
    return 1
  fi
}

# bus_ensure_stream <stream> <subject>: the stream exists and carries this home's
# subject. The machine runs ONE JetStream, so one stream serves every home on it:
# a stream made for the first home's prefix alone refuses every other home's
# publish, and those wakes sit in the home's outbox while the file read model
# looks like the queue. A wildcard over the home part is refused where another
# stream (the captain channel's jg.captain.>) overlaps it, so each home adds its
# own subject to the list; the stream keeps its messages.
bus_ensure_stream() { # <stream> <subject> [<max-age>]
  local have
  have=$(bus stream info "$1" --json 2>/dev/null | jq -r '(.config.subjects // []) | join(",")' 2>/dev/null)
  if [ -z "$have" ]; then
    bus stream add "$1" --subjects "$2" --storage file \
      --retention limits --max-age "${3:-$BUS_MAX_AGE}" --dupe-window 24h --defaults >/dev/null 2>&1
  else
    case ",$have," in *",$2,"*) return 0 ;; esac
    bus stream edit "$1" --subjects "$have,$2" --force >/dev/null 2>&1
  fi
}

bus_ensure_streams() {
  bus_ensure_stream "$WAKE_STREAM" "$SUBJECT_PREFIX.wake.>" "${1:-}"
  bus_ensure_stream "$INBOX_STREAM" "$SUBJECT_PREFIX.inbox.>" "${1:-}"
}

# --- helpers -----------------------------------------------------------------
sha256_of() { # stdin
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1; fi
}

# home_key <state-dir>: a stable short name for one home, so one stream keeps two
# homes' identical task names apart.
home_key() { # <state-dir>
  local home
  home=$(dirname "$1")
  printf '%s:%s\n' "$(basename "$home")" "$(printf '%s' "$home" | sha256_of | cut -c1-8)"
}

# --- the live path ------------------------------------------------------------
# The bus is the store for the wake queue. A producer publishes a raise, a
# consumer's acknowledgement publishes another event, and ONE renderer writes the
# read model every other reader still opens: state/.wake-queue, in exactly the
# format it has always had. Nothing appends to that file any more, so the append
# lock, the sequence file, the whole-file rewrite on every acknowledgement, the
# withdraw rewrite, the record-only file and the queue's own append-recovery
# marker all go with the path they served. docs/bus-live.md owns the contract.
LIVE_QUEUE=$STATE/.wake-queue                  # read model: queued rows, oldest first
LIVE_SOLID=$STATE/.wake-settled                # read model: record-only rows, newest last
LIVE_EVENTS=$STATE/.wake-bus.events.jsonl      # this home's unsettled events, with their sequence
LIVE_CURSOR=$STATE/.wake-bus.cursor            # "<stream>\t<sequence>" already applied
LIVE_OUTBOX=$STATE/.wake-bus.outbox.jsonl      # events a failed publish still owes the bus

live_home_key() { home_key "$STATE"; }

# live_enabled: the one-step reversal. config/wake-bus carrying `off` returns the
# home to the file behaviour on the spot - rows wait in this home's own outbox and
# nothing is published - without reverting the change.
live_enabled() {
  [ -f "$HOME_DIR/config/wake-bus" ] || return 0
  ! grep -qw off "$HOME_DIR/config/wake-bus" 2>/dev/null
}

# bus_pub_seq <subject> <message-id> <json>: publish, then print the sequence the
# server stored it at, or 0 when it was not stored. The sequence is the row's
# ordering number, so it comes from the server rather than from a counter a crash
# could rewind.
bus_pub_seq() { # <subject> <message-id> <json>
  local out seq
  out=$(bus pub --jetstream -H "Nats-Msg-Id:$2" "$1" "$3" 2>&1) || return 0
  seq=$(printf '%s' "$out" | sed -n 's/.*Sequence: \([0-9][0-9]*\).*/\1/p' | head -n 1)
  printf '%s\n' "${seq:-0}"
}

live_cursor_get() { # <stream>
  awk -v s="$1" '$1 == s { print $2; found = 1 } END { if (!found) print 0 }' "$LIVE_CURSOR" 2>/dev/null
}

live_cursor_set() { # <stream> <sequence>
  local tmp=$LIVE_CURSOR.tmp.$$ out
  out=$({ awk -v s="$1" '$1 != s' "$LIVE_CURSOR" 2>/dev/null; printf '%s\t%s\n' "$1" "$2"; })
  if printf '%s\n' "$out" > "$tmp" && mv -f "$tmp" "$LIVE_CURSOR"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# live_apply <stream> <file>: append every message since the cursor that belongs
# to this home, each carrying the sequence it was stored at.
live_apply() { # <stream> <file>
  local stream=$1 out=$2 from seq last raw body
  from=$(( $(live_cursor_get "$stream") + 1 ))
  last=$(bus stream info "$stream" --json 2>/dev/null | jq -r '.state.last_seq // 0' 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ "$last" -ge "$from" ] || return 0
  seq=$from
  while [ "$seq" -le "$last" ]; do
    raw=$(bus stream get "$stream" "$seq" --json 2>/dev/null) || { seq=$((seq + 1)); continue; }
    body=$(printf '%s' "$raw" | jq -r '.data // empty' 2>/dev/null | base64 -d 2>/dev/null || true)
    if [ -n "$body" ]; then
      printf '%s' "$body" | jq -c --argjson seq "$seq" --arg home "$(live_home_key)" \
        'select(.home == $home) | . + {seq: (.rseq // $seq)}' >> "$out" 2>/dev/null || true
    fi
    seq=$((seq + 1))
  done
  live_cursor_set "$stream" "$last"
}

# live_flush_outbox: publish what an earlier failed publish still owes, and keep
# only what the server refused again. A home whose bus is briefly down therefore
# loses no wake: the event waits here until the next render.
live_flush_outbox() {
  local line seq keep
  [ -s "$LIVE_OUTBOX" ] || return 0
  keep=$LIVE_OUTBOX.tmp.$$
  : > "$keep" || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # An acknowledgement carries its raise's id, so its message id takes the
    # "/ack" suffix live_ack gives it; under the raise's own id the server would
    # drop it as a duplicate and the row would never settle.
    seq=$(bus_pub_seq "$(printf '%s' "$line" | jq -r '.subject')" \
      "$(printf '%s' "$line" | jq -r '.id + (if .ack == true then "/ack" else "" end)')" \
      "$(printf '%s' "$line" | jq -c 'del(.subject)')")
    [ "${seq:-0}" -gt 0 ] || printf '%s\n' "$line" >> "$keep"
  done < "$LIVE_OUTBOX"
  mv -f "$keep" "$LIVE_OUTBOX" || { rm -f -- "$keep"; return 1; }
}

live_outbox_add() { # <subject> <json>
  mkdir -p "$STATE" 2>/dev/null || return 1
  jq -nc --arg subject "$1" --argjson event "$2" '{subject: $subject} + $event' >> "$LIVE_OUTBOX" 2>/dev/null
}

# live_publish <subject> <id> <json>: publish one event, or owe it in the outbox.
live_publish() { # <subject> <id> <json>
  local seq
  live_enabled || { live_outbox_add "$1" "$3"; return 0; }
  seq=$(bus_pub_seq "$1" "$2" "$3")
  if [ "${seq:-0}" -le 0 ]; then
    # The first raise on a fresh home arrives before the streams exist, and a
    # subject no stream carries is refused; making them and retrying once keeps
    # that first event instead of owing it.
    bus_ensure_streams || true
    seq=$(bus_pub_seq "$1" "$2" "$3")
  fi
  [ "${seq:-0}" -gt 0 ] && return 0
  live_outbox_add "$1" "$3"
}

# live_render: bring the local replica up to date, then write the read models the
# rest of the fleet reads. The replica holds only unsettled events, so a fold
# stays small: an acknowledgement drops its raise with it.
live_render() {
  local model have_bus=0
  mkdir -p "$STATE" || return 1
  if live_enabled && bus_gate >/dev/null 2>&1; then
    have_bus=1
    bus_ensure_streams || true
    live_flush_outbox || true
  fi
  model=$STATE/.wake-bus.fold.$$
  : > "$model" || return 1
  if [ -s "$LIVE_EVENTS" ]; then cat "$LIVE_EVENTS" >> "$model" || return 1; fi
  # An event a failed publish still owes the bus is part of the read model: a home
  # whose bus is down keeps queueing and keeps draining, and the outbox hands the
  # event to the stream on the next render that can reach it.
  if [ -s "$LIVE_OUTBOX" ]; then jq -c 'del(.subject) | .seq = (.rseq // 0)' "$LIVE_OUTBOX" >> "$model" 2>/dev/null || true; fi
  if [ "$have_bus" = 1 ]; then
    live_apply "$WAKE_STREAM" "$model" || true
    live_apply "$INBOX_STREAM" "$model" || true
  fi
  if ! jq -c -s 'reduce .[] as $e ({};
        if ($e.ack // false) then (if has($e.id) then .[$e.id].ack = true else . end)
        else .[$e.id] = $e end)
      | [to_entries[].value] | map(select((.ack // false) != true)) | .[]' "$model" > "$model.keep" 2>/dev/null; then
    rm -f -- "$model" "$model.keep"
    return 1
  fi
  mv -f "$model.keep" "$LIVE_EVENTS" || { rm -f -- "$model" "$model.keep"; return 1; }
  rm -f -- "$model"
  jq -r 'select(.where == "queue") | [.at, (.seq // .rseq), .kind, .key, .payload] | @tsv' "$LIVE_EVENTS" 2>/dev/null \
    | LC_ALL=C sort -t "$(printf '\t')" -k2,2n > "$model.queue" || : > "$model.queue"
  chmod 0600 "$model.queue" 2>/dev/null || true
  _jg_atomic_replace "$model.queue" "$LIVE_QUEUE" || { rm -f -- "$model.queue"; return 1; }
  jq -r 'select(.where == "settled") | [.at, "silent", .kind, .key, .payload] | @tsv' "$LIVE_EVENTS" 2>/dev/null \
    | LC_ALL=C sort -t "$(printf '\t')" -k1,1n > "$model.settled" || : > "$model.settled"
  chmod 0600 "$model.settled" 2>/dev/null || true
  _jg_atomic_replace "$model.settled" "$LIVE_SOLID" || { rm -f -- "$model.settled"; return 1; }
}

live_raise() { # <kind> <key> <payload> <class>
  local id at rseq event
  at=$(date -u +%s)
  id="wake/$(live_home_key)/$at-$$-$RANDOM"
  # The row's number is fixed here, before any publish: a home whose bus is not
  # reachable still writes read-model rows, and the number must not change when
  # the event later reaches the stream.
  rseq=$(( at * 1000 + (RANDOM % 1000) ))
  event=$(jq -nc --arg id "$id" --arg home "$(live_home_key)" --arg kind "$1" --arg key "$2" \
    --arg payload "$3" --arg class "$4" --argjson at "$at" --argjson rseq "$rseq" \
    '{v:1,id:$id,home:$home,where:"queue",at:$at,rseq:$rseq,kind:$kind,key:$key,payload:$payload,class:$class}') || return 1
  live_publish "$SUBJECT_PREFIX".wake.raise "$id" "$event" || return 1
  live_render
  return 0
}

live_settle() { # <kind> <key> <payload>
  local id at event
  at=$(date -u +%s)
  id="settled/$(live_home_key)/$at-$$-$RANDOM"
  event=$(jq -nc --arg id "$id" --arg home "$(live_home_key)" --arg kind "$1" --arg key "$2" \
    --arg payload "$3" --argjson at "$at" --argjson rseq "$(( at * 1000 + (RANDOM % 1000) ))" \
    '{v:1,id:$id,home:$home,where:"settled",at:$at,rseq:$rseq,kind:$kind,key:$key,payload:$payload,class:"silent"}') || return 1
  live_publish "$SUBJECT_PREFIX".wake.settled "$id" "$event" || return 1
  live_render
}

live_ack() { # <id>...
  local id at owed subject
  at=$(date -u +%s)
  for id in "$@"; do
    [ -n "$id" ] || continue
    # An event the bus never received is acknowledged by dropping it here: there
    # is nothing on the server to settle, and keeping it would resurrect the row.
    if [ -s "$LIVE_OUTBOX" ] && jq -e --arg id "$id" 'select(.id == $id)' "$LIVE_OUTBOX" >/dev/null 2>&1; then
      owed=$LIVE_OUTBOX.tmp.$$
      if jq -c --arg id "$id" 'select(.id != $id)' "$LIVE_OUTBOX" > "$owed" 2>/dev/null \
        && mv -f "$owed" "$LIVE_OUTBOX"; then
        continue
      fi
      rm -f -- "$owed"
      return 1
    fi
    # An inbox record is acknowledged on the inbox stream, beside its raise.
    case "$id" in inbox/*) subject="$SUBJECT_PREFIX.inbox.ack" ;; *) subject="$SUBJECT_PREFIX.wake.ack" ;; esac
    live_publish "$subject" "$id/ack" \
      "$(jq -nc --arg id "$id" --arg home "$(live_home_key)" --argjson at "$at" \
        '{v:1,id:$id,home:$home,ack:true,at:$at}')" || return 1
  done
  live_render
}

# live_ids_through <max-seq> [<allowed-seqs-file>]: the queued ids an actor may
# acknowledge, by sequence. With a file, only the sequences it lists - the branch
# actor's grant - are named, so an acknowledgement can never consume a row it was
# not handed.
live_ids_through() { # <max-seq> [<seqs-file>]
  live_events | jq -r --argjson max "$1" \
    'select(.where == "queue" and ((.seq // .rseq) <= $max)) | [(.seq // .rseq), .id] | @tsv' 2>/dev/null \
    | if [ -n "${2:-}" ]; then awk -F '\t' -v f="$2" 'BEGIN { while ((getline l < f) > 0) keep[l + 0] = 1 } ($1 + 0) in keep { print $2 }'
      else awk -F '\t' '{ print $2 }'; fi
}

# live_inbox_raise <task> <sequence> <delivery> <body-sha>: one inbox record on the
# bus, published by the writer that made it durable, so no scan has to find it.
live_inbox_raise() { # <task> <seq> <delivery> <body-sha>
  local id at
  at=$(date -u +%s)
  id="inbox/$(live_home_key)/$1/$2"
  live_publish "$SUBJECT_PREFIX".inbox.raise "$id" \
    "$(jq -nc --arg id "$id" --arg home "$(live_home_key)" --arg task "$1" --argjson seq "$2" \
      --arg delivery "$3" --arg sha "$4" --argjson at "$at" \
      '{v:1,id:$id,home:$home,task:$task,seq:$seq,at:$at,delivery:$delivery,body_sha:$sha}')" || return 1
  live_render
}

# live_inbox_settle: a worker acknowledges a steer by moving its record into
# handled/, so this is the one observer that carries that move to the bus. A
# record still in its inbox is left alone; one that is gone is acknowledged.
# Cheap: it reads the local replica, not the bus.
live_inbox_settle() {
  local task seq
  bus_gate >/dev/null 2>&1 || return 0
  live_events | jq -r 'select((.ack // false) != true and .task != null) | [.task, .seq] | @tsv' 2>/dev/null | while IFS=$'\t' read -r task seq; do
      [ -n "${task:-}" ] || continue
      [ -e "$STATE/$task.inbox/$seq.msg" ] && continue
      printf 'inbox/%s/%s/%s\n' "$(live_home_key)" "$task" "$seq"
    done > "$STATE/.wake-bus.inbox-acks.$$" || return 0
  if [ -s "$STATE/.wake-bus.inbox-acks.$$" ]; then
    # shellcheck disable=SC2046  # one id per line, each one event id
    live_ack $(cat "$STATE/.wake-bus.inbox-acks.$$")
  fi
  rm -f -- "$STATE/.wake-bus.inbox-acks.$$"
}

# live_count: how many rows the read model holds, which is how a consumer knows
# whether anything is still queued after an acknowledgement.
live_count() {
  awk -F '\t' 'END { print NR + 0 }' "$LIVE_QUEUE" 2>/dev/null
}

# live_events: every unsettled event this home knows, the replica plus anything a
# failed publish still owes. A home with no reachable bus therefore queues, drains
# and acknowledges exactly as it did on the file path, and the outbox hands the
# events to the stream when the bus answers again.
live_events() {
  if [ -s "$LIVE_EVENTS" ]; then cat "$LIVE_EVENTS"; fi
  if [ -s "$LIVE_OUTBOX" ]; then jq -c 'del(.subject) | .seq = (.rseq // 0)' "$LIVE_OUTBOX" 2>/dev/null || true; fi
}

# live_ids <kind> <key>: the queued, unsettled ids for exactly this kind and key.
live_ids() {
  live_events | jq -r --arg k "$1" --arg r "$2" \
    'select(.where == "queue" and .kind == $k and .key == $r) | .id' 2>/dev/null | LC_ALL=C sort
}

# --- arguments ---------------------------------------------------------------
h=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      [ -n "${2:-}" ] || { printf 'jg-wake-bus.sh: --home needs a directory\n' >&2; exit 2; }
      h=$(cd "$2/state" 2>/dev/null && pwd) || {
        printf 'jg-wake-bus.sh: no state directory under %s\n' "$2" >&2; exit 2; }
      HOMES+=("$h")
      shift 2
      ;;
    raise)
      [ "$#" -ge 5 ] || { printf 'jg-wake-bus.sh: raise needs <kind> <key> <payload> <class>\n' >&2; exit 2; }
      CMD=raise; RAISE_KIND=$2; RAISE_KEY=$3; RAISE_PAYLOAD=$4; RAISE_CLASS=$5; shift 5 ;;
    settle)
      [ "$#" -ge 4 ] || { printf 'jg-wake-bus.sh: settle needs <kind> <key> <payload>\n' >&2; exit 2; }
      CMD=settle; RAISE_KIND=$2; RAISE_KEY=$3; RAISE_PAYLOAD=$4; shift 4 ;;
    ids)
      [ "$#" -ge 3 ] || { printf 'jg-wake-bus.sh: ids needs <kind> <key>\n' >&2; exit 2; }
      CMD=ids; RAISE_KIND=$2; RAISE_KEY=$3; shift 3 ;;
    ids-through)
      [ "$#" -ge 2 ] || { printf 'jg-wake-bus.sh: ids-through needs <max-sequence> [<seqs-file>]\n' >&2; exit 2; }
      CMD="ids-through"
      RAISE_KIND=$2
      RAISE_KEY=${3:-}
      if [ "$#" -ge 3 ]; then shift 3; else shift 2; fi ;;
    count) CMD=count; shift ;;
    inbox-raise)
      [ "$#" -ge 5 ] || { printf 'jg-wake-bus.sh: inbox-raise needs <task> <seq> <delivery> <body-sha>\n' >&2; exit 2; }
      CMD=inbox-raise; INBOX_TASK=$2; INBOX_SEQ=$3; INBOX_DELIVERY=$4; INBOX_SHA=$5; shift 5 ;;
    inbox-settle) CMD=inbox-settle; shift ;;
    ack)
      CMD=ack; shift
      ACK_IDS=("$@") || true
      set -- ;;
    render) CMD=render; shift ;;
    *) printf 'jg-wake-bus.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$CMD" ] || { printf 'usage: jg-wake-bus.sh [--home DIR] raise|settle|ack|ids|count|inbox-raise|inbox-settle|render (see the header)\n' >&2; exit 2; }
if [ "${#HOMES[@]}" -eq 0 ]; then HOMES=("$STATE"); fi
for h in "${HOMES[@]}"; do
  [ -d "$h" ] || { printf 'jg-wake-bus.sh: no state directory at %s\n' "$h" >&2; exit 2; }
done
HOME_DIR=$(dirname "${HOMES[0]}")
BUS_URL=$(config_get "$HOME_DIR" nats-url "nats://127.0.0.1:4222")
# jg.<home>.>: the one prefix this home may publish or read on the machine server.
if [ -z "$SUBJECT_PREFIX" ]; then
  SUBJECT_PREFIX="jg.$(basename "$HOME_DIR" | tr -c 'A-Za-z0-9_.-' '_')"
fi
[ -n "${JG_WAKE_BUS_URL:-}" ] && BUS_URL=$JG_WAKE_BUS_URL
# Resolved once, before any command runs: the live raise and its render must not
# depend on a gate that prints its own skip lines into a producer's output.
if [ -n "${JG_NATS_BIN:-}" ]; then BUS_NATS=$JG_NATS_BIN; else BUS_NATS=$(command -v nats 2>/dev/null || true); fi

case "$CMD" in
  raise) live_raise "$RAISE_KIND" "$RAISE_KEY" "$RAISE_PAYLOAD" "$RAISE_CLASS" ;;
  settle) live_settle "$RAISE_KIND" "$RAISE_KEY" "$RAISE_PAYLOAD" ;;
  ack) live_ack ${ACK_IDS[@]+"${ACK_IDS[@]}"} ;;
  ids) live_ids "$RAISE_KIND" "$RAISE_KEY" ;;
  ids-through) live_ids_through "$RAISE_KIND" "$RAISE_KEY" ;;
  count) live_count ;;
  inbox-raise) live_inbox_raise "$INBOX_TASK" "$INBOX_SEQ" "$INBOX_DELIVERY" "$INBOX_SHA" ;;
  inbox-settle) live_inbox_settle ;;
  render) live_render ;;
esac

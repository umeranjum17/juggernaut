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
#            every home on the machine, so the Go command (wakebus.go) adds this home's subject to
#            a stream an earlier build made for another home; a home reads only its own events
#            (the event's `home`).
#   outbox   an event the server refuses waits in state/.wake-bus.outbox.jsonl and is
#            published by the next render, so a bus that is briefly down loses no wake.
#
# Usage: jg-wake-bus.sh raise <kind> <key> <payload> <class> | settle <kind> <key> <payload>
#        | ack <id>... | ids <kind> <key> | ids-through <max-seq> [<seqs-file>] | count
#        | inbox-raise <task> <seq> <delivery> <body-sha> | inbox-handled <task> <seq> <outcome> <evidence>
#        | inbox-settle | render
#        | endpoint
#   bin/jg-wake-bus-probe.sh measures the whole path on this machine.
#   endpoint prints "<server url> <wake stream> <raise subject> <account user> <password file>",
#   tab separated: where the wake engine service (core/bus/cmd/jg-bus/engine.go) consumes from.
#
# Env: JG_WAKE_BUS_URL, JG_NATS_BIN, JG_BUS_MAX_AGE.
# Login: when the machine's accounts file holds this home's account (the server holds one
# account per home), the script connects as that account, `bin/jg-bus.sh login`, and publishes on
# jg.<account>. A server that runs no accounts, and a home that has not joined one, answers
# nothing and takes the folder-name prefix with no login.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-kv-lib.sh
. "$SCRIPT_DIR/jg-kv-lib.sh"

WAKE_STREAM=JG_WAKE
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
    printf 'skip: the event system at %s does not answer\n' "$BUS_URL"
    return 1
  fi
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
LIVE_EVENTS=$STATE/.wake-bus.events.jsonl      # this home's unsettled events, with their sequence
LIVE_OUTBOX=$STATE/.wake-bus.outbox.jsonl      # events a failed publish still owes the bus

live_home_key() { home_key "$STATE"; }

# live_enabled: the one-step reversal. config/wake-bus carrying `off` returns the
# home to the file behaviour on the spot - rows wait in this home's own outbox and
# nothing is published - without reverting the change.
live_enabled() {
  [ -f "$HOME_DIR/config/wake-bus" ] || return 0
  ! grep -qw off "$HOME_DIR/config/wake-bus" 2>/dev/null
}

# wake_go: the Go command builds, delivers and renders the wake engine's events
# (core/bus/cmd/jg-bus/wakebus.go, wakerender.go, wake.go). It is handed what this script
# resolved: the home, its key, the bus address, the client, the subject prefix and the
# stream age. NATS_USER and NATS_PASSWORD, exported below when the machine runs accounts,
# reach it through the environment.
wake_go() {
  JG_HOME=$HOME_DIR JG_STATE_OVERRIDE=${HOMES[0]} JG_WAKE_HOME_KEY=$(live_home_key) JG_WAKE_BUS_URL=$BUS_URL \
    JG_NATS_BIN=${BUS_NATS:-} JG_BUS_SUBJECT_PREFIX=$SUBJECT_PREFIX JG_BUS_MAX_AGE=$BUS_MAX_AGE \
    "$SCRIPT_DIR/jg-bus.sh" wake "$@"
}

# live_render: make the streams, publish what the outbox owes, apply the streams from the
# cursor and write the read models the rest of the fleet reads. The cursor moves only
# after the replica holding what was read is durable.
live_render() { wake_go render "$STATE"; }

# A raise and a record-only wake are built and delivered by the Go command, which owes an
# event it cannot publish; the read model follows.
live_raise() { wake_go raise "$STATE" "$@" || return 1; live_render; return 0; } # <kind> <key> <payload> <class>
live_settle() { wake_go settle "$STATE" "$@" || return 1; live_render; } # <kind> <key> <payload>

# live_publish <subject> <id> <json>: publish one event, or owe it in the outbox.
live_publish() { wake_go deliver "$STATE" "$@"; }

# live_ack <id>...: acknowledge each row, then prove it left the replica. Every
# acknowledgement is its own bus message (a message id unique to this attempt): the
# server drops a second message under an id it has already stored as a duplicate,
# and a row whose first acknowledgement the cursor had already passed without
# settling it could then never be acknowledged again, yet every retry exited 0.
# An acknowledgement that leaves its row in the replica says so and exits 1.
live_ack() { # <id>...
  local id at owed subject mid left=''
  at=$(date -u +%s)
  for id in "$@"; do
    [ -n "$id" ] || continue
    # An event the bus never received is acknowledged by dropping it here: there
    # is nothing on the server to settle, and keeping it would resurrect the row.
    if [ -s "$LIVE_OUTBOX" ] && jq -e --arg id "$id" 'select(.id == $id)' "$LIVE_OUTBOX" >/dev/null 2>&1; then
      owed=$LIVE_OUTBOX.tmp.$$
      if jq -c --arg id "$id" 'select(.id != $id)' "$LIVE_OUTBOX" > "$owed" 2>/dev/null \
        && mv -f "$owed" "$LIVE_OUTBOX"; then
        # The replica copied the owed row at the last render; drop that copy too, or
        # the render below puts the row back.
        if [ -s "$LIVE_EVENTS" ] && jq -c --arg id "$id" 'select(.id != $id)' "$LIVE_EVENTS" > "$owed" 2>/dev/null; then
          mv -f "$owed" "$LIVE_EVENTS" || rm -f -- "$owed"
        fi
        continue
      fi
      rm -f -- "$owed"
      return 1
    fi
    # An inbox record is acknowledged on the inbox stream, beside its raise.
    case "$id" in inbox/*) subject="$SUBJECT_PREFIX.inbox.ack" ;; *) subject="$SUBJECT_PREFIX.wake.ack" ;; esac
    mid="$id/ack/$at-$$-$RANDOM"
    live_publish "$subject" "$mid" \
      "$(jq -nc --arg id "$id" --arg mid "$mid" --arg home "$(live_home_key)" --argjson at "$at" \
        '{v:1,id:$id,mid:$mid,home:$home,ack:true,at:$at}')" || return 1
  done
  live_render || return 1
  for id in "$@"; do
    [ -n "$id" ] || continue
    if live_events | jq -e --arg id "$id" 'select(.id == $id and (.ack // false) != true)' >/dev/null 2>&1; then
      left="$left $id"
    fi
  done
  if [ -n "$left" ]; then
    printf 'jg-wake-bus.sh: acknowledged but still queued (the acknowledgement did not settle the row):%s\n' "$left" >&2
    return 1
  fi
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

# live_inbox_handled <task> <seq> <outcome> <evidence>: the worker's claim that it handled (or
# refused) one steer, with the pointer to what shows it. A new event of its own on the inbox
# stream - never the transport's ack, which only ever means "read" - so a sender or the delivery
# record can consume it. It folds into nothing: where=handled is no queue row.
live_inbox_handled() { # <task> <seq> <outcome> <evidence>
  local id
  id="inbox/$(live_home_key)/$1/$2/handled"
  live_publish "$SUBJECT_PREFIX".inbox.handled "$id" \
    "$(jq -nc --arg id "$id" --arg home "$(live_home_key)" --arg task "$1" --argjson seq "$2" \
      --arg outcome "$3" --arg evidence "$4" --argjson at "$(date -u +%s)" \
      '{v:1,id:$id,home:$home,where:"handled",task:$task,seq:$seq,at:$at,outcome:$outcome,evidence:$evidence}')"
}

# live_inbox_settle: a worker acknowledges a steer by moving its record into
# handled/, so this is the one observer that carries that move to the bus. A
# record still in its inbox is left alone; one that is in handled/ is acknowledged; one that is in neither is not.
# Cheap: it reads the local replica, not the bus. The record's number is the last part
# of its own id, and its file is that number padded the way bin/jg-task-inbox-lib.sh
# names it, so a replica an older render wrote with the stream's sequence still settles.
live_inbox_settle() {
  local id task seq
  bus_gate >/dev/null 2>&1 || return 0
  live_events | jq -r 'select((.ack // false) != true and .task != null) | [.id, .task, (.id | split("/") | last)] | @tsv' 2>/dev/null | while IFS=$'\t' read -r id task seq; do
      [ -n "${task:-}" ] || continue
      case "$seq" in ''|*[!0-9]*) continue ;; esac
      # Acknowledged only when the worker moved the record into handled/. A record
      # that is in neither place was lost, not handled, so it stays unacknowledged.
      [ -e "$STATE/$task.inbox/handled/$(printf '%03d' "$((10#$seq))").msg" ] || continue
      printf '%s\n' "$id"
    done > "$STATE/.wake-bus.inbox-acks.$$" || return 0
  local rc=0
  if [ -s "$STATE/.wake-bus.inbox-acks.$$" ]; then
    # shellcheck disable=SC2046  # one id per line, each one event id
    live_ack $(cat "$STATE/.wake-bus.inbox-acks.$$") || rc=$?
  fi
  rm -f -- "$STATE/.wake-bus.inbox-acks.$$"
  return "$rc"
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
  if [ -s "$LIVE_OUTBOX" ]; then jq -c 'del(.subject) | .seq = (.rseq // .seq // 0)' "$LIVE_OUTBOX" 2>/dev/null || true; fi
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
    inbox-handled)
      [ "$#" -ge 5 ] || { printf 'jg-wake-bus.sh: inbox-handled needs <task> <seq> <outcome> <evidence>\n' >&2; exit 2; }
      CMD=inbox-handled; INBOX_TASK=$2; INBOX_SEQ=$3; INBOX_DELIVERY=$4; INBOX_SHA=$5; shift 5 ;;
    inbox-settle) CMD=inbox-settle; shift ;;
    ack)
      CMD=ack; shift
      ACK_IDS=("$@") || true
      set -- ;;
    render) CMD=render; shift ;;
    endpoint) CMD=endpoint; shift ;;
    *) printf 'jg-wake-bus.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$CMD" ] || { printf 'usage: jg-wake-bus.sh [--home DIR] raise|settle|ack|ids|count|inbox-raise|inbox-settle|render (see the header)\n' >&2; exit 2; }
if [ "${#HOMES[@]}" -eq 0 ]; then HOMES=("$STATE"); fi
for h in "${HOMES[@]}"; do
  [ -d "$h" ] || { printf 'jg-wake-bus.sh: no state directory at %s\n' "$h" >&2; exit 2; }
done
HOME_DIR=$(dirname "${HOMES[0]}")
# The server address defaults to the one the stack runs the bus on (the captain channel's nats-url,
# a home's config/captain-channel over defaults/captain-channel), so a home that moved its server
# does not have the wake bus and the engine reading a different one.
channel_url=''
for channel_file in "$HOME_DIR/config/captain-channel" "$SCRIPT_DIR/../defaults/captain-channel"; do
  [ -f "$channel_file" ] || continue
  channel_url=$(awk '$1 == "set" && $2 == "nats-url" { print $3; exit }' "$channel_file" 2>/dev/null)
  [ -z "$channel_url" ] || break
done
BUS_URL=$(config_get "$HOME_DIR" nats-url "${channel_url:-nats://127.0.0.1:4222}")
# When the machine runs accounts, its accounts file holds this home's account: `jg-bus.sh login`
# answers the name and the credentials file it was written from, whatever registry named the home
# (the owner's, which its accounts file is generated from), and this client publishes on that
# account's prefix. A bare server (a test, a detached stack) answers nothing and takes the
# folder-name prefix and no login.
ACCOUNT_PASS_FILE=''
if acct=$(JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="${HOMES[0]}" "$SCRIPT_DIR/jg-bus.sh" login 2>/dev/null); then
  NATS_USER=${acct%%$'\t'*}
  ACCOUNT_PASS_FILE=${acct#*$'\t'}
  NATS_PASSWORD=$(cat "$ACCOUNT_PASS_FILE" 2>/dev/null) || NATS_PASSWORD=''
  export NATS_USER NATS_PASSWORD
  [ -n "$SUBJECT_PREFIX" ] || SUBJECT_PREFIX=jg.$NATS_USER
fi
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
  inbox-handled) live_inbox_handled "$INBOX_TASK" "$INBOX_SEQ" "$INBOX_DELIVERY" "$INBOX_SHA" ;;
  inbox-settle) live_inbox_settle ;;
  render) live_render ;;
  endpoint) printf '%s\t%s\t%s\t%s\t%s\n' "$BUS_URL" "$WAKE_STREAM" "$SUBJECT_PREFIX.wake.raise" "${NATS_USER:-}" "${ACCOUNT_PASS_FILE:-}" ;;
esac

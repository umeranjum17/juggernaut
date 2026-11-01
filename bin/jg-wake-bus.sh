#!/usr/bin/env bash
# jg-wake-bus.sh - the wake queue and the task inboxes on NATS JetStream, in
# shadow: both paths run at once and the files stay authoritative.
#
# WHY THIS EXISTS (migration step 5b). The wake queue and the per-task steering
# inboxes are files with locks, drains, doorbells and re-ring ladders - the
# largest pile of shell left in the core. The decided shape is a durable bus:
# JetStream keeps the events, its message-id dedupe replaces the re-enqueue
# dedupe, its sequence replaces the sequence file plus the queue lock, and
# history replaces the fact that a consumed wake leaves no trace at all. This
# step only proves the bus reproduces the file path's consumer result; nothing
# switches and the file path stays authoritative.
#
# docs/bus-shadow.md owns the event model, the parity contract, the measured line
# count of each path and what the switch would remove. This script is the one
# owner of the shadow's mechanics: the file scan, the publish with its message-id
# dedupe, the shadow record that keeps a sync cheap and restartable, and the fold
# that turns the stream back into the rows a consumer sees.
#
# CONTRACT (this header is the one owner of the bus' shape here).
#   config   a home enables the mirror with config/wake-bus; the same file may
#            set `nats-url <url>`, and JG_WAKE_BUS_URL overrides both. No file
#            means the mirror is off and every command but view and parity says
#            so and exits 0, so a home without a bus behaves exactly as before.
#   streams  JG_WAKE carries jg.wake.>, JG_INBOX carries jg.inbox.>, both file
#            storage with the retention JG_BUS_MAX_AGE sets (default 168h: the
#            24h replay window needs history). The stream names are fixed here
#            so a replay reads the same two streams a mirror wrote.
#   record   $STATE/wake-bus.jsonl, one event document per line, appended once it
#            is published. The file path is the durable record of the event, so
#            the record never has to be: it is the mirror's cache of what went out,
#            which makes a sync idempotent, restartable and cheap. A publish that
#            fails leaves no line, so the next sync publishes it again, and
#            Nats-Msg-Id makes any repeat a no-op on the server.
#   rows     both paths produce the same canonical rows, one per consumer-visible
#            record, and parity compares them sorted:
#              wake  <id> queue   <kind> <key> <payload> <class>
#              wake  <id> settled <kind> <key> <payload> silent
#              inbox <id> pending <delivery> <body-sha256>
#              inbox <id> handled <delivery> <body-sha256>
#            A wake row the file path consumed has no file-side row at all: the
#            drain deletes it, so the file path keeps no acknowledgement record
#            and only the bus can count wake acknowledgements.
#   write    nothing here writes to the file path. No queue row, settled row,
#            inbox record or handled move is created, changed or removed, and a
#            missing client or server prints `skip: ...` and exits 0.
#
# Usage:
#   jg-wake-bus.sh sync                            mirror this home's events
#   jg-wake-bus.sh view [--since-hours N]          print the bus consumer rows as TSV
#   jg-wake-bus.sh parity [--since-hours N] [--corrupt]
#                                                  replay both paths and compare them
#
# Options: --home DIR (repeatable) resolves a home and its state directory and
# never writes to it; --record-dir DIR keeps the shadow record outside the home;
# --corrupt republishes one existing event with tampered fields, which parity
# must then report as a difference, so a green parity run is never vacuous.
#
# Env: JG_WAKE_BUS_URL, JG_NATS_BIN, JG_BUS_MAX_AGE.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-task-inbox-lib.sh
. "$SCRIPT_DIR/jg-task-inbox-lib.sh"
# shellcheck source=bin/jg-kv-lib.sh
. "$SCRIPT_DIR/jg-kv-lib.sh"

WAKE_STREAM=JG_WAKE
INBOX_STREAM=JG_INBOX
# One subject prefix per home on the machine's one server: jg.<home>.> owns the
# wakes, the inboxes and the captain channel of exactly one home, and the account
# that carries them can publish nowhere else (core/bus/accounts.conf).
SUBJECT_PREFIX=${JG_BUS_SUBJECT_PREFIX:-}
WAKE_SUBJECT=''
INBOX_SUBJECT=''
BUS_MAX_AGE=${JG_BUS_MAX_AGE:-168h}
RECORD_DIR=${JG_WAKE_BUS_RECORD_DIR:-}
SINCE_HOURS=24
CORRUPT=0
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

bus_ensure_streams() {
  local max_age
  max_age=${1:-$BUS_MAX_AGE}
  bus stream info "$WAKE_STREAM" >/dev/null 2>&1 \
    || bus stream add "$WAKE_STREAM" --subjects "$WAKE_SUBJECT" --storage file \
      --retention limits --max-age "$max_age" --dupe-window 24h --defaults >/dev/null 2>&1
  bus stream info "$INBOX_STREAM" >/dev/null 2>&1 \
    || bus stream add "$INBOX_STREAM" --subjects "$INBOX_SUBJECT" --storage file \
      --retention limits --max-age "$max_age" --dupe-window 24h --defaults >/dev/null 2>&1
}

bus_publish() { # <subject> <message-id> <json>
  bus pub --jetstream -q -H "Nats-Msg-Id:$2" "$1" "$3" >/dev/null 2>&1
}

# --- shared row vocabulary ---------------------------------------------------
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

inbox_delivery() { # <record-path>
  local d
  d=$(sed -n 's/^delivery=//p' "$1" 2>/dev/null | head -n 1)
  printf '%s\n' "${d:-normal}"
}

inbox_body_sha() { # <record-path>
  jg_task_inbox_body "$1" 2>/dev/null | sha256_of
}

record_epoch() { # <inbox-record>: the record's own write time in epoch seconds
  local at
  at=$(sed -n 's/^at=//p' "$1" 2>/dev/null | head -n 1)
  case "$at" in
    '') printf '0\n' ;;
    *) date -u -d "$at" +%s 2>/dev/null || printf '0\n' ;;
  esac
}

# file_rows <state-dir>: what the file path holds now, one canonical row per
# consumer-visible record, each followed by the record's own timestamp so the
# caller applies a window (the mirror keeps it, parity compares without it).
file_rows() { # <state-dir>
  local st=$1 rec task seq n=0 at kind wkey payload key
  key=$(home_key "$st")
  {
    if [ -s "$st/.wake-queue" ]; then
      while IFS=$'\t' read -r at seq kind wkey payload; do
        [ -n "${kind:-}" ] || continue
        case "$seq" in ''|*[!0-9]*) continue ;; esac
        printf 'wake\twake/%s/%s\tqueue\t%s\t%s\t%s\t%s\t%s\n' \
          "$key" "$seq" "$kind" "$wkey" "$payload" \
          "$(jg_wake_route_class "$kind" "$wkey" "$payload")" "$at"
      done < "$st/.wake-queue"
    fi
    if [ -s "$st/.wake-settled" ]; then
      while IFS=$'\t' read -r at _class kind wkey payload; do
        [ -n "${kind:-}" ] || continue
        n=$((n + 1))
        printf 'wake\tsettled/%s/%s\tsettled\t%s\t%s\t%s\tsilent\t%s\n' \
          "$key" "$n" "$kind" "$wkey" "$payload" "$at"
      done < "$st/.wake-settled"
    fi
    for rec in "$st"/*.inbox/*.msg "$st"/*.inbox/handled/*.msg; do
      [ -f "$rec" ] || continue
      seq=${rec##*/}
      seq=${seq%.msg}
      case "$seq" in ''|*[!0-9]*) continue ;; esac
      task=${rec%/*}
      task=${task%/handled}
      task=${task##*/}
      task=${task%.inbox}
      case "$rec" in */handled/*) at=handled ;; *) at=pending ;; esac
      printf 'inbox\tinbox/%s/%s/%s\t%s\t%s\t%s\t%s\n' \
        "$key" "$task" "$seq" "$at" "$(inbox_delivery "$rec")" \
        "$(inbox_body_sha "$rec")" "$(record_epoch "$rec")"
    done
  } | LC_ALL=C sort
}

# --- the bus path ------------------------------------------------------------
# bus_dump <out-file> <since-epoch> <homes>: every message either stream holds for
# one of these homes inside the window, one event document per line. The home
# filter keeps a fleet-wide stream from reporting another home's rows as a
# difference when only some homes are being compared.
bus_dump() { # <out-file> <since-epoch> <home-keys>
  local out=$1 since=$2 keys=$3 s n last body
  : > "$out"
  for s in "$WAKE_STREAM" "$INBOX_STREAM"; do
    last=$(bus stream info "$s" --json 2>/dev/null | jq -r '.state.last_seq // 0' 2>/dev/null)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    n=1
    while [ "$n" -le "$last" ]; do
      body=$(bus stream get "$s" "$n" --json 2>/dev/null | jq -r '.data // empty' 2>/dev/null | base64 -d 2>/dev/null || true)
      if [ -n "$body" ]; then
        printf '%s' "$body" | jq -c --argjson since "$since" --argjson keys "$keys" \
          '. as $e | select((.at // 0) >= $since) | select($keys | index($e.home) != null)' \
          >> "$out" 2>/dev/null || true
      fi
      n=$((n + 1))
    done
  done
}

# home_keys: the home keys of the homes this run compares, as a JSON array, so
# the fold keeps exactly these homes and never another home's rows.
home_keys() {
  local st
  for st in "${HOMES[@]}"; do home_key "$st"; done \
    | jq -R -s -c 'split("\n") | map(select(length > 0))'
}

# bus_fold <dump-file>: one event per id - the last raise wins, so a corrected or
# replayed event never counts twice, and an acknowledgement settles it.
bus_fold() { # <dump-file>
  jq -c -s '
    (reduce .[] as $e ({};
       if $e.ack then (if .[$e.id] then .[$e.id].ack = true else . end)
       else .[$e.id] = $e end))
    | [to_entries[] | .value] | sort_by((.at // 0), .id) | .[]' "$1" 2>/dev/null
}

# bus_rows <dump-file>: the same canonical rows the file path produces.
bus_rows() { # <dump-file>
  bus_fold "$1" | jq -r '
    if .where == "settled" then
      ["wake", .id, "settled", .kind, .key, .payload, "silent"] | @tsv
    elif .task then ["inbox", .id, (if .ack then "handled" else "pending" end), .delivery, .body_sha] | @tsv
    elif .ack then empty
    else ["wake", .id, "queue", .kind, .key, .payload, .class] | @tsv
    end' 2>/dev/null | LC_ALL=C sort
}

# --- the mirror --------------------------------------------------------------
# record_file <state-dir>: the shadow record's path. It lives in the home's state
# directory by default, which is the record of that home's own bus traffic.
record_file() { # <state-dir>
  if [ -n "$RECORD_DIR" ]; then
    mkdir -p "$RECORD_DIR" || return 1
    printf '%s/%s.jsonl\n' "$RECORD_DIR" "$(home_key "$1" | tr ':' '_')"
  else
    mkdir -p "$1" || return 1
    printf '%s/wake-bus.jsonl\n' "$1"
  fi
}

# record_state <record> <id>: live, acked, or nothing when never published.
record_state() { # <record> <id>: live, acked, or nothing when never published
  [ -f "$1" ] || return 0
  awk -F '\t' -v id="$2" '
    $2 == id { last = $1 }
    END { if (last == "live" || last == "acked") print last }' "$1" 2>/dev/null
}

record_append() { # <record> <state> <id> <json>
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" >> "$1" 2>/dev/null
}

# record_epoch_of <record> <id>: the event time the record holds for one id, so
# an acknowledgement carries the same time as the raise it settles.
record_epoch_of() { # <record> <id>
  awk -F '\t' -v id="$2" '$2 == id && $1 == "live" { print $3; exit }' "$1" 2>/dev/null \
    | jq -r '.at // 0' 2>/dev/null
}

# row_event <state-dir> <row>: the event document one canonical row stands for.
row_event() { # <state-dir> <row-tsv>
  local st=$1 row=$2 kind id state task seq rec body
  local -a f
  local IFS=$'\t'
  read -r -a f <<< "$row"
  kind=${f[0]} id=${f[1]} state=${f[2]}
  case "$kind:$state" in
    wake:queue)
      jq -nc --arg id "$id" --arg home "$(home_key "$st")" --arg kind "${f[3]}" --arg key "${f[4]}" \
        --arg payload "${f[5]}" --arg class "${f[6]}" --argjson seq "${id##*/}" --argjson at "${f[7]}" \
        '{v:1,id:$id,home:$home,where:"queue",seq:$seq,at:$at,kind:$kind,key:$key,payload:$payload,class:$class}'
      ;;
    wake:settled)
      jq -nc --arg id "$id" --arg home "$(home_key "$st")" --arg kind "${f[3]}" --arg key "${f[4]}" \
        --arg payload "${f[5]}" --argjson at "${f[7]}" \
        '{v:1,id:$id,home:$home,where:"settled",at:$at,kind:$kind,key:$key,payload:$payload,class:"silent"}'
      ;;
    inbox:*)
      seq=${id##*/}
      task=${id%/*}
      task=${task##*/}
      rec="$st/$task.inbox/$seq.msg"
      [ -f "$rec" ] || rec="$st/$task.inbox/handled/$seq.msg"
      body=$(jg_task_inbox_body "$rec" 2>/dev/null || true)
      jq -nc --arg id "$id" --arg home "$(home_key "$st")" --arg task "$task" \
        --arg delivery "${f[3]}" --arg body "$body" --arg body_sha "${f[4]}" \
        --argjson seq "$seq" --argjson at "${f[5]}" \
        '{v:1,id:$id,home:$home,task:$task,seq:$seq,at:$at,delivery:$delivery,body:$body,body_sha:$body_sha}'
      ;;
    *) return 2 ;;
  esac
}

# ack_event <state-dir> <id> <at>: the acknowledgement document for one id. The
# row it answers is already gone from the file path, so only its id and time are
# available here.
ack_event() { # <state-dir> <id> <at>
  local st=$1 id=$2 at=$3
  case "$at" in ''|*[!0-9]*) at=0 ;; esac
  jq -nc --arg id "$id" --arg home "$(home_key "$st")" --argjson at "$at" \
    '{v:1,id:$id,home:$home,ack:true,at:$at}'
}

# publish_event <record> <state> <id> <subject> <json>: publish, then record it.
# A publish that fails records nothing, so the next sync publishes the event
# again; the file path still holds the event either way, and the server's
# message-id dedupe makes a repeat publish a no-op.
publish_event() { # <record> <state> <id> <subject> <json>
  local record=$1 state=$2 id=$3 subject=$4 json=$5
  bus_publish "$subject" "$id$([ "$state" = acked ] && printf /ack)" "$json" || return 0
  record_append "$record" "$state" "$id" "$json"
}

# mirror_home <state-dir> <bus-max-age>: publish the raises the file path gained
# and the acknowledgements it lost. It never touches the file path.
mirror_home() { # <state-dir> <max-age>
  local st=$1 max_age=$2 record rows published=0 acked=0 id row state
  local live_file handled_file
  [ -d "$st" ] || { printf 'mirror: no state directory at %s\n' "$st" >&2; return 1; }
  record=$(record_file "$st") || return 1
  rows=$(mktemp "${TMPDIR:-/tmp}/jg-wake-bus-rows.XXXXXX") || return 1
  bus_ensure_streams "$max_age"
  file_rows "$st" > "$rows"
  live_file=$(awk -F '\t' '$3 != "handled" { print $2 }' "$rows")
  handled_file=$(awk -F '\t' '$3 == "handled" { print $2 }' "$rows")

  # 1. a live row the record has never carried is a new raise.
  local subject
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    state=$(record_state "$record" "$id")
    [ -z "$state" ] || continue
    row=$(awk -F '\t' -v id="$id" '$2 == id' "$rows")
    [ -n "$row" ] || continue
    case "$id" in wake/*) subject="$SUBJECT_PREFIX.wake.raise" ;; *) subject="$SUBJECT_PREFIX.inbox.raise" ;; esac
    publish_event "$record" live "$id" "$subject" "$(row_event "$st" "$row")" || return 1
    published=$((published + 1))
  done <<EOF
$live_file
EOF

  # 2. a row the record carries live but the file path no longer holds is
  #    acknowledged: the drain consumed it, a worker moved it into handled/, or
  #    the producer withdrew it. All three are "no longer queued" to any consumer.
  local gone
  gone=$(record_live "$record" | grep -vxF -f <(printf '%s\n' "$live_file") 2>/dev/null || true)
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$id" in wake/*) subject="$SUBJECT_PREFIX.wake.ack" ;; *) subject="$SUBJECT_PREFIX.inbox.ack" ;; esac
    publish_event "$record" acked "$id" "$subject" \
      "$(ack_event "$st" "$id" "$(record_epoch_of "$record" "$id")")" || return 1
    acked=$((acked + 1))
  done <<EOF
$gone
EOF

  # 3. an inbox record handled before the mirror saw it is raised and acknowledged
  #    together, so the bus holds the same handled row the file path holds.
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    state=$(record_state "$record" "$id")
    [ -z "$state" ] || continue
    row=$(awk -F '\t' -v id="$id" '$2 == id' "$rows")
    [ -n "$row" ] || continue
    publish_event "$record" live "$id" "$SUBJECT_PREFIX.inbox.raise" "$(row_event "$st" "$row")" || return 1
    publish_event "$record" acked "$id" "$SUBJECT_PREFIX.inbox.ack" \
      "$(ack_event "$st" "$id" "$(record_epoch_of "$record" "$id")")" || return 1
    acked=$((acked + 1))
  done <<EOF
$handled_file
EOF
  rm -f -- "$rows"
  printf 'bus shadow mirror: published=%s acknowledged=%s home=%s\n' \
    "$published" "$acked" "$(dirname "$st")"
}

# record_live <record>: the ids the record says are on the bus and unsettled.
record_live() { # <record>
  [ -f "$1" ] || return 0
  awk -F '\t' '{ seen[$2] = $1 } END { for (id in seen) if (seen[id] == "live") print id }' "$1" 2>/dev/null \
    | LC_ALL=C sort
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
    seq=$(bus_pub_seq "$(printf '%s' "$line" | jq -r '.subject')" \
      "$(printf '%s' "$line" | jq -r '.id')" "$(printf '%s' "$line" | jq -c 'del(.subject)')")
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
  local id at owed
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
      live_publish "$SUBJECT_PREFIX".wake.ack "$id/ack" \
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

# --- subcommands -------------------------------------------------------------
cmd_sync() {
  local st home max_age
  home=$(dirname "$1")
  max_age=$(config_get "$home" max-age "$BUS_MAX_AGE")
  bus_gate || return 0
  for st in "$@"; do
    home=$(dirname "$st")
    mirror_home "$st" "$(config_get "$home" max-age "$BUS_MAX_AGE")" || return 1
  done
}

cmd_view() {
  local tmp
  bus_gate || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/jg-wake-bus-dump.XXXXXX") || return 1
  bus_dump "$tmp" "$SINCE" "$(home_keys)" || true
  bus_rows "$tmp"
  rm -f -- "$tmp"
}

# cmd_parity: replay the window through both paths and compare the consumer
# result row by row. The file path is live, so a row can arrive or be consumed
# while the comparison runs; only records that both scans of the file path agree
# on are compared, and the ones that moved are counted as churned instead of
# being reported as a difference they are not. --corrupt tampers with one event
# first, so a run that still reported no difference would be a vacuous check.
cmd_parity() {
  local st tmp diffs=0 compared=0 churned=0
  bus_gate || return 0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/jg-wake-bus-parity.XXXXXX") || return 1
  scan_window "$tmp/before"
  cmd_sync "${HOMES[@]}" || true
  scan_window "$tmp/after"
  comm -12 "$tmp/before" "$tmp/after" > "$tmp/file"
  comm -3 "$tmp/before" "$tmp/after" | sed 's/^\t//' | cut -f2 | LC_ALL=C sort -u > "$tmp/churn"
  churned=$(awk 'END { print NR }' "$tmp/churn")
  [ "$CORRUPT" -eq 1 ] && { corrupt_one_event || true; }
  bus_dump "$tmp/dump" "$SINCE" "$(home_keys)" || true
  # A record that moved while the run was reading the file path is dropped from
  # both sides, so a live row that arrived or was consumed mid-run can never be
  # reported as a difference.
  bus_rows "$tmp/dump" > "$tmp/bus.all"
  if [ -s "$tmp/churn" ]; then
    awk -F '\t' 'NR == FNR { skip[$1] = 1; next } !($2 in skip)' "$tmp/churn" "$tmp/bus.all" > "$tmp/bus"
  else
    mv "$tmp/bus.all" "$tmp/bus"
  fi
  compared=$(awk 'END { print NR }' "$tmp/file")
  if ! diff -u "$tmp/file" "$tmp/bus" > "$tmp/diff" 2>&1; then
    diffs=$(grep -cE '^[+-][^+-]' "$tmp/diff" || true)
    grep -E '^[+-][^+-]' "$tmp/diff" | head -n 20
  fi
  printf 'bus shadow parity: homes=%s events_compared=%s differences=%s churned=%s bus_acknowledgements=%s\n' \
    "${#HOMES[@]}" "$compared" "${diffs:-0}" "$churned" "$(record_ack_count)"
  rm -rf -- "$tmp"
  [ "${diffs:-0}" -eq 0 ]
}

# scan_window <out-file>: the file path's consumer rows inside the window, sorted.
# The bus rows carry no timestamp: it is what the window filtered on, not part of
# the consumer result, so the file side drops it after filtering.
scan_window() { # <out-file>
  local st out=$1
  : > "$out"
  for st in "${HOMES[@]}"; do
    file_rows "$st" \
      | awk -F '\t' -v since="$SINCE" '$NF + 0 >= since { sub(/\t[^\t]*$/, ""); print }' \
      >> "$out"
  done
  LC_ALL=C sort -o "$out" "$out"
}

# record_ack_count: acknowledgements the bus path published. The file path
# deletes a consumed wake row and keeps no record of the consumption, so this
# count has no file-side counterpart.
record_ack_count() {
  local st record total=0
  for st in "${HOMES[@]}"; do
    record=$(record_file "$st" 2>/dev/null) || continue
    [ -f "$record" ] || continue
    total=$((total + $(awk -F '\t' -v since="$SINCE" '
      $1 == "acked" && match($0, /"at":[0-9]+/) {
        at = substr($0, RSTART + 5, RLENGTH - 5)
        if (at + 0 >= since) n++
      } END { print n + 0 }' "$record")))
  done
  printf '%s\n' "$total"
}

# corrupt_one_event: republish one existing raise with tampered fields, on the
# same subject and under a different message id so the store keeps it. The fold's
# last-raise-wins then presents the tampered row, which is exactly the difference
# parity must catch.
corrupt_one_event() {
  local s n last raw subject body id
  for s in "$WAKE_STREAM" "$INBOX_STREAM"; do
    last=$(bus stream info "$s" --json 2>/dev/null | jq -r '.state.last_seq // 0' 2>/dev/null)
    case "$last" in ''|*[!0-9]*) continue ;; esac
    n=1
    while [ "$n" -le "$last" ]; do
      raw=$(bus stream get "$s" "$n" --json 2>/dev/null)
      n=$((n + 1))
      subject=$(printf '%s' "$raw" | jq -r '.subject // empty' 2>/dev/null)
      body=$(printf '%s' "$raw" | jq -r '.data // empty' 2>/dev/null | base64 -d 2>/dev/null || true)
      [ -n "$subject" ] && [ -n "$body" ] || continue
      # An acknowledgement carries no row of its own, so tampering with one could
      # not change the consumer result the check compares.
      id=$(printf '%s' "$body" | jq -r 'select(.ack != true) | .id // empty' 2>/dev/null)
      [ -n "$id" ] || continue
      bus_publish "$subject" "$id/corrupt" \
        "$(printf '%s' "$body" | jq -c '.payload = "corrupted by the parity test" | .key = "corrupted" | .body = "corrupted" | .body_sha = "corrupted"')" \
        && return 0
    done
  done
  return 1
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
    --record-dir)
      [ -n "${2:-}" ] || { printf 'jg-wake-bus.sh: --record-dir needs a directory\n' >&2; exit 2; }
      RECORD_DIR=$2
      shift 2
      ;;
    --since-hours)
      [ -n "${2:-}" ] || { printf 'jg-wake-bus.sh: --since-hours needs a count\n' >&2; exit 2; }
      SINCE_HOURS=$2
      shift 2
      ;;
    --corrupt) CORRUPT=1; shift ;;
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
    sync|view|parity) CMD=$1; shift ;;
    *) printf 'jg-wake-bus.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
case "$SINCE_HOURS" in ''|*[!0-9]*) printf 'jg-wake-bus.sh: --since-hours must be a count\n' >&2; exit 2 ;; esac
SINCE=$(( $(date +%s) - SINCE_HOURS * 3600 ))
[ -n "$CMD" ] || { printf 'usage: jg-wake-bus.sh [--home DIR] sync|view|parity (see the header)\n' >&2; exit 2; }
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
WAKE_SUBJECT="$SUBJECT_PREFIX.wake.>"
INBOX_SUBJECT="$SUBJECT_PREFIX.inbox.>"
[ -n "${JG_WAKE_BUS_URL:-}" ] && BUS_URL=$JG_WAKE_BUS_URL
# Resolved once, before any command runs: the live raise and its render must not
# depend on a gate that prints its own skip lines into a producer's output.
if [ -n "${JG_NATS_BIN:-}" ]; then BUS_NATS=$JG_NATS_BIN; else BUS_NATS=$(command -v nats 2>/dev/null || true); fi

# The mirror is opt-in: a home turns it on with config/wake-bus, or with
# JG_WAKE_BUS_SHADOW=on for a run that must not write into that home.
if [ "$CMD" = sync ] && [ ! -f "$HOME_DIR/config/wake-bus" ] \
  && [ "$(config_get "$HOME_DIR" shadow off)" != on ]; then
  printf 'skip: wake bus shadow not enabled (config/wake-bus)\n'
  exit 0
fi

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
  sync) cmd_sync "${HOMES[@]}" ;;
  view) cmd_view ;;
  parity) cmd_parity ;;
esac

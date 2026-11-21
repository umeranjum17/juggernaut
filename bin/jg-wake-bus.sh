#!/usr/bin/env bash
# jg-wake-bus.sh - the wake queue and the task inboxes in the home's own files: this script is
# their one owner.
#
# A producer queues a raise, a consumer's acknowledgement queues another event, and one
# renderer folds the events into the read model every other reader opens
# (state/.wake-queue, state/.wake-settled). docs/bus-live.md owns the contract.
#
# CONTRACT.
#   queue    The queue is the home's own files: an event waits in state/.wake-bus.outbox.jsonl,
#            and the next render folds it into the replica state/.wake-bus.events.jsonl and
#            the read models. A raise owns the rule at the producer's boundary: when the wake
#            engine refuses the raise, or cannot run at all, the raise owes the row in the
#            outbox with the engine's own cause kept on stderr and still answers success,
#            because a producer's duty never depends on the engine answering and a wake must
#            never be dropped.
#
# Usage: jg-wake-bus.sh raise <kind> <key> <payload> <class> | settle <kind> <key> <payload>
#        | ack <id>... | ids <kind> <key> | ids-through <max-seq> [<seqs-file>] | count
#        | inbox-raise <task> <seq> <delivery> <body-sha> | inbox-handled <task> <seq> <outcome> <evidence>
#        | inbox-settle | render
#        | raise-stdin <kind> <key> <class> | settle-stdin <kind> <key>
#          Payload comes verbatim from stdin, avoiding the OS argument-size limit.
#
# Env: JG_BUS_SUBJECT_PREFIX.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"

# The subject prefix names this home on every event it queues: jg.<home>.
SUBJECT_PREFIX=${JG_BUS_SUBJECT_PREFIX:-}
CMD=
HOMES=()
ACK_IDS=()
INBOX_TASK='' INBOX_SEQ='' INBOX_DELIVERY='' INBOX_SHA=''

# --- helpers -----------------------------------------------------------------
sha256_of() { # stdin
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1; fi
}

# home_key <state-dir>: a stable short name for one home, so two homes' identical task names
# stay apart.
home_key() { # <state-dir>
  local home
  home=$(dirname "$1")
  printf '%s:%s\n' "$(basename "$home")" "$(printf '%s' "$home" | sha256_of | cut -c1-8)"
}

# The home's own files are the store for the wake queue. A producer queues a raise, a consumer's
# acknowledgement queues another event, and ONE renderer writes the read model every other reader
# opens: state/.wake-queue. docs/bus-live.md owns the contract.
LIVE_QUEUE=$STATE/.wake-queue                  # read model: queued rows, oldest first
LIVE_EVENTS=$STATE/.wake-bus.events.jsonl      # this home's unsettled events, with their sequence
LIVE_OUTBOX=$STATE/.wake-bus.outbox.jsonl      # events queued and not yet folded into the replica

live_home_key() { home_key "$STATE"; }

# wake_go: the Go command builds, queues and renders the wake engine's events
# (core/bus/cmd/jg-bus/wakebus.go, wakerender.go, wake.go). It is handed what this script
# resolved: the home, its key and the subject prefix.
wake_go() {
  JG_HOME=$HOME_DIR JG_STATE_OVERRIDE=${HOMES[0]} JG_WAKE_HOME_KEY=$(live_home_key) \
    JG_BUS_SUBJECT_PREFIX=$SUBJECT_PREFIX \
    "$SCRIPT_DIR/jg-bus.sh" wake "$@"
}

# live_render: fold the replica and the queued events and write the read models the rest of
# the fleet reads.
live_render() { wake_go render "$STATE"; }

# A raise and a record-only wake are built and queued by the Go command; the read model follows.
live_raise() { printf '%s' "$3" | live_raise_stdin "$1" "$2" "$4"; } # <kind> <key> <payload> <class>
live_settle() { printf '%s' "$3" | live_settle_stdin "$1" "$2"; }
# owe_raise_stdin <kind> <key> <class>: queue one raise in the outbox from the raise
# path alone. The engine fixes a row's number and identity; when the engine refused, or
# could not run, the row takes the legacy number the allocator was built to start beyond
# (this second in milliseconds plus a random suffix), which the engine's own
# nextWakeSequence already accounts for, so it stays ordered and unique beside every row
# the engine writes. The engine's refusal keeps its own cause on stderr; this only makes
# sure the wake survives it.
owe_raise_stdin() { # <kind> <key> <class>; the payload arrives on stdin
  local kind=$1 key=$2 class=$3 payload at rseq id row
  payload=$(cat)
  at=$(date -u +%s)
  rseq=$(( at * 1000 + RANDOM % 1000 ))
  id="wake/$(live_home_key)/$at-$$-$RANDOM"
  row=$(jq -nc --arg subject "$SUBJECT_PREFIX.wake.raise" --arg id "$id" \
    --arg home "$(live_home_key)" --arg kind "$kind" --arg key "$key" --arg payload "$payload" \
    --arg class "$class" --arg word "${JG_WAKE_WORD:-}" --argjson at "$at" --argjson rseq "$rseq" \
    '{subject:$subject,v:1,id:$id,home:$home,where:"queue",at:$at,rseq:$rseq,kind:$kind,key:$key,payload:$payload,class:$class}
     + (if $word == "" then {} else {word:$word} end)') || return 1
  mkdir -p "$STATE" 2>/dev/null || return 1
  printf '%s\n' "$row" >> "$LIVE_OUTBOX"
}

# A raise succeeds when its event is durable. That rule holds at the producer's boundary, so
# this owns it: whether the engine could not make the event durable, could not run, or refused
# the raise by its own rules, the row is owed here with the engine's cause on stderr. A caller
# therefore never sees a raise that both failed and lost the event; only a row that cannot even
# be written here fails.
live_raise_stdin() { # <kind> <key> <class>; the payload arrives on stdin
  local rc payload
  payload=$(cat)
  printf '%s' "$payload" | wake_go raise-stdin "$STATE" "$@"
  rc=$?
  if [ "$rc" -eq 0 ]; then live_render; return 0; fi
  printf '%s' "$payload" | owe_raise_stdin "$@" || return 1
  printf 'jg-wake-bus.sh: the raise was not queued by the wake engine (status %s); owed it in %s\n' \
    "$rc" "$LIVE_OUTBOX" >&2
  live_render >/dev/null 2>&1 || true
  return 0
}
live_settle_stdin() { wake_go settle-stdin "$STATE" "$@" || return 1; live_render; }

# live_publish <subject> <id> <json>: queue one event in the outbox.
live_publish() { wake_go deliver "$STATE" "$@"; }

# live_ack <id>...: acknowledge each row, then prove it left the replica. Every
# acknowledgement is its own event (a message id unique to this attempt). An
# acknowledgement that leaves its row in the replica says so and exits 1.
live_ack() { # <id>...
  local id at owed subject mid left=''
  at=$(date -u +%s)
  for id in "$@"; do
    [ -n "$id" ] || continue
    # An event still in the outbox is acknowledged by dropping it here, or keeping it would
    # resurrect the row.
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
    # An inbox record is acknowledged beside its raise.
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

# live_inbox_raise <task> <sequence> <delivery> <body-sha>: one inbox record, queued by the
# writer that made it durable, so no scan has to find it.
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
# refused) one steer, with the pointer to what shows it. A new event of its own - never
# an ack, which only ever means "read" - so a sender or the delivery record can consume it. It folds into nothing: where=handled is no queue row.
live_inbox_handled() { # <task> <seq> <outcome> <evidence>
  local id
  id="inbox/$(live_home_key)/$1/$2/handled"
  live_publish "$SUBJECT_PREFIX".inbox.handled "$id" \
    "$(jq -nc --arg id "$id" --arg home "$(live_home_key)" --arg task "$1" --argjson seq "$2" \
      --arg outcome "$3" --arg evidence "$4" --argjson at "$(date -u +%s)" \
      '{v:1,id:$id,home:$home,where:"handled",task:$task,seq:$seq,at:$at,outcome:$outcome,evidence:$evidence}')"
}

# live_inbox_settle: a worker acknowledges a steer by moving its record into
# handled/, so this is the one observer that carries that move to the queue. A
# record still in its inbox is left alone; one that is in handled/ is acknowledged; one that is in neither is not.
# Cheap: it reads the local replica. The record's number is the last part
# of its own id, and its file is that number padded the way bin/jg-task-inbox-lib.sh
# names it, so a replica an older render wrote with a stream sequence still settles.
live_inbox_settle() {
  local id task seq
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
# queued event still owes.
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
    raise-stdin)
      [ "$#" -ge 4 ] || { printf 'jg-wake-bus.sh: raise-stdin needs <kind> <key> <class>\n' >&2; exit 2; }
      CMD=raise-stdin; RAISE_KIND=$2; RAISE_KEY=$3; RAISE_CLASS=$4; shift 4 ;;
    settle-stdin)
      [ "$#" -ge 3 ] || { printf 'jg-wake-bus.sh: settle-stdin needs <kind> <key>\n' >&2; exit 2; }
      CMD=settle-stdin; RAISE_KIND=$2; RAISE_KEY=$3; shift 3 ;;
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
    *) printf 'jg-wake-bus.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$CMD" ] || { printf 'usage: jg-wake-bus.sh [--home DIR] raise|settle|ack|ids|count|inbox-raise|inbox-settle|render (see the header)\n' >&2; exit 2; }
if [ "${#HOMES[@]}" -eq 0 ]; then HOMES=("$STATE"); fi
for h in "${HOMES[@]}"; do
  [ -d "$h" ] || { printf 'jg-wake-bus.sh: no state directory at %s\n' "$h" >&2; exit 2; }
done
HOME_DIR=$(dirname "${HOMES[0]}")
# jg.<home>: the prefix this home names its events with.
if [ -z "$SUBJECT_PREFIX" ]; then
  SUBJECT_PREFIX="jg.$(basename "$HOME_DIR" | tr -c 'A-Za-z0-9_.-' '_')"
fi
case "$CMD" in
  raise) live_raise "$RAISE_KIND" "$RAISE_KEY" "$RAISE_PAYLOAD" "$RAISE_CLASS" ;;
  settle) live_settle "$RAISE_KIND" "$RAISE_KEY" "$RAISE_PAYLOAD" ;;
  raise-stdin) live_raise_stdin "$RAISE_KIND" "$RAISE_KEY" "$RAISE_CLASS" ;;
  settle-stdin) live_settle_stdin "$RAISE_KIND" "$RAISE_KEY" ;;
  ack) live_ack ${ACK_IDS[@]+"${ACK_IDS[@]}"} ;;
  ids) live_ids "$RAISE_KIND" "$RAISE_KEY" ;;
  ids-through) live_ids_through "$RAISE_KIND" "$RAISE_KEY" ;;
  count) live_count ;;
  inbox-raise) live_inbox_raise "$INBOX_TASK" "$INBOX_SEQ" "$INBOX_DELIVERY" "$INBOX_SHA" ;;
  inbox-handled) live_inbox_handled "$INBOX_TASK" "$INBOX_SEQ" "$INBOX_DELIVERY" "$INBOX_SHA" ;;
  inbox-settle) live_inbox_settle ;;
  render) live_render ;;
esac

#!/usr/bin/env bash
# jg-reply-bus.sh - the pending-reply event stream on the home's JetStream bus:
# the publish a producer makes, the fold that reads it back, and the projection
# it writes.
#
# WHY THIS EXISTS (migration step 5d, the transport half). A pending reply was a
# record file whose facts lived nowhere else: a create, a delivery attempt and
# its confirmation, a turn's completion, a reply, a reset, a discard. Those
# facts are events of one waiter now, published to the home's JetStream bus, and
# the record file is their projection. Nothing keeps a second event log beside
# the stream: the producers publish (bin/jg-pending-reply-lib.sh calls
# `publish`), the fold reads the stream, and `project` rebuilds every record from
# the stream alone.
#
# core/bus/workflows/pending-reply.json is the workflow definition: the instance
# key, the events, the two stages with the anchor each timer measures from, the
# activity each timeout runs and its retries, and the terminal states. That file,
# not this script, decides the grace default, the subjects and the retention.
#
# docs/reply-shadow.md owns the event model, the projection contract, and what
# the switch leaves to the next slice.
#
# CONTRACT (this header is the one owner of the transport's shape here).
#   config   the server is `nats-url` in the home's config/reply-bus, then
#            config/state-bus, then JG_REPLY_BUS_URL, then JG_KV_URL, then
#            nats://127.0.0.1:4222; the client is JG_NATS_BIN, then `nats`. The
#            workflow file may be overridden per home at
#            config/bus/workflows/pending-reply.json.
#   stream   JG_REPLY over jg.reply.>, file storage, retention from the
#            definition. It is created on first use, so no separate step runs.
#   events   one event per fact of one waiter, all on jg.reply.>:
#              waiter   the instance exists, and carries its record text
#              timer    the timeout one stage is bound to: stage, anchor, grace
#              fire     that timeout fired, at the epoch the record shows
#              answer   the reply that settled the waiter: epoch and how it came
#              discard  that waiter is gone: its record was dropped
#            The message id is the fact's key plus a digest of its body, so a
#            repeat publish is a server no-op and a changed fact supersedes the
#            earlier one. The fold keeps the last event per key, in stream order,
#            and an id whose last event is a discard stops counting.
#   publish  one record's facts, read from the record file itself: what a producer
#            calls once it has written the record. No bus behind it is a skip and
#            never a failure, so a home without one still records.
#   project  the fold, written back as the record files: the same keys in the same
#            order the writers use, and the delivery marker the readers expect.
#            This is what makes the stream the authority: destroy the records and
#            rebuild them from the bus.
#   log      the stream in the engine's log format, `<key>\t<seq>\t<json>`, so
#            bin/jg-reply-engine.sh folds, decides and replays the bus itself.
#   rows     the record files and the stream produce the same canonical rows, one
#            per consumer-visible fact, and parity compares them sorted:
#              reply <id> waiter <task> <grace>
#              reply <id> timer  <stage> <deadline|none>
#              reply <id> fire   <stage> <epoch>
#              reply <id> answer <epoch> <via>
#            The deadline is derived on each side from the anchor and the grace,
#            so a mixed-up anchor, grace or unit shows up as a difference.
#   write    publish writes to the bus and project writes the records; nothing
#            here sends a repost, opens an escalation, or writes a status line.
#            A missing client or server prints `skip: ...` and exits 0.
#
# Usage:
#   jg-reply-bus.sh publish <record> [--at EPOCH]   publish one record's facts
#   jg-reply-bus.sh publish <record> --discard      publish that it is gone
#   jg-reply-bus.sh sync [--home DIR]               backfill every record's facts
#   jg-reply-bus.sh project [--home DIR]            rebuild the records from the bus
#   jg-reply-bus.sh log [--since-hours N]           print the stream as the engine's log
#   jg-reply-bus.sh view [--since-hours N]          print the workflow rows as TSV
#   jg-reply-bus.sh parity [--since-hours N] [--corrupt]
#                                                   compare the records with the bus
#
# Options: --home DIR (repeatable) resolves a home and its state directory;
# --at EPOCH pins the time a publish carries; --corrupt republishes one event
# with a tampered field, which parity must then report as a difference, so a
# green run is never vacuous.
#
# Env: JG_REPLY_BUS_URL, JG_NATS_BIN, JG_PENDING_REPLY_GRACE_SECS.
set -u
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

SINCE_HOURS=168
CORRUPT=0
CMD=
HOMES=()
POS=
AT=
DISCARD=0

config_get() { # <home-dir> <key> <default>
  local var value file
  var="JG_REPLY_BUS_$(printf '%s' "$2" | tr 'a-z-' 'A-Z_')"
  value=$(eval "printf '%s' \"\${$var:-}\"")
  for file in config/reply-bus config/state-bus; do
    [ -z "$value" ] && [ -f "$1/$file" ] || continue
    value=$(awk -v k="$2" '$1 == k { sub(/^[^ ]+[ \t]+/, ""); print; exit }' "$1/$file" 2>/dev/null)
  done
  printf '%s\n' "${value:-$3}"
}

workflow_file() { # <home-dir>
  if [ -f "$1/config/bus/workflows/pending-reply.json" ]; then
    printf '%s' "$1/config/bus/workflows/pending-reply.json"
  else
    printf '%s' "$ROOT/core/bus/workflows/pending-reply.json"
  fi
}

# wf <jq-path> <default>: one value out of the workflow definition, which is the
# one owner of the stages, the subjects and the grace default.
wf() { # <jq-filter> <default>
  local value
  value=$(jq -r "$1 // empty" "$WORKFLOW" 2>/dev/null)
  printf '%s\n' "${value:-$2}"
}

sha256_of() { # stdin
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1; fi
}

# home_key <state-dir>: a stable short name for one home, so one stream keeps two
# homes' waiters apart.
home_key() { # <state-dir>
  local home
  home=$(dirname "$1")
  printf '%s:%s\n' "$(basename "$home")" "$(printf '%s' "$home" | sha256_of | cut -c1-8)"
}

home_keys() { # the home keys of this run, as a JSON array
  local st
  for st in "${HOMES[@]}"; do home_key "$st"; done \
    | jq -R -s -c 'split("\n") | map(select(length > 0))'
}

# --- the record's facts -------------------------------------------------------
# record_facts <state-dir> <since-epoch> [<record-file>...]: one line per fact the
# record path holds for a waiter, read in a single pass over those record files
# (the whole directory when none is named). The names in the right-hand columns
# are the workflow definition's, so the facts and the stages cannot drift apart
# silently.
record_facts() { # <state-dir> <since-epoch> [<record-file>...]
  local st=$1 since=$2 dir
  shift 2
  if [ "$#" -eq 0 ]; then
    dir="$st/pending-replies"
    [ -d "$dir" ] || return 0
    set -- "$dir"/[0-9a-f]*
    [ -e "$1" ] || return 0
  fi
  awk -v key="$(home_key "$st")" -v stages="$STAGES" -v gdef="$GRACE_DEFAULT" \
    -v since="$since" '
    function reset() {
      corr = ""; task = ""; phase = ""; created = ""; reqc = ""; recova = ""
      recovc = ""; resolved = ""; via = ""; escalated = ""; grace = ""
      delivered = ""; attempted = ""; recov_out = ""; turn_seen = ""; recov_seen = ""
      file = ""
    }
    function val(name) {
      if (name == "request_turn_completed_epoch") return reqc
      if (name == "recovery_attempted_epoch") return recova
      if (name == "recovery_turn_completed_epoch") return recovc
      if (name == "escalated_epoch") return escalated
      return ""
    }
    # seen(name): whether the turn of that stage was observed busy before it completed.
    function seen(name) {
      if (name == "request_turn_completed_epoch") return (turn_seen == "1" ? 1 : 0)
      if (name == "recovery_turn_completed_epoch") return (recov_seen == "1" ? 1 : 0)
      return 0
    }
    # outcome(name): what the activity of that stage returned, in the own
    # vocabulary of the definition, so the engine never has to guess between a
    # fire and its result.
    function outcome(name) {
      if (name == "request_turn_completed_epoch") {
        if (recov_out != "") return recov_out
        if (recova != "") return "sending"
        return "-"
      }
      if (name == "recovery_turn_completed_epoch") {
        if (escalated == "") return "-"
        # The recorded phase has moved on to escalated or resolved by the time a
        # record is read, so the escalation kind is read from the outcome that
        # opened it, not from the phase it left behind.
        if (recov_out == "failed" || recov_out == "unknown") return "recovery-delivery"
        if (delivered == "") return "delivery-unknown"
        return "missed"
      }
      return "-"
    }
    # dvstate(): the delivery state of the waiter as one word.
    function dvstate() {
      if (delivered != "") return "confirmed"
      if (phase == "delivery_unknown") return "unknown"
      if (attempted != "") return "attempted"
      return "sent"
    }
    function emit(  n, i, f, anc, fire, g, st, marker, line, rc) {
      if (corr == "" || created == "") return
      if (created + 0 < since) return
      g = grace
      if (g !~ /^[0-9]+$/) g = gdef
      # The delivery sidecar is the one fact the record file does not carry: it
      # says a delivery was attempted, which is what ages into an unknown one.
      attempted = ""
      if (file != "" && delivered == "") {
        marker = file
        sub(/\/[^\/]*$/, "", marker)
        marker = marker "/.delivery-confirmed-" corr
        while ((rc = (getline line < marker)) > 0) {
          if (line ~ /^attempted=/) attempted = substr(line, 11)
        }
        close(marker)
      }
      printf "waiter\t%s/%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
        key, corr, task, g, created, dvstate(), (delivered == "" ? "-" : delivered), \
        (attempted == "" ? "-" : attempted)
      n = split(stages, S, " ")
      for (i = 1; i <= n; i++) {
        split(S[i], f, "|")
        anc = val(f[2])
        if (anc !~ /^[0-9]+$/) anc = "-"
        printf "timer\t%s/%s\t%s\t%s\t%s\t%s\t%s\n", key, corr, f[1], anc, g, created, seen(f[2])
        fire = val(f[3])
        if (fire ~ /^[0-9]+$/) {
          printf "fire\t%s/%s\t%s\t%s\t%s\t%s\n", key, corr, f[1], fire, created, outcome(f[2])
        }
      }
      if (phase == "resolved" && resolved ~ /^[0-9]+$/) {
        st = via
        if (st == "") st = "status"
        printf "answer\t%s/%s\t%s\t%s\t%s\n", key, corr, resolved, st, created
      }
    }
    FNR == 1 { if (NR > 1) emit(); reset() }
    /^corr_id=/ { corr = substr($0, 9) }
    /^task_id=/ { task = substr($0, 9) }
    /^phase=/ { phase = substr($0, 7) }
    /^created_epoch=/ { created = substr($0, 15) }
    /^request_turn_completed_epoch=/ { reqc = substr($0, 30) }
    /^recovery_attempted_epoch=/ { recova = substr($0, 26) }
    /^recovery_turn_completed_epoch=/ { recovc = substr($0, 31) }
    /^resolved_epoch=/ { resolved = substr($0, 16) }
    /^resolved_via=/ { via = substr($0, 14) }
    /^escalated_epoch=/ { escalated = substr($0, 17) }
    /^grace_secs=/ { grace = substr($0, 12) }
    /^delivered_epoch=/ { delivered = substr($0, 17) }
    /^recovery_delivery_outcome=/ { recov_out = substr($0, 27) }
    /^turn_seen_busy=/ { turn_seen = substr($0, 16) }
    /^recovery_turn_seen_busy=/ { recov_seen = substr($0, 25) }
    /^corr_id=/ { file = FILENAME }
    END { if (NR > 0) emit() }
  ' "$@" 2>/dev/null || true
}

# facts_rows <state-dir> <since-epoch>: the record path's decision rows.
facts_rows() { # <state-dir> <since-epoch>
  record_facts "$1" "$2" | awk -F'\t' '
    $1 == "waiter" { printf "reply\t%s\twaiter\t%s\t%s\n", $2, $3, $4 }
    $1 == "timer" {
      dl = "none"
      if ($4 ~ /^[0-9]+$/) dl = $4 + $5
      printf "reply\t%s\ttimer\t%s\t%s\n", $2, $3, dl
    }
    $1 == "fire" { printf "reply\t%s\tfire\t%s\t%s\n", $2, $3, $4 }
    $1 == "answer" { printf "reply\t%s\tanswer\t%s\t%s\n", $2, $3, $4 }
  ' | LC_ALL=C sort
}

# --- the workflow path -------------------------------------------------------
bus() { # one client call against the bus; the server address is always explicit
  "$BUS_NATS" -s "$BUS_URL" --timeout 10s "$@"
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

bus_ensure_stream() {
  bus stream info "$REPLY_STREAM" >/dev/null 2>&1 && return 0
  bus stream add "$REPLY_STREAM" --subjects "$REPLY_SUBJECT" --storage file \
    --retention limits --max-age "$MAX_AGE" --dupe-window 24h --defaults >/dev/null 2>&1
}

bus_publish() { # <subject> <message-id> <json>
  bus pub --jetstream -q -H "Nats-Msg-Id:$2" "$1" "$3" >/dev/null 2>&1
}

# subject_of <fact-key>: the subject a fact travels on, from the definition.
subject_of() { # <key>
  case "$1" in
    waiter/*) printf '%s' "$SUBJECT_WAITER" ;;
    timer/*) printf '%s' "$SUBJECT_TIMER" ;;
    fire/*) printf '%s' "$SUBJECT_FIRE" ;;
    answer/*) printf '%s' "$SUBJECT_ANSWER" ;;
  esac
}

# facts_events <state-dir> <since-epoch> [<record-file>...]: the event document
# and its key for every fact, as "key<TAB>json". Built in awk so a backfill of
# thousands of waiters costs one process, not one per fact.
facts_events() { # <state-dir> <since-epoch> [<record-file>...]
  local st=$1 since=$2
  shift 2
  record_facts "$st" "$since" "$@" | awk -F'\t' -v home="$(home_key "$st")" '
    function jsnum(v) { return (v ~ /^[0-9]+$/) ? v : "null" }
    $1 == "waiter" {
      printf "waiter/%s\t{\"v\":1,\"kind\":\"waiter\",\"id\":\"%s\",\"home\":\"%s\",\"task\":\"%s\",\"grace\":%s,\"at\":%s,\"state\":\"%s\",\"delivered\":%s,\"attempted\":%s}\n",
        $2, $2, home, $3, $4, $5, $6, jsnum($7), jsnum($8)
    }
    $1 == "timer" {
      anchor = "null"
      if ($4 ~ /^[0-9]+$/) anchor = $4
      printf "timer/%s/%s\t{\"v\":1,\"kind\":\"timer\",\"id\":\"%s\",\"home\":\"%s\",\"stage\":\"%s\",\"anchor\":%s,\"grace\":%s,\"at\":%s,\"seen\":%s}\n",
        $2, $3, $2, home, $3, anchor, $5, $6, ($7 == "1" ? "true" : "false")
    }
    $1 == "fire" {
      extra = ""
      if ($3 == "request") extra = sprintf(",\"outcome\":\"%s\"", $6)
      else extra = sprintf(",\"reason\":\"%s\"", $6)
      printf "fire/%s/%s\t{\"v\":1,\"kind\":\"fire\",\"id\":\"%s\",\"home\":\"%s\",\"stage\":\"%s\",\"epoch\":%s,\"at\":%s%s}\n",
        $2, $3, $2, home, $3, $4, $5, extra
    }
    $1 == "answer" {
      printf "answer/%s\t{\"v\":1,\"kind\":\"answer\",\"id\":\"%s\",\"home\":\"%s\",\"epoch\":%s,\"via\":\"%s\",\"at\":%s}\n",
        $2, $2, home, $3, $4, $5
    }
  '
}

# publish_record <state-dir> <record-file>: publish every fact that record holds,
# with the record's own text on its waiter event so the projection is exact. The
# message id makes a repeated publish a no-op on the server, so a writer never has
# to know what the bus already holds.
publish_record() { # <state-dir> <record-file>
  local st=$1 rec=$2 key json subject sha
  [ -f "$rec" ] || return 0
  facts_events "$st" 0 "$rec" | while IFS=$'\t' read -r key json; do
    [ -n "${key:-}" ] && [ -n "${json:-}" ] || continue
    case "$key" in
      waiter/*) json=$(printf '%s' "$json" | jq -c --rawfile record "$rec" '. + {record: $record}' 2>/dev/null) || continue ;;
    esac
    subject=$(subject_of "$key")
    [ -n "$subject" ] || continue
    sha=$(printf '%s' "$json" | sha256_of)
    bus_publish "$subject" "$key/$sha" "$json" || true
  done
}

# publish_discard <state-dir> <corr-id> <epoch>: the waiter is gone. The id is on
# the event so the fold stops counting it, and the projection drops the file.
publish_discard() { # <state-dir> <corr-id> <epoch>
  local st=$1 corr=$2 at=$3 home json
  home=$(home_key "$st")
  json=$(jq -nc --arg id "$home/$corr" --arg home "$home" --argjson at "$at" \
    '{v:1,kind:"discard",id:$id,home:$home,at:$at}') || return 1
  bus_publish "$SUBJECT_DISCARD" "discard/$corr/$at" "$json"
}

# bus_dump <out-file> <since-epoch> <home-keys>: every message the stream holds
# for one of these homes inside the window, in stream order. The order is what
# makes the fold's last-write-wins exact.
bus_dump() { # <out-file> <since-epoch> <home-keys-json>
  local out=$1 since=$2 keys=$3 last n raw body
  : > "$out"
  last=$(bus stream info "$REPLY_STREAM" --json 2>/dev/null | jq -r '.state.last_seq // 0' 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  n=1
  while [ "$n" -le "$last" ]; do
    raw=$(bus stream get "$REPLY_STREAM" "$n" --json 2>/dev/null)
    body=$(printf '%s' "$raw" | jq -r '.data // empty' 2>/dev/null | base64 -d 2>/dev/null || true)
    if [ -n "$body" ]; then
      printf '%s' "$body" | jq -c --argjson since "$since" --argjson keys "$keys" --argjson seq "$n" \
        '. as $e | select(($e.at // 0) >= $since) | select($keys | index($e.home) != null) | . + {seq: $seq}' \
        >> "$out" 2>/dev/null || true
    fi
    n=$((n + 1))
  done
}

# bus_rows <dump-file>: the fold as the rows a consumer sees. An answer or a fire
# only counts for a waiter the stream holds, and the deadline is derived here from
# the anchor and the grace the timer event carries.
bus_rows() { # <dump-file>
  jq -r -s '
    (reduce .[] as $e ({};
       .[($e.kind) + "/" + $e.id + (if $e.stage then "/" + $e.stage else "" end)] = $e)) as $fold
    | (reduce .[] as $e ({}; if $e.kind == "discard" then .[$e.id] = true else . end)) as $dead
    | ($fold | [.[] | select(.kind == "waiter") | .id]) as $waiters
    | $fold | [.[] | select(.id as $i | $waiters | index($i)) | select($dead[.id] // false | not)]
    | .[]
    | if .kind == "waiter" then ["reply", .id, "waiter", .task, (.grace | tostring)]
      elif .kind == "timer" then
        ["reply", .id, "timer", .stage,
         (if .anchor == null then "none" else ((.anchor + .grace) | tostring) end)]
      elif .kind == "fire" then ["reply", .id, "fire", .stage, (.epoch | tostring)]
      elif .kind == "answer" then ["reply", .id, "answer", (.epoch | tostring), .via]
      else empty end
    | @tsv' "$1" 2>/dev/null | LC_ALL=C sort
}

# --- subcommands -------------------------------------------------------------
# cmd_sync <state-dir>...: publish every fact every record of these homes holds.
# The producers publish their own facts as they write, so this is the one-time
# backfill a home runs once after the switch, and the repair after a lost stream.
cmd_sync() {
  local st dir rec n=0
  bus_gate >/dev/null 2>&1 || return 0
  bus_ensure_stream
  for st in "$@"; do
    dir="$st/pending-replies"
    [ -d "$dir" ] || { printf 'sync: no record directory at %s\n' "$dir" >&2; continue; }
    n=0
    for rec in "$dir"/[0-9a-f]*; do
      [ -f "$rec" ] || continue
      publish_record "$st" "$rec"
      n=$((n + 1))
    done
    printf 'reply bus backfill: records=%s home=%s\n' "$n" "$(dirname "$st")"
  done
}

# cmd_publish <record>: one producer's write, as the events of that record.
cmd_publish() { # <record-path>
  local rec=$1 st at
  [ -n "$rec" ] || return 2
  st=$(dirname "$(dirname "$rec")")
  at=${AT:-$(date +%s)}
  bus_gate >/dev/null 2>&1 || return 0
  bus_ensure_stream
  if [ "$DISCARD" = 1 ]; then
    publish_discard "$st" "$(basename "$rec")" "$at"
    return 0
  fi
  publish_record "$st" "$rec"
}

# cmd_log: the stream in the engine's log format, so the fold, the decision and
# the replay read the bus itself instead of a file beside it.
cmd_log() {
  local tmp
  bus_gate >/dev/null 2>&1 || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/jg-reply-bus-log.XXXXXX") || return 1
  bus_dump "$tmp" "$SINCE" "$(home_keys)" || true
  jq -r -s '
    (reduce .[] as $e ({}; if $e.kind == "discard" then .[$e.id] = true else . end)) as $dead
    | .[] | select(($dead[.id] // false) | not)
    | [(.kind + "/" + .id + (if .stage then "/" + .stage else "" end)), (.seq | tostring),
       (. | del(.seq) | tojson)]
    | join("\t")' "$tmp" 2>/dev/null || true
  rm -f -- "$tmp"
}

# cmd_project <state-dir>: the fold written back as the record files. This is the
# projection: the writer's keys, the delivery marker the readers expect, and a
# discarded waiter's files gone. Run it against a copy to prove the stream holds
# everything the records do.
cmd_project() { # <state-dir>
  local st=$1 dir tmp corr dead b64 delivered attempted target
  dir="$st/pending-replies"
  bus_gate >/dev/null 2>&1 || return 0
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/jg-reply-bus-project.XXXXXX") || return 1
  bus_dump "$tmp" 0 "$(home_keys)" || true
  jq -r -s '
    sort_by(.seq)
    | reduce .[] as $e ({};
        .[$e.id] = ((.[$e.id] // {id: $e.id})
          | if $e.kind == "discard" then .dead = true
            elif $e.kind == "waiter" then .waiter = $e
            else . end))
    | [.[] | select(.waiter or .dead)] | .[]
    | [ .id, (if .dead then "1" else "0" end), ((.waiter.record // "") | @base64),
        ((.waiter.delivered // "-") | tostring), ((.waiter.attempted // "-") | tostring) ]
    | @tsv' "$tmp" 2>/dev/null | while IFS=$'\t' read -r id dead b64 delivered attempted; do
      # The event id is <home>/<corr>; the record's name is the corr alone.
      corr=${id##*/}
      case "$corr" in ''|*[!a-f0-9]*) continue ;; esac
      target="$dir/$corr"
      if [ "$dead" = 1 ] || [ -z "$b64" ]; then
        rm -f -- "$target" "$dir/.delivery-confirmed-$corr"
        continue
      fi
      if printf '%s' "$b64" | base64 -d > "$dir/.$corr.tmp.$$" 2>/dev/null \
        && chmod 600 "$dir/.$corr.tmp.$$" 2>/dev/null; then
        mv -f "$dir/.$corr.tmp.$$" "$target" || rm -f -- "$dir/.$corr.tmp.$$"
      else
        rm -f -- "$dir/.$corr.tmp.$$"
        continue
      fi
      # The delivery marker is a fact of the same event: attempted and unconfirmed
      # is a marker, and a confirmed delivery is the record's delivered_epoch.
      if [ "$delivered" = - ] && [ "$attempted" != - ]; then
        printf 'attempted=%s\n' "$attempted" > "$dir/.delivery.tmp.$$" \
          && chmod 600 "$dir/.delivery.tmp.$$" 2>/dev/null \
          && mv -f "$dir/.delivery.tmp.$$" "$dir/.delivery-confirmed-$corr"
      else
        rm -f -- "$dir/.delivery-confirmed-$corr"
      fi
    done
  rm -f -- "$tmp"
}

cmd_view() {
  local tmp
  bus_gate || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/jg-reply-bus-dump.XXXXXX") || return 1
  bus_dump "$tmp" "$SINCE" "$(home_keys)" || true
  bus_rows "$tmp"
  rm -f -- "$tmp"
}

# scan_window <out-file>: the record path's rows inside the window, sorted.
scan_window() { # <out-file>
  local st out=$1
  : > "$out"
  for st in "${HOMES[@]}"; do facts_rows "$st" "$SINCE" >> "$out"; done
  LC_ALL=C sort -o "$out" "$out"
}

# cmd_parity: replay the window through both paths and compare the consumer
# result row by row. The record path is live, so a fact can appear or change while
# the comparison runs; only rows both scans of the record path agree on are
# compared, and the ones that moved are counted as churned instead of being
# reported as a difference they are not. --corrupt tampers with one event first,
# so a run that still reported no difference would be a vacuous check.
cmd_parity() {
  local tmp diffs=0 compared=0 churned=0 timers_armed=0 timers_fired=0
  local late_max=0 fire_without_timer=0 fire_early=0
  bus_gate || return 0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/jg-reply-bus-parity.XXXXXX") || return 1
  scan_window "$tmp/before"
  scan_window "$tmp/after"
  comm -12 "$tmp/before" "$tmp/after" > "$tmp/file"
  comm -3 "$tmp/before" "$tmp/after" | sed 's/^\t//' | LC_ALL=C sort -u > "$tmp/churn"
  churned=$(awk 'END { print NR }' "$tmp/churn")
  [ "$CORRUPT" -eq 1 ] && { corrupt_one_event || true; }
  bus_dump "$tmp/dump" "$SINCE" "$(home_keys)" || true
  bus_rows "$tmp/dump" > "$tmp/bus.all"
  if [ -s "$tmp/churn" ]; then
    grep -vxF -f "$tmp/churn" "$tmp/bus.all" > "$tmp/bus" 2>/dev/null || : > "$tmp/bus"
  else
    cp "$tmp/bus.all" "$tmp/bus"
  fi
  compared=$(awk 'END { print NR }' "$tmp/file")
  if ! diff -u "$tmp/file" "$tmp/bus" > "$tmp/diff" 2>&1; then
    diffs=$(grep -cE '^[+-][^+-]' "$tmp/diff" || true)
    grep -E '^[+-][^+-]' "$tmp/diff" | head -n 20
  fi
  read -r timers_armed timers_fired late_max fire_without_timer fire_early < <(
    awk -F'\t' '
      $3 == "timer" && $5 != "none" { armed[$2 SUBSEP $4] = $5 }
      $3 == "fire" { fired++; fkey[fired] = $2 SUBSEP $4; fep[fired] = $5 }
      END {
        for (i = 1; i <= fired; i++) {
          at = armed[fkey[i]]
          if (at == "") { orphan++; continue }
          late = fep[i] - at
          if (late < 0) { early++; continue }
          if (late > max) max = late
        }
        printf "%d %d %d %d %d\n", length(armed), fired + 0, max + 0, orphan + 0, early + 0
      }' "$tmp/file" 2>/dev/null
  )
  printf 'reply bus parity: homes=%s events_compared=%s differences=%s churned=%s timers_armed=%s timers_fired=%s max_lateness_s=%s fire_without_timer=%s fire_before_deadline=%s\n' \
    "${#HOMES[@]}" "$compared" "${diffs:-0}" "$churned" "${timers_armed:-0}" \
    "${timers_fired:-0}" "${late_max:-0}" "${fire_without_timer:-0}" "${fire_early:-0}"
  rm -rf -- "$tmp"
  [ "${diffs:-0}" -eq 0 ]
}

# corrupt_one_event: republish one existing event with a tampered field, under a
# fresh message id so the store keeps it and the fold presents it last. The
# deadline, the fire epoch, the answer epoch and the waiter's task are all things
# a row shows, so the tampered event must produce a difference.
corrupt_one_event() {
  local last n raw subject body id keys
  keys=$(home_keys)
  last=$(bus stream info "$REPLY_STREAM" --json 2>/dev/null | jq -r '.state.last_seq // 0' 2>/dev/null)
  case "$last" in ''|*[!0-9]*) return 1 ;; esac
  n=1
  while [ "$n" -le "$last" ]; do
    raw=$(bus stream get "$REPLY_STREAM" "$n" --json 2>/dev/null)
    n=$((n + 1))
    subject=$(printf '%s' "$raw" | jq -r '.subject // empty' 2>/dev/null)
    body=$(printf '%s' "$raw" | jq -r '.data // empty' 2>/dev/null | base64 -d 2>/dev/null || true)
    [ -n "$subject" ] && [ -n "$body" ] || continue
    # Only a row inside the window and of a compared home can change the verdict.
    printf '%s' "$body" | jq -e --argjson since "$SINCE" --argjson keys "$keys" \
      'select(.at >= $since) | . as $e | select($keys | index($e.home) != null)' >/dev/null 2>&1 || continue
    id=$(printf '%s' "$body" | jq -r '.id // empty' 2>/dev/null)
    [ -n "$id" ] || continue
    bus_publish "$subject" "$id/corrupt/$(date +%s)-$RANDOM" \
      "$(printf '%s' "$body" | jq -c '
        if (.anchor | type) == "number" then .anchor += 1
        elif (.epoch | type) == "number" then .epoch += 1
        else .task = "corrupted-by-the-parity-test" end')" && return 0
  done
  return 1
}

# --- arguments ---------------------------------------------------------------
h=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      [ -n "${2:-}" ] || { printf 'jg-reply-bus.sh: --home needs a directory\n' >&2; exit 2; }
      h=$(cd "$2/state" 2>/dev/null && pwd) || {
        printf 'jg-reply-bus.sh: no state directory under %s\n' "$2" >&2; exit 2; }
      HOMES+=("$h")
      shift 2
      ;;
    --since-hours)
      [ -n "${2:-}" ] || { printf 'jg-reply-bus.sh: --since-hours needs a count\n' >&2; exit 2; }
      SINCE_HOURS=$2
      shift 2
      ;;
    --at)
      [ -n "${2:-}" ] || { printf 'jg-reply-bus.sh: --at needs an epoch\n' >&2; exit 2; }
      AT=$2
      shift 2
      ;;
    --discard) DISCARD=1; shift ;;
    --corrupt) CORRUPT=1; shift ;;
    -h|--help) sed -n '2,66p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    publish|sync|project|log|view|parity) CMD=$1; shift ;;
    *)
      [ -z "$POS" ] || { printf 'jg-reply-bus.sh: unexpected argument: %s\n' "$1" >&2; exit 2; }
      POS=$1
      shift
      ;;
  esac
done
case "$SINCE_HOURS" in ''|*[!0-9]*) printf 'jg-reply-bus.sh: --since-hours must be a count\n' >&2; exit 2 ;; esac
case "${AT:-}" in ''|*[!0-9]*) [ -z "${AT:-}" ] || { printf 'jg-reply-bus.sh: --at must be an epoch\n' >&2; exit 2; } ;; esac
SINCE=$(( $(date +%s) - SINCE_HOURS * 3600 ))
[ -n "$CMD" ] || { printf 'usage: jg-reply-bus.sh publish|sync|project|log|view|parity [--home DIR] (see the header)\n' >&2; exit 2; }
# One record names its own home: the record path is <home>/state/pending-replies/<id>,
# so a producer needs no other context to publish.
if [ "$CMD" = publish ] && [ "${#HOMES[@]}" -eq 0 ]; then
  [ -n "$POS" ] || { printf 'jg-reply-bus.sh: publish needs a record path\n' >&2; exit 2; }
  HOMES=("$(dirname "$(dirname "$POS")")")
fi
if [ "${#HOMES[@]}" -eq 0 ]; then HOMES=("${JG_STATE_OVERRIDE:-${JG_HOME:-$ROOT}/state}"); fi
for h in "${HOMES[@]}"; do
  [ -d "$h" ] || { printf 'jg-reply-bus.sh: no state directory at %s\n' "$h" >&2; exit 2; }
done
HOME_DIR=$(dirname "${HOMES[0]}")
WORKFLOW=$(workflow_file "$HOME_DIR")
REPLY_STREAM=$(wf '.stream.name' JG_REPLY)
REPLY_SUBJECT=$(wf '.stream.subjects' 'jg.reply.>')
MAX_AGE=$(wf '.stream.max_age' 168h)
SUBJECT_WAITER=$(wf '.subjects.waiter' jg.reply.start)
SUBJECT_TIMER=$(wf '.subjects.timer' jg.reply.timer)
SUBJECT_FIRE=$(wf '.subjects.fire' jg.reply.fire)
SUBJECT_ANSWER=$(wf '.subjects.answer' jg.reply.answer)
SUBJECT_DISCARD=$(wf '.subjects.discard' jg.reply.discard)
GRACE_DEFAULT=$(wf '.defaults.grace_secs' "${JG_PENDING_REPLY_GRACE_SECS:-120}")
MAX_AGE=$(config_get "$HOME_DIR" max-age "$MAX_AGE")
STAGES=$(jq -r '[.stages[] | [.name, .timer_anchor, .fire_epoch] | join("|")] | join(" ")' "$WORKFLOW" 2>/dev/null)
[ -n "$STAGES" ] || STAGES='request|request_turn_completed_epoch|recovery_attempted_epoch recovery|recovery_turn_completed_epoch|escalated_epoch'
BUS_URL=$(config_get "$HOME_DIR" nats-url "nats://127.0.0.1:4222")
[ -n "${JG_REPLY_BUS_URL:-}" ] && BUS_URL=$JG_REPLY_BUS_URL

case "$CMD" in
  publish) cmd_publish "$POS" ;;
  sync) cmd_sync "${HOMES[@]}" ;;
  project) for h in "${HOMES[@]}"; do cmd_project "$h"; done ;;
  log) cmd_log ;;
  view) cmd_view ;;
  parity) cmd_parity ;;
esac

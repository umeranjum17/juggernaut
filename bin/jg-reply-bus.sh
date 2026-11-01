#!/usr/bin/env bash
# jg-reply-bus.sh - one pending reply as a Dapr workflow, in shadow: the wait for
# the reply event or its timeout runs beside the file path, and the files stay
# authoritative.
#
# WHY THIS EXISTS (migration step 5d). A pending reply is a hand-rolled
# wait-for-reply-or-timeout: a record file, a grace window measured from a turn's
# completion, a busy/idle observation to find that completion, one recovery
# repost with its own reconciliation ladder, a second grace window, and then one
# escalation. The decided shape is a durable workflow: the waiter is an instance,
# the reply is the event that resumes it, the timeout is a timer that survives a
# restart, and the repost-then-escalate ladder is the workflow's own activity
# loop. This step puts the same wait on the bus beside the record and proves the
# event path reaches the record path's decision - the same reply settles the same
# waiter, and the same timeout is bound to the same deadline. Nothing switches,
# and this script writes nothing into the file path.
#
# core/bus/workflows/pending-reply.json is the workflow definition: the instance
# key, the events, the two stages with the anchor each timer measures from, the
# activity each timeout runs and its retries, and the terminal states. That file,
# not this script, decides the grace default, the subjects and the retention.
#
# docs/reply-shadow.md owns the event model, the parity contract, the measured
# line count of each path and what a switch would remove.
#
# CONTRACT (this header is the one owner of the shadow's shape here).
#   config   a home turns the shadow on with config/reply-bus, which may also set
#            `nats-url <url>`; JG_REPLY_BUS_URL overrides it. The workflow file may
#            be overridden per home at config/bus/workflows/pending-reply.json.
#   events   one event per fact of one waiter, all on jg.reply.>:
#              waiter  the instance exists: task and the grace it waits for
#              timer   the timeout one stage is bound to: stage, anchor, grace
#              fire    that timeout fired, at the epoch the record shows
#              answer  the reply that settled the waiter: epoch and how it came
#            The message id is the fact's key plus a digest of its body, so a
#            repeat publish is a server no-op and a changed fact supersedes the
#            earlier one. The fold keeps the last event per key.
#   rows     both paths produce the same canonical rows, one per consumer-visible
#            fact, and parity compares them sorted:
#              reply <id> waiter <task> <grace>
#              reply <id> timer  <stage> <deadline|none>
#              reply <id> fire   <stage> <epoch>
#              reply <id> answer <epoch> <via>
#            The deadline is derived on each side from the anchor and the grace,
#            so a mixed-up anchor, grace or unit shows up as a difference.
#   write    nothing here writes to the file path: no record, no status line, no
#            repost, no escalation. A missing client or server prints `skip: ...`
#            and exits 0.
#
# Usage:
#   jg-reply-bus.sh sync                        mirror this home's waiters as events
#   jg-reply-bus.sh view [--since-hours N]      print the workflow rows as TSV
#   jg-reply-bus.sh parity [--since-hours N] [--corrupt]
#                                               replay both paths and compare them
#
# Options: --home DIR (repeatable) resolves a home and its state directory and
# never writes to it; --record-dir DIR keeps the shadow record outside the home;
# --corrupt republishes one event with a tampered field, which parity must then
# report as a difference, so a green run is never vacuous.
#
# Env: JG_REPLY_BUS_URL, JG_NATS_BIN, JG_REPLY_BUS_SHADOW, JG_PENDING_REPLY_GRACE_SECS.
set -u
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=bin/jg-kv-lib.sh
. "$SCRIPT_DIR/jg-kv-lib.sh"

SINCE_HOURS=168
CORRUPT=0
CMD=
HOMES=()
RECORD_DIR=${JG_REPLY_BUS_RECORD_DIR:-}
PUBLISH=0

config_get() { # <home-dir> <key> <default>
  local var value
  var="JG_REPLY_BUS_$(printf '%s' "$2" | tr 'a-z-' 'A-Z_')"
  value=$(eval "printf '%s' \"\${$var:-}\"")
  if [ -z "$value" ] && [ -f "$1/config/reply-bus" ]; then
    value=$(awk -v k="$2" '$1 == k { sub(/^[^ ]+[ \t]+/, ""); print; exit }' "$1/config/reply-bus" 2>/dev/null)
  fi
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

# --- the file path's facts ---------------------------------------------------
# record_facts <state-dir> <since-epoch>: one line per fact the record path holds
# for a waiter, read in a single pass over the record files. The names in the
# right-hand columns are the workflow definition's, so the facts and the stages
# cannot drift apart silently.
record_facts() { # <state-dir> <since-epoch>
  local st=$1 since=$2 dir
  dir="$st/pending-replies"
  [ -d "$dir" ] || return 0
  set -- "$dir"/[0-9a-f]*
  [ -e "$1" ] || return 0
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

bus_ensure_stream() {
  bus stream info "$REPLY_STREAM" >/dev/null 2>&1 && return 0
  bus stream add "$REPLY_STREAM" --subjects "$REPLY_SUBJECT" --storage file \
    --retention limits --max-age "$MAX_AGE" --dupe-window 24h --defaults >/dev/null 2>&1
}

bus_publish() { # <subject> <message-id> <json>
  bus pub --jetstream -q -H "Nats-Msg-Id:$2" "$1" "$3" >/dev/null 2>&1
}

# record_file <state-dir>: the shadow record's path, one line per published fact.
# It keeps a sync cheap and restartable, and it lives outside the home when a
# replay must not write into a home it is only reading.
record_file() { # <state-dir>
  if [ -n "$RECORD_DIR" ]; then
    mkdir -p "$RECORD_DIR" || return 1
    printf '%s/%s.jsonl\n' "$RECORD_DIR" "$(home_key "$1" | tr ':' '_')"
  else
    mkdir -p "$1" || return 1
    printf '%s/reply-bus.jsonl\n' "$1"
  fi
}

# facts_events <state-dir> <since-epoch>: the event document and its key for
# every fact, as "key<TAB>json". Built in awk so a replay of thousands of
# waiters costs one process, not one per fact.
facts_events() { # <state-dir> <since-epoch>
  record_facts "$1" "$2" | awk -F'\t' -v home="$(home_key "$1")" '
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

# mirror_home <state-dir>: publish the facts this home gained or changed. It
# never touches the file path, and a publish that fails records nothing so the
# next sync tries again.
mirror_home() { # <state-dir>
  local st=$1 record cand changed published=0 key json sha subject
  [ -d "$st" ] || { printf 'mirror: no state directory at %s\n' "$st" >&2; return 1; }
  record=$(record_file "$st") || return 1
  [ "${PUBLISH:-0}" = 1 ] && bus_ensure_stream
  cand=$(mktemp "${TMPDIR:-/tmp}/jg-reply-bus-cand.XXXXXX") || return 1
  changed=$(mktemp "${TMPDIR:-/tmp}/jg-reply-bus-new.XXXXXX") || { rm -f -- "$cand"; return 1; }
  facts_events "$st" "$SINCE" > "$cand"
  awk -F'\t' 'NR == FNR { last[$1] = $3; next } last[$1] != $2' "$record" "$cand" > "$changed" 2>/dev/null \
    || cp "$cand" "$changed"
  while IFS=$'\t' read -r key json; do
    [ -n "${key:-}" ] && [ -n "${json:-}" ] || continue
    sha=$(printf '%s' "$json" | sha256_of)
    # The log is the event store and is written first: a fact the engine folds is
    # a fact this home holds, whether or not a bus ever answers. The bus is a
    # transport for the same lines, so a missing server costs the replica, never
    # the event.
    printf '%s\t%s\t%s\n' "$key" "$sha" "$json" >> "$record" || continue
    published=$((published + 1))
    [ "$PUBLISH" = 1 ] || continue
    case "$key" in waiter/*) subject=$SUBJECT_WAITER ;; timer/*) subject=$SUBJECT_TIMER ;;
      fire/*) subject=$SUBJECT_FIRE ;; answer/*) subject=$SUBJECT_ANSWER ;; *) continue ;; esac
    bus_publish "$subject" "$key/$sha" "$json" >/dev/null 2>&1 || true
  done < "$changed"
  rm -f -- "$cand" "$changed"
  printf 'reply shadow mirror: published=%s home=%s\n' "$published" "$(dirname "$st")"
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
    n=$((n + 1))
    body=$(printf '%s' "$raw" | jq -r '.data // empty' 2>/dev/null | base64 -d 2>/dev/null || true)
    if [ -n "$body" ]; then
      printf '%s' "$body" | jq -c --argjson since "$since" --argjson keys "$keys" \
        'select(.at >= $since) | . as $e | select($keys | index($e.home) != null)' >> "$out" 2>/dev/null || true
    fi
  done
}

# bus_rows <dump-file>: the fold as the rows a consumer sees. An answer or a fire
# only counts for a waiter the stream holds, and the deadline is derived here from
# the anchor and the grace the timer event carries.
bus_rows() { # <dump-file>
  jq -r -s '
    (reduce .[] as $e ({};
       .[($e.kind) + "/" + $e.id + (if $e.stage then "/" + $e.stage else "" end)] = $e)) as $fold
    | ($fold | [.[] | select(.kind == "waiter") | .id]) as $waiters
    | $fold | [.[] | select(.id as $i | $waiters | index($i))]
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
# cmd_sync: mirror the facts of every named home into its event log, then onto
# the bus when one answers. The bus is optional on purpose: the log is the store.
cmd_sync() {
  local st
  PUBLISH=0
  if bus_gate >/dev/null 2>&1; then PUBLISH=1; fi
  for st in "$@"; do mirror_home "$st" || return 1; done
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
  cmd_sync "${HOMES[@]}" || true
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
  printf 'reply shadow parity: homes=%s events_compared=%s differences=%s churned=%s timers_armed=%s timers_fired=%s max_lateness_s=%s fire_without_timer=%s fire_before_deadline=%s\n' \
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
    --record-dir)
      [ -n "${2:-}" ] || { printf 'jg-reply-bus.sh: --record-dir needs a directory\n' >&2; exit 2; }
      RECORD_DIR=$2
      shift 2
      ;;
    --since-hours)
      [ -n "${2:-}" ] || { printf 'jg-reply-bus.sh: --since-hours needs a count\n' >&2; exit 2; }
      SINCE_HOURS=$2
      shift 2
      ;;
    --corrupt) CORRUPT=1; shift ;;
    sync|view|parity) CMD=$1; shift ;;
    *) printf 'jg-reply-bus.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
case "$SINCE_HOURS" in ''|*[!0-9]*) printf 'jg-reply-bus.sh: --since-hours must be a count\n' >&2; exit 2 ;; esac
SINCE=$(( $(date +%s) - SINCE_HOURS * 3600 ))
[ -n "$CMD" ] || { printf 'usage: jg-reply-bus.sh [--home DIR] sync|view|parity (see the header)\n' >&2; exit 2; }
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
GRACE_DEFAULT=$(wf '.defaults.grace_secs' "${JG_PENDING_REPLY_GRACE_SECS:-120}")
MAX_AGE=$(config_get "$HOME_DIR" max-age "$MAX_AGE")
STAGES=$(jq -r '[.stages[] | [.name, .timer_anchor, .fire_epoch] | join("|")] | join(" ")' "$WORKFLOW" 2>/dev/null)
[ -n "$STAGES" ] || STAGES='request|request_turn_completed_epoch|recovery_attempted_epoch recovery|recovery_turn_completed_epoch|escalated_epoch'
BUS_URL=$(config_get "$HOME_DIR" nats-url "nats://127.0.0.1:4222")
[ -n "${JG_REPLY_BUS_URL:-}" ] && BUS_URL=$JG_REPLY_BUS_URL

# The mirror is opt-in: a home turns it on with config/reply-bus, or with
# JG_REPLY_BUS_SHADOW=on for a run that must not write into that home.
if [ "$CMD" = sync ] && [ ! -f "$HOME_DIR/config/reply-bus" ] \
  && [ "$(config_get "$HOME_DIR" shadow off)" != on ]; then
  printf 'skip: reply workflow shadow not enabled (config/reply-bus)\n'
  exit 0
fi

case "$CMD" in
  sync) cmd_sync "${HOMES[@]}" ;;
  view) cmd_view ;;
  parity) cmd_parity ;;
esac

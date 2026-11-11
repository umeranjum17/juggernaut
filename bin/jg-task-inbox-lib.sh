#!/usr/bin/env bash
# jg-task-inbox-lib.sh - the per-task steering inbox: durable records plus a
# constant doorbell.
#
# ONE owner of the steering-inbox contract: the record format, sequence
# allocation, the idempotent re-enqueue dedup, the handled/ acknowledgement,
# the self-describing doorbell line, and the watcher's re-ring ladder policy.
# bin/jg-send.sh writes and rings locally, the host-local remote steer leg
# (bin/jg-remote-squad-lead-control.sh cmd_send) writes idempotently and rings
# on the remote host, bin/jg-watch.sh and bin/jg-delivery-tick.sh both poll and
# re-ring through the one ladder below (jg_task_inbox_ladder), and the brief
# scaffold (bin/jg-brief.sh) tells the worker how to read and acknowledge;
# none of them restates the format.
#
# Design (captain-adopted, data/jg-send-reliability-reframe-s1/report.md): the
# payload moves to the filesystem, which is reliable; the terminal carries only
# a short constant doorbell line. While the endpoint remains available, that
# line does not need to be reliable because ringing it again is free. A
# duplicated doorbell is a no-op by construction (the worker finds the inbox
# empty or already handled), and a swallowed doorbell is detected by the
# absence of the worker's acknowledgement and re-rung on a bounded schedule.
# A positively dead or missing endpoint bypasses that schedule without being
# typed into, and its unhandled record surfaces through the ordinary stale wake
# into stuck-operator-recovery.
#
# Layout under <state-dir>:
#   <task>.inbox/NNN.msg       one durable steer, numeric sequence, atomic rename
#   <task>.inbox/handled/      the worker's `mv` here IS the acknowledgement
#   <task>.inbox/.delivery.jsonl  the delivery record, one JSON line per proof (see
#                              below); append-only, never read by the ladder
#   <task>.inbox/.seq.lock     serializes sequence allocation across writers
#                              (the session and the away daemon)
#   <task>.inbox/.ring-state   watcher re-ring ladder: "<msg>\t<count>\t<epoch>"
#   <task>.inbox/.busy-state   consecutive deferrals: "<msg>\t<count>" (a turn
#                              still running, or a composer holding other text)
#   <task>.inbox/.busy-escalated  oldest message already reported as deferred by
#                              a running turn; NOT a delivery terminal
#   <task>.inbox/.held-escalated  oldest message already reported as held behind
#                              other composer text; NOT a delivery terminal
#   <task>.inbox/.escalated    oldest-message name already surfaced as stale,
#                              so later polls suppress another escalation
#   <task>.inbox/.composer-seen  a lead's pending composer text: hash, first-seen
#                              epoch, submitted flag (the unchanged-text submit)
#   <task>.inbox/.retry-ring   name of a fire-and-forget record still owed its
#                              one retry ring (jg_task_inbox_mark_retry)
#
# Record format (jg_task_inbox_write / jg_task_inbox_body):
#   schema=jg-task-inbox.v1
#   at=<utc timestamp>
#   ticket=<id>                the ticket the steer is about: its ticket=<id> token, else the task
#   kind=<order|route|steer>   what the steer is: its [order] or [route] tag, else steer
#                              (core/machines/tables/message.tsv; steers are counted from these two lines)
#   delivery=fire-and-forget   present only when the re-ring ladder must ignore it
#                              (it still gets one retry ring; see below)
#   --
#   <exact message text; newlines are legal; a marked squad_lead request keeps
#    its from-juggernaut marker and corr token verbatim in this body>
#
# Delivery record (jg_task_delivery_note, bin/jg-delivery.sh): five words, each with its
# own proof, and no word stands in for another. stored: the record was renamed into the
# inbox. rung: the doorbell was typed (a ring that returned 0). read: the worker moved the
# record to handled/ - the folder name is old, the move proves only a read. handled: the
# worker ran `bin/jg-delivery.sh handled` with an evidence pointer (a status line, commit,
# reply, task change or PR). failed: the worker refused it with a reason. Only stored,
# rung and ring-failed (a ring that did not land; the pointer is its exit code) are written
# here; the rest is the worker's claim and is shown as one.
#
# Sequence numbers are never reused within a task: allocation scans both the
# inbox root and handled/, so a message is processed at most once per worker
# lifetime even if every doorbell is duplicated. Concurrent writers serialize
# on .seq.lock; the worst racing outcome is ordering, never loss.
#
# Re-ring ladder (jg_task_inbox_due_action): an unhandled message older than
# JG_TASK_INBOX_GRACE_SECS is due one delivery attempt per grace period; an
# attempt may ring or be skipped to protect another draft in a proven pending
# composer; an unsubmitted copy of this doorbell is retried. After
# JG_TASK_INBOX_RING_MAX attempts without an acknowledgement it escalates. The
# caller owns the busy and recovery-grade endpoint checks: due actions deferred
# by a busy pane consume a separate durable consecutive-poll budget,
# JG_TASK_INBOX_BUSY_MAX. At that bound the caller surfaces a stuck-busy reason
# WITHOUT typing, and that report is not a give-up: a busy pane is a turn still
# running, so the deferral keeps the message owed and the doorbell rings on the
# first non-busy poll. A composer that provably holds other text is the same
# kind of deferral, reported at once because one key press clears it, and it
# never spends the delivery budget either. A non-busy due check or
# acknowledgement resets this budget.
# Fire-and-forget retries remain outside escalation. A positively
# dead or missing endpoint skips delivery and the ladder and escalates directly.
# This library owns the schedule, durable budgets, and escalation marker.
# If delivery-attempt or busy-deferral bookkeeping fails while the record remains unhandled,
# the caller surfaces that failure instead of retrying silently; a concurrently
# removed inbox is a quiet no-op. Escalation deliberately queues the wake before
# writing the deduplication marker: normal polls surface a message once, while a
# crash or marker failure may produce a rare duplicate rather than silently lose
# a wake.
#
# Retry ring (jg_task_inbox_mark_retry): only while config/wait-no-turns is
# present. A fire-and-forget record never enters the ladder, but when
# jg-send's ring at enqueue did not land
# (jg_task_inbox_ring returned 1 or 2) it marks the record, and one grace later
# the due action is `retry`: once the worker has no open decision of its own,
# the watcher rings once more and spends the mark
# whatever the result, so the record never rings a third time and never
# escalates. A waiting worker does not poll its inbox (bin/jg-brief.sh), so
# without this retry the record could sit unread until a checkpoint. A pending ordinary record's
# ladder rings the same inbox, so the retry waits behind it, and an
# acknowledged record drops its mark. The remote steer leg has no watcher
# ladder and owes no retry.
#
# Inbox names containing bytes outside printable ASCII are unsupported. The
# doorbell refuses them rather than sending terminal control bytes to a pane.
#
# jg_task_inbox_ring requires bin/jg-backend.sh's dispatch (sourced below); the
# other helpers are dependency-light. Sourced by bin/jg-send.sh, bin/jg-watch.sh,
# and tests. No side effects on source beyond its sourced libraries.
#
# Tunables (env):
#   JG_TASK_INBOX_GRACE_SECS   default 90; delivery-attempt grace and spacing
#   JG_TASK_INBOX_RING_MAX     default 3; delivery attempts before escalation
#   JG_TASK_INBOX_BUSY_MAX     default 2; consecutive busy-deferred due polls before
#                              the one stuck-busy report (delivery stays owed)
#   JG_TASK_INBOX_HELD_SECS   default 30; minimum age before one Codex retry
#   JG_TASK_INBOX_COMPOSER_SUBMIT_SECS  default 120; a lead's composer text that stays
#                              unchanged this long is submitted once, then the doorbell
#                              rings (jg_task_inbox_unchanged_composer_submit)

_JG_TASK_INBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Both dependencies are canonical lint roots in their own right. Keep them as
# analysis boundaries here so ShellCheck's external-source traversal does not
# recursively duplicate the full backend graph for every inbox consumer.
# shellcheck source=/dev/null
. "$_JG_TASK_INBOX_LIB_DIR/jg-wake-lib.sh"
# shellcheck source=/dev/null
. "$_JG_TASK_INBOX_LIB_DIR/jg-backend.sh"
# shellcheck source=/dev/null
. "$_JG_TASK_INBOX_LIB_DIR/jg-busy-lib.sh"

JG_TASK_INBOX_SCHEMA='jg-task-inbox.v1'
JG_TASK_INBOX_GRACE_DEFAULT=90
JG_TASK_INBOX_RING_MAX_DEFAULT=3
JG_TASK_INBOX_BUSY_MAX_DEFAULT=2
JG_TASK_INBOX_LOCK_WAIT_DEFAULT=5

jg_task_inbox_grace_secs() {
  local g=${JG_TASK_INBOX_GRACE_SECS:-$JG_TASK_INBOX_GRACE_DEFAULT}
  case "$g" in ''|*[!0-9]*) g=$JG_TASK_INBOX_GRACE_DEFAULT ;; esac
  printf '%s' "$g"
}

jg_task_inbox_ring_max() {
  local m=${JG_TASK_INBOX_RING_MAX:-$JG_TASK_INBOX_RING_MAX_DEFAULT}
  case "$m" in ''|*[!0-9]*) m=$JG_TASK_INBOX_RING_MAX_DEFAULT ;; esac
  printf '%s' "$m"
}

jg_task_inbox_busy_max() {
  local m=${JG_TASK_INBOX_BUSY_MAX:-$JG_TASK_INBOX_BUSY_MAX_DEFAULT}
  case "$m" in ''|*[!0-9]*) m=$JG_TASK_INBOX_BUSY_MAX_DEFAULT ;; esac
  # Check the length before numeric comparison so oversized input cannot overflow.
  if [ "${#m}" -gt 9 ] || [ "$m" -eq 0 ]; then
    m=$JG_TASK_INBOX_BUSY_MAX_DEFAULT
  fi
  printf '%s' "$m"
}

# Persist before returning the new count, so a fresh watcher continues the same
# bounded wait. A removed or acknowledged record is a quiet no-op.
jg_task_inbox_record_busy() {  # <state-dir> <task-id> <record-path>
  local dir base previous count
  dir=$(jg_task_inbox_dir "$1" "$2")
  base=${3##*/}
  { IFS=$(printf '\t') read -r previous count < "$dir/.busy-state"; } 2>/dev/null || true
  [ "${previous:-}" = "$base" ] || count=0
  case "${count:-}" in ''|*[!0-9]*) count=0 ;; esac
  [ -f "$3" ] || { printf '0'; return 0; }
  count=$((count + 1))
  if ! { printf '%s\t%s\n' "$base" "$count" > "$dir/.busy-state"; } 2>/dev/null; then
    [ -f "$3" ] || { printf '0'; return 0; }
    return 1
  fi
  printf '%s' "$count"
}

# Reset the busy budget and its report dedupe together: once the pane is free
# the record is ordinary ladder work again, so a later busy stretch on the same
# message earns its own report rather than inheriting silence.
jg_task_inbox_clear_busy() {  # <state-dir> <task-id>
  local dir
  dir=$(jg_task_inbox_dir "$1" "$2")
  rm -f "$dir/.busy-state" "$dir/.busy-escalated" 2>/dev/null
}

# One busy-poll deferral of an unread record. Prints exactly one of:
#   quiet             still inside the deferral budget (or already reported)
#   report <count>    the bound is reached: the caller surfaces it once
#   escalate          the deferral bookkeeping cannot be written
# A deferral is NEVER a delivery give-up - the record stays owed, and
# jg_task_inbox_clear_busy re-arms the ladder the moment the pane is free.
jg_task_inbox_defer() {  # <state-dir> <task-id> <record-path>
  local count
  if ! count=$(jg_task_inbox_record_busy "$1" "$2" "$3"); then
    [ -f "$3" ] || { printf 'quiet'; return 0; }
    printf 'escalate'
    return 0
  fi
  if [ "$count" -lt "$(jg_task_inbox_busy_max)" ] \
    || jg_task_inbox_deferral_reported "$1" "$2" "$3" busy; then
    printf 'quiet'
    return 0
  fi
  printf 'report %s' "$count"
}

# Whether this record's deferral report of <kind> was already surfaced, so
# later deferral polls stay quiet. <kind> is busy (a turn still running) or
# held (the composer provably holds other text).
jg_task_inbox_deferral_reported() {  # <state-dir> <task-id> <record-path> <kind>
  local dir
  dir=$(jg_task_inbox_dir "$1" "$2")
  [ "$(cat "$dir/.$4-escalated" 2>/dev/null)" = "${3##*/}" ]
}

# Mark a deferral report as surfaced. Deliberately NOT
# jg_task_inbox_record_escalated: the message is still owed its doorbell, and
# only the report is deduped.
jg_task_inbox_record_deferral_reported() {  # <state-dir> <task-id> <record-path> <kind>
  local dir
  dir=$(jg_task_inbox_dir "$1" "$2")
  [ -d "$dir" ] || return 0
  if ! { printf '%s\n' "${3##*/}" > "$dir/.$4-escalated"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}

jg_task_inbox_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox' "$1" "$2"
}

jg_task_inbox_handled_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox/handled' "$1" "$2"
}

# Numeric sequence of one record basename, or fail for a non-record name.
jg_task_inbox_seq_of() {  # <basename>
  local n=${1%.msg}
  [ "$n" != "$1" ] || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$((10#$n))"
}

# Next unused sequence, scanning the inbox root AND handled/ so an
# acknowledged sequence is never reissued. Caller must hold .seq.lock.
jg_task_inbox_next_seq() {  # <inbox-dir>
  local dir=$1 max=0 d f n
  for d in "$dir" "$dir/handled"; do
    for f in "$d"/*.msg; do
      [ -e "$f" ] || continue
      n=$(jg_task_inbox_seq_of "${f##*/}") || continue
      [ "$n" -le "$max" ] || max=$n
    done
  done
  printf '%03d' "$((max + 1))"
}

jg_task_inbox_lock_acquire() {  # <lock-path>
  local lock=$1 wait=${JG_TASK_INBOX_LOCK_WAIT_SECS:-$JG_TASK_INBOX_LOCK_WAIT_DEFAULT}
  local deadline probe
  case "$wait" in ''|*[!0-9]*) wait=$JG_TASK_INBOX_LOCK_WAIT_DEFAULT ;; esac
  probe=$(mktemp "${lock%/*}/.lock-probe.XXXXXX") || return 1
  rm -f "$probe" || return 1
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    jg_lock_try_create "$lock" && return 0
  fi
  deadline=$(( $(date +%s) + wait ))
  while ! jg_lock_try_acquire "$lock"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

# The per-pane submit lock serializes direct sends with doorbells. A held row
# is recorded only after a send into a proven empty composer left our exact
# text visible. Claim the row before retrying Enter so a crash cannot retry it.
# State transitions under that lock: absent + proven paste -> held; held +
# changed content -> absent; held + due idle matching content -> attempted;
# attempted + matching content -> attempted; any row + empty composer -> absent.
# Only this library owns those transitions; the tmux paste hook asks it to record.
jg_task_inbox_held_record() {  # <dir> <backend> <target> <text> <label>
  local dir=$1 backend=$2 target=$3 text=$4 label=$5 pane held tmp
  [ "$backend" = tmux ] || return 0
  pane=$(tmux display-message -p -t "$target" '#{socket_path}:#{pane_id}' 2>/dev/null) || return 1
  held=$(jg_backend_capture "$backend" "$target" "$JG_COMPOSER_CAPTURE_LINES" "$label" 2>/dev/null) || return 1
  held=$(jg_composer_extract_selected_content styled=0 "$held") || return 1
  [ -n "$text" ] && [ "$held" = "$text" ] || return 0
  tmp=$(mktemp -d "$dir/.held-wake.XXXXXX") || return 1
  printf '%s' "$text" > "$tmp/text" && printf '%s' "$pane" > "$tmp/pane" && date +%s > "$tmp/at" || return 1
  mv "$tmp" "$dir/.held-wake" || return 1
}

jg_task_inbox_held_retry() {  # <dir> <backend> <target> <label>
  local dir=$1 backend=$2 target=$3 label=$4 row=$1/.held-wake at now bound pane held text state dialog
  [ -d "$row" ] && [ "$backend" = tmux ] || return 1
  pane=$(tmux display-message -p -t "$target" '#{socket_path}:#{pane_id}' 2>/dev/null) || return 1
  [ "$pane" = "$(cat "$row/pane" 2>/dev/null)" ] || return 1
  jg_backend_source "$backend" || return 1
  text=$(cat "$row/text" 2>/dev/null) || return 1
  held=$(jg_backend_capture "$backend" "$target" "$JG_COMPOSER_CAPTURE_LINES" "$label" 2>/dev/null) || return 1
  held=$(jg_composer_extract_selected_content styled=0 "$held") || return 1
  if [ -z "$text" ] || [ "$held" != "$text" ]; then
    jg_task_inbox_held_clear "$dir"
    return 1
  fi
  [ ! -e "$row/attempted" ] || return 1
  at=$(cat "$row/at" 2>/dev/null) || return 1
  bound=${JG_TASK_INBOX_HELD_SECS:-30}
  case "$at:$bound" in *[!0-9:]*|:*|*:) return 1 ;; esac
  now=$(date +%s) || return 1
  [ "$((now - at))" -ge "$bound" ] || return 1
  [ "$(jg_pane_busy_state "$target" 2>/dev/null)" = idle ] || return 1
  jg_composer_dialog_sink_prepare || return 1
  state=$(jg_backend_composer_state "$backend" "$target" "$label" 2>/dev/null) || state=unknown
  dialog=$(jg_composer_blocking_dialog_noted 2>/dev/null) || dialog=
  jg_composer_dialog_sink_release
  [ "$state" = pending ] && [ -z "$dialog" ] || return 1
  : > "$row/attempted" || return 1
  jg_backend_send_key "$backend" "$target" Enter "$label" >/dev/null 2>&1 || return 1
  return 0
}

jg_task_inbox_held_clear() { # <dir>
  rm -f "$1/.held-wake/text" "$1/.held-wake/pane" "$1/.held-wake/at" "$1/.held-wake/attempted"
  rmdir "$1/.held-wake" 2>/dev/null || true
}

jg_task_inbox_submit_dir() { # <state> <backend> <target> <inbox-dir>
  local state=$1 backend=$2 target=$3 inbox=$4 pane
  if [ "$backend" = tmux ]; then
    pane=$(tmux display-message -p -t "$target" '#{pane_id}' 2>/dev/null) || return 1
    case "$pane" in ''|*[!a-zA-Z0-9_%.-]*) return 1 ;; esac
    printf '%s/.submit-tmux-%s' "$state" "$pane"
  else
    printf '%s/.submit-%s' "$state" "${inbox##*/}"
  fi
}

jg_task_inbox_direct_submit() { # <state> <backend> <target> <text> <retries> <sleep> <settle> <label> <strict>
  local dir backend=$2 target=$3 text=$4 label=$8 before verdict rc=0
  dir=$(jg_task_inbox_submit_dir "$1" "$backend" "$target" '') || return 1
  mkdir -p "$dir" || return 1
  jg_task_inbox_lock_acquire "$dir/.submit.lock" || return 1
  before=$(jg_backend_composer_state "$backend" "$target" "$label" 2>/dev/null) || before=unknown
  if [ "${9:-0}" = 1 ] && [ "$before" != empty ]; then
    jg_lock_release "$dir/.submit.lock"
    echo 'error: the composer is not confirmed empty; direct text was not typed' >&2
    return 1
  fi
  [ "$before" != empty ] || jg_task_inbox_held_clear "$dir"
  verdict=$(JG_TASK_INBOX_SUBMIT_DIR="$dir" JG_TASK_INBOX_SUBMIT_LABEL="$label" \
    jg_backend_send_text_submit "$backend" "$target" "$text" "$5" "$6" "$7" "$label") || rc=$?
  [ "$verdict" != empty ] || jg_task_inbox_held_clear "$dir"
  jg_lock_release "$dir/.submit.lock"
  printf '%s' "$verdict"
  return "$rc"
}

# Write one record into the next sequence slot: temp-write, then atomic
# rename. Prints the record path. Caller must hold .seq.lock.
# The two header lines every record carries: ticket=<id> and kind=<order|route|steer>.
jg_task_inbox_identity() {  # <task-id> <text>
  local ticket=$1 kind=steer re_tag='(^|[[:space:]])\[(order|route)\]([[:space:]]|$)' re_ticket='(^|[[:space:]])ticket=([A-Za-z0-9._-]+)([[:space:]]|$)'
  [[ $2 =~ $re_ticket ]] && ticket=${BASH_REMATCH[2]}
  [[ $2 =~ $re_tag ]] && kind=${BASH_REMATCH[2]}
  printf 'ticket=%s\nkind=%s\n' "$ticket" "$kind"
}

# One header value of a record (inbox or handled/), empty when the record predates the line.
jg_task_inbox_field() {  # <record-path> <key>
  local rec=$1
  [ -f "$rec" ] || rec="${rec%/*}/handled/${rec##*/}"
  awk -v k="$2" '$0 == "--" { exit } index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$rec" 2>/dev/null
}

_jg_task_inbox_write_record_locked() {  # <inbox-dir> <text> [delivery-mode]
  local dir=$1 text=$2 delivery_mode=${3:-} seq tmp rec status=0 task=${1##*/}
  task=${task%.inbox}
  seq=$(jg_task_inbox_next_seq "$dir")
  rec="$dir/$seq.msg"
  tmp=$(mktemp "$dir/.staging.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$JG_TASK_INBOX_SCHEMA"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jg_task_inbox_identity "$task" "$text"
    [ "$delivery_mode" != fire-and-forget ] || printf 'delivery=fire-and-forget\n'
    printf -- '--\n'
    printf '%s' "$text"
  } > "$tmp" && mv "$tmp" "$rec" || status=1
  [ "$status" -eq 0 ] || { rm -f "$tmp"; return 1; }
  jg_task_delivery_note "$dir" "$seq" stored || true
  # The record is durable, so publish it: the bus is this path's store and the
  # writer is the source, which is why nothing has to scan for it later
  # (docs/bus-live.md). A bus that cannot be reached leaves the record in place
  # and the renderer picks it up on its next pass, so a steer is never lost.
  # A failed raise never blocks the steer, but it is reported, not swallowed.
  local raise_out
  raise_out=$(jg_wake_bus inbox-raise "$task" "$((10#${seq#0}))" \
    "$([ "$delivery_mode" = fire-and-forget ] && printf 'fire-and-forget' || printf 'normal')" \
    "$(printf '%s' "$text" | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | cut -d' ' -f1)" \
    2>&1) || printf 'jg-task-inbox: steer %s for %s is stored, but the event system did not take it: %s\n' \
      "$seq" "$task" "$(printf '%s' "$raise_out" | tr '\n' ' ' | cut -c1-200)" >&2
  printf '%s' "$rec"
}

# Append one proof to the delivery record. Best effort by design: a record that cannot
# be written never blocks a steer, a ring or a worker's claim.
jg_task_delivery_note() {  # <inbox-dir> <seq-or-record-name> <word> [pointer]
  local dir=$1 seq=${2##*/} word=$3 pointer=${4:-}
  seq=${seq%.msg}
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  command -v jq >/dev/null 2>&1 || return 1
  jq -nc --argjson seq "$((10#$seq))" --arg word "$word" --arg pointer "$pointer" --argjson at "$(date +%s)" \
    '{seq:$seq,word:$word,at:$at} + (if $pointer == "" then {} else {pointer:$pointer} end)' \
    >> "$dir/.delivery.jsonl" 2>/dev/null || return 1
}

# Durably enqueue one steer: temp-write, then atomic rename into the next
# sequence slot. Prints the record path. Fails without a partial record.
jg_task_inbox_write() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock rec status=0
  dir=$(jg_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  jg_task_inbox_lock_acquire "$lock" || return 1
  rec=$(_jg_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  jg_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$rec"
}

# Durably enqueue one steer at most once: when a record with the exact same
# body already exists - unhandled or already acknowledged in handled/ - no new
# record is written and the existing record's path is printed instead.
# This is the enqueue primitive for a transport that can fail with completion
# unknown (the remote steer leg over ssh): the caller's safe recovery is to run
# the same enqueue again, and this dedup is what makes the re-run land on the
# same record instead of a duplicate the worker would act on twice. Two
# distinct logical requests never collapse in practice because a marked
# squad_lead request embeds a per-request correlation token in its body. The
# local plane keeps plain jg_task_inbox_write: its outcome is synchronous, so
# a repeated identical local steer is a deliberate new instruction.
jg_task_inbox_write_idempotent() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock want have f rec='' status=0
  dir=$(jg_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  jg_task_inbox_lock_acquire "$lock" || return 1
  if want=$(mktemp "$dir/.dedup.XXXXXX") && have=$(mktemp "$dir/.dedup.XXXXXX"); then
    if printf '%s' "$text" > "$want"; then
      for f in "$dir"/*.msg "$dir/handled"/*.msg; do
        if [ ! -e "$f" ]; then
          case "$f" in
            "$dir"/*.msg)
              f="$dir/handled/${f##*/}"
              [ -e "$f" ] || continue
              ;;
            *) continue ;;
          esac
        fi
        if [ "$delivery_mode" = fire-and-forget ]; then
          jg_task_inbox_is_fire_and_forget "$f" || continue
        elif jg_task_inbox_is_fire_and_forget "$f"; then
          continue
        fi
        if ! jg_task_inbox_body "$f" > "$have" 2>/dev/null; then
          case "$f" in
            "$dir"/*.msg)
              f="$dir/handled/${f##*/}"
              jg_task_inbox_body "$f" > "$have" 2>/dev/null || continue
              ;;
            *) continue ;;
          esac
        fi
        cmp -s "$want" "$have" || continue
        [ ! -e "$dir/handled/${f##*/}" ] || f="$dir/handled/${f##*/}"
        rec=$f
        break
      done
    else
      status=1
    fi
    rm -f "$want" "$have"
  else
    rm -f "${want:-}" 2>/dev/null || true
    status=1
  fi
  if [ "$status" -eq 0 ] && [ -z "$rec" ]; then
    rec=$(_jg_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fi
  jg_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$rec"
}

# The exact enqueued text back out of a record.
jg_task_inbox_body() {  # <record-path>
  local line
  [ -f "$1" ] || return 1
  while IFS= read -r line; do
    if [ "$line" = -- ]; then
      cat
      return 0
    fi
  done < "$1"
  return 1
}

# The constant self-describing doorbell line for the inbox containing a record.
# It names the inbox by the literal "$JG_TASK_INBOX", which bin/jg-spawn.sh
# exports into every launch as the inbox's absolute path, so the worker can
# resolve it from its own environment even after losing its brief context.
# The short `<task>.inbox` name follows as the fallback for a worker launched
# before that export, whose brief carries the full path (bin/jg-dod-lib.sh
# role contract, bin/jg-brief.sh inbox section). No absolute path is printed,
# so the line's length never grows with the home's depth: a long line wraps
# past what a harness composer read can prove, and a Herdr submit then reports
# it did not reach the pane on every re-ring. The leading `: ` is the POSIX
# shell no-op, so the same line typed into a pane whose agent has exited (a
# bare shell) runs nothing; see the dead-pane note in the header. A
# non-printable inbox name fails without output so terminal controls never
# reach the pane's line discipline.
jg_task_inbox_doorbell_line() {  # <record-path>
  local dir=${1%/*} abs name quoted LC_ALL=C
  abs=$(cd "$dir" 2>/dev/null && pwd) || abs=$dir
  abs=${abs%/handled}
  name=${abs##*/}
  case "$name" in
    ''|*[![:print:]]*) return 1 ;;
  esac
  quoted=$(printf '%s' "$name" | sed "s/'/'\\\\''/g")
  printf ": Juggernaut instruction waiting: list \"\$JG_TASK_INBOX\"/*.msg in your '%s' steering inbox, read and act on each in numeric order, then mv each into its handled/." \
    "$quoted"
}

# Whether an earlier unhandled record in the inbox already has a standing bell:
# a ring that landed (a `rung` word in the delivery record), no acknowledgement
# yet, and the worker provably busy (bin/jg-busy-lib.sh, the same verdict the
# watcher defers on). The doorbell names the whole inbox, so a busy worker that
# heard it reads every waiting record when its turn ends; ringing again for each
# later record only repeats the line into its composer. A worker that is idle or
# not provably busy with a rung record still unhandled swallowed that bell (its
# pane sits at an empty prompt), so the bell does not stand and the send rings.
# Only a ring that returned 0 writes `rung`, so a skipped or failed ring never
# silences a later send. The re-ring ladder does not call this: it re-rings the
# oldest unhandled record on its own schedule.
jg_task_inbox_bell_standing() {  # <state-dir> <task-id> <this-record-path> <task-meta>
  local dir this f n rung verdict earlier=0
  dir=$(jg_task_inbox_dir "$1" "$2")
  this=${3##*/}
  [ -s "$dir/.delivery.jsonl" ] && command -v jq >/dev/null 2>&1 || return 1
  rung=$(jq -r 'select(.word == "rung") | .seq' "$dir/.delivery.jsonl" 2>/dev/null) || return 1
  [ -n "$rung" ] || return 1
  for f in "$dir"/*.msg; do
    [ -e "$f" ] || continue
    [ "${f##*/}" != "$this" ] || continue
    n=$(jg_task_inbox_seq_of "${f##*/}") || continue
    printf '%s\n' "$rung" | grep -qx "$n" && { earlier=1; break; }
  done
  [ "$earlier" = 1 ] || return 1
  verdict=$(jg_busy_classify_meta "$4" "$2" "$1")
  [ "${verdict%% *}" = busy ]
}

# Ring the doorbell, best-effort: one endpoint-liveness pre-check, one advisory
# composer pre-check, then the backend's submit machinery with a minimal retry
# budget, verdict discarded.
# Returns 0 rang, 1 skipped because the composer PROVENLY holds pending text
# other than our own doorbell (the watcher re-rings later), 2 the backend send
# failed or the line could not be left out of the composer (withdrawn, or not
# typed because the backend has no clear-line key; the reason says which), 3 skipped because the endpoint is positively dead or missing (nothing
# typed; recovery owns the record). No return value is delivery proof; the
# acknowledgement move is the only delivery signal.
# The skip is deliberately narrow: only an exact `pending` verdict can defer,
# because there our Enter could submit someone's real half-typed content.
# `pending-unproven` and `unknown` still ring - the worst outcome is a garbled
# CONSTANT line the worker recovers semantically, while skipping on ambiguous
# verdicts would starve a harness whose idle screen the classifier cannot
# positively identify (that classifier is advisory here by design).
# For Codex, a pending composer is left alone unless a recorded held wake proves
# what was typed into the same pane, and its bounded retry has not been attempted.
# Other harnesses retain the previous exact-doorbell retry behavior.
# The nudge path normally withdraws a line that did not submit.
# On return 2, JG_TASK_INBOX_RING_REASON holds the backend's refusal
# diagnostics on one line, for callers to log; it is empty otherwise.
jg_task_inbox_ring() {  # <backend> <target> <record-path> [expected-label]
  local rc=0 dir=${3%/*} submit_dir harness
  [ "${dir##*/}" != handled ] || dir=${dir%/*}
  harness=$(jg_meta_get "${dir%.inbox}.meta" harness 2>/dev/null) || harness=
  if [ "$1" = tmux ] && [ "$harness" = codex ]; then
    submit_dir=$(jg_task_inbox_submit_dir "${dir%/*}" "$1" "$2" "$dir") || return 2
    mkdir -p "$submit_dir" || return 2
    jg_task_inbox_lock_acquire "$submit_dir/.submit.lock" || return 2
    if jg_task_inbox_held_retry "$submit_dir" "$1" "$2" "${4:-}"; then
      rc=1
    else
      JG_TASK_INBOX_SUBMIT_DIR="$submit_dir" JG_TASK_INBOX_SUBMIT_LABEL="${4:-}" \
        _jg_task_inbox_ring_attempt "$1" "$2" "$3" "${4:-}" "$submit_dir" || rc=$?
      [ "$(jg_backend_composer_state "$1" "$2" "${4:-}" 2>/dev/null)" != empty ] || jg_task_inbox_held_clear "$submit_dir"
    fi
    jg_lock_release "$submit_dir/.submit.lock"
  else
    _jg_task_inbox_ring_attempt "$@" || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    jg_task_delivery_note "$dir" "${3##*/}" rung || true
  else
    jg_task_delivery_note "$dir" "${3##*/}" ring-failed "$rc" || true
  fi
  return "$rc"
}

_jg_task_inbox_ring_attempt() {  # <backend> <target> <record-path> <expected-label> <submit-dir>
  local backend=$1 target=$2 rec=$3 label=${4:-} submit_dir=${5:-} line cstate verdict errf
  JG_TASK_INBOX_RING_REASON=
  case "$(jg_backend_agent_state "$backend" "$target" 2>/dev/null || true)" in
    dead|missing) return 3 ;;
  esac
  if ! line=$(jg_task_inbox_doorbell_line "$rec"); then
    JG_TASK_INBOX_RING_REASON="inbox name is not printable"
    return 2
  fi
  cstate=$(jg_backend_composer_state "$backend" "$target" "$label" 2>/dev/null) || cstate=unknown
  case "$cstate" in
    pending)
      [ -z "$submit_dir" ] || return 1
      if ! jg_task_inbox_composer_holds "$backend" "$target" "$line" "$label"; then
        # Not our whole line: a leading part of it is an interrupted typing of
        # ours and is withdrawn (never submitted as a fragment); anything else
        # is a human's draft and defers the ring.
        case "$(jg_backend_withdraw_typed "$backend" "$target" "$line" "$label")" in
          withdrawn) JG_TASK_INBOX_RING_REASON="the partly typed doorbell was withdrawn from the composer"; return 2 ;;
          stuck) JG_TASK_INBOX_RING_REASON="the doorbell is still in the composer and could not be cleared"; return 2 ;;
        esac
        return 1
      fi
      [ "$(jg_backend_busy_state "$backend" "$target" 2>/dev/null)" != busy ] || return 1
      jg_backend_send_key "$backend" "$target" Enter "$label" >/dev/null 2>&1 || return 2
      sleep 0.3
      jg_task_inbox_composer_holds "$backend" "$target" "$line" "$label" || return 0
      jg_backend_send_key "$backend" "$target" Enter "$label" >/dev/null 2>&1 || return 2
      sleep 0.3
      case "$(jg_backend_withdraw_typed "$backend" "$target" "$line" "$label")" in
        withdrawn) JG_TASK_INBOX_RING_REASON="the stuck doorbell was withdrawn from the composer"; return 2 ;;
        stuck) JG_TASK_INBOX_RING_REASON="the doorbell is still in the composer and could not be cleared"; return 2 ;;
      esac
      return 0
      ;;
  esac
  [ "$cstate" != empty ] || [ -z "$submit_dir" ] || jg_task_inbox_held_clear "$submit_dir"
  # Accepted residual race: terminal input and Enter are separate delivery
  # steps, so an agent exiting after the liveness check could leave a bare
  # shell only a suffix; the `: ` prefix protects complete lines only. Do not
  # add process-bound atomic delivery here unless an incident reopens this.
  errf=$(mktemp "${TMPDIR:-/tmp}/jg-ring-err.XXXXXX" 2>/dev/null) || errf=/dev/null
  verdict=$(jg_backend_send_nudge "$backend" "$target" "$line" 2 0.4 0.3 "$label" 2>"$errf") || verdict=send-failed
  if [ "$errf" != /dev/null ]; then
    JG_TASK_INBOX_RING_REASON=$(LC_ALL=C tr -c '[:print:]\n' ' ' < "$errf" | sed '/^ *$/d' | paste -sd ';' - | cut -c1-300)
    rm -f "$errf"
  fi
  # The verdict is read only to report a failed keystroke; every other value
  # (empty, pending, unknown, ...) is deliberately ignored, never proof.
  if [ "$verdict" = send-failed ]; then
    JG_TASK_INBOX_RING_REASON=${JG_TASK_INBOX_RING_REASON:-the backend reported send-failed without a reason}
    return 2
  fi
  # A line that was taken back out of the composer (or never typed because it
  # could not be) delivered nothing: the record stays undelivered for a later
  # ring, and no doorbell text is left for a human's next keystroke to join.
  case "$verdict" in
    withdrawn) JG_TASK_INBOX_RING_REASON="the unsubmitted doorbell was withdrawn from the composer"; return 2 ;;
    holds-text) return 1 ;;
    not-withdrawable) JG_TASK_INBOX_RING_REASON="the $backend backend has no clear-line key, so the doorbell was not typed"; return 2 ;;
    stuck)
      if [ -n "$submit_dir" ] && [ "$cstate" = empty ] && [ ! -e "$submit_dir/.held-wake" ]; then
        jg_task_inbox_held_record "$submit_dir" "$backend" "$target" "$line" "$label" || true
      fi
      JG_TASK_INBOX_RING_REASON="the doorbell is still in the composer and could not be cleared"; return 2 ;;
  esac
  JG_TASK_INBOX_RING_REASON=
  return 0
}

jg_task_inbox_composer_holds() {  # <backend> <target> <line> [expected-label]
  local cap held
  jg_backend_source "$1" || return 1
  cap=$(jg_backend_capture "$1" "$2" "$JG_COMPOSER_CAPTURE_LINES" "${4:-}" 2>/dev/null) || return 1
  held=$(jg_composer_extract_selected_content styled=0 "$cap") || return 1
  [ -n "$held" ] && [ "$(printf '%s' "$held" | tr -d '[:space:]')" = "$(printf '%s' "$3" | tr -d '[:space:]')" ]
}

# A lead's composer that keeps the same pending text is a draft nobody will
# finish, and the steer behind it sits unread. Once the exact text has stayed
# unchanged for JG_TASK_INBOX_COMPOSER_SUBMIT_SECS (default 120), submit it once,
# so the doorbell can ring. State under <inbox>/.composer-seen is
# "<content hash>\t<first-seen epoch>\t<submitted 0|1>"; changed text restarts
# the clock, and a submitted hash is never submitted again. Prints "submitted"
# when it pressed Enter; any other outcome prints "wait". A composer that is not
# pending, or a worker that is not a lead, never gets a key press.
jg_task_inbox_composer_submit_secs() {
  local s=${JG_TASK_INBOX_COMPOSER_SUBMIT_SECS:-120}
  case "$s" in ''|*[!0-9]*) s=120 ;; esac
  printf '%s' "$s"
}

jg_task_inbox_unchanged_composer_submit() {  # <state-dir> <task-id> <backend> <target> <label>
  local dir cap held hash seen_hash seen_at submitted now
  dir=$(jg_task_inbox_dir "$1" "$2")
  jg_task_is_lead "$1/$2.meta" || { printf 'wait'; return 0; }
  jg_backend_source "$3" || { printf 'wait'; return 0; }
  cap=$(jg_backend_capture "$3" "$4" "$JG_COMPOSER_CAPTURE_LINES" "$5" 2>/dev/null) || { printf 'wait'; return 0; }
  held=$(jg_composer_extract_selected_content styled=0 "$cap") || { printf 'wait'; return 0; }
  [ -n "$held" ] || { rm -f "$dir/.composer-seen" 2>/dev/null; printf 'wait'; return 0; }
  hash=$(printf '%s' "$held" | cksum | cut -d' ' -f1)
  now=$(date +%s)
  { IFS=$(printf '\t') read -r seen_hash seen_at submitted < "$dir/.composer-seen"; } 2>/dev/null || true
  case "${seen_at:-}" in ''|*[!0-9]*) seen_hash= ;; esac
  if [ "${seen_hash:-}" != "$hash" ]; then
    { printf '%s\t%s\t0\n' "$hash" "$now" > "$dir/.composer-seen"; } 2>/dev/null || true
    printf 'wait'
    return 0
  fi
  if [ "${submitted:-0}" = 1 ] || [ "$((now - seen_at))" -lt "$(jg_task_inbox_composer_submit_secs)" ]; then
    printf 'wait'
    return 0
  fi
  { printf '%s\t%s\t1\n' "$hash" "$seen_at" > "$dir/.composer-seen"; } 2>/dev/null || { printf 'wait'; return 0; }
  jg_backend_send_key "$3" "$4" Enter "$5" >/dev/null 2>&1 || { printf 'wait'; return 0; }
  sleep 0.5
  printf 'submitted'
}

jg_task_is_lead() {  # <meta-path>
  [ "$(jg_meta_get "$1" kind 2>/dev/null)" = squad_lead ]
}

jg_task_inbox_is_fire_and_forget() {  # <record-path>
  local rec=$1
  if [ ! -f "$rec" ]; then
    rec="${rec%/*}/handled/${rec##*/}"
    [ -f "$rec" ] || return 1
  fi
  awk '
    $0 == "--" { exit }
    $0 == "delivery=fire-and-forget" { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$rec"
}

# Oldest escalation-tracked unhandled record, or fail when none is due.
jg_task_inbox_oldest_unhandled() {  # <state-dir> <task-id>
  local dir best='' best_n=0 f n
  dir=$(jg_task_inbox_dir "$1" "$2")
  for f in "$dir"/*.msg; do
    [ -e "$f" ] || continue
    jg_task_inbox_is_fire_and_forget "$f" && continue
    n=$(jg_task_inbox_seq_of "${f##*/}") || continue
    if [ -z "$best" ] || [ "$n" -lt "$best_n" ]; then
      best=$f
      best_n=$n
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# Owe a fire-and-forget record its one retry ring (see the header). A newer
# mark replaces an older one: a ring names the whole inbox, not one record.
jg_task_inbox_mark_retry() {  # <state-dir> <task-id> <record-path>
  local dir
  dir=$(jg_task_inbox_dir "$1" "$2")
  { printf '%s\n' "${3##*/}" > "$dir/.retry-ring"; } 2>/dev/null
}

# Spend the retry mark after its ring, only while it still names that record:
# a newer mark written meanwhile is owed its own retry and survives. Fails only
# when the processed record's mark stays behind.
jg_task_inbox_clear_retry() {  # <state-dir> <task-id> <record-path>
  local dir
  dir=$(jg_task_inbox_dir "$1" "$2")
  [ "$(cat "$dir/.retry-ring" 2>/dev/null)" = "${3##*/}" ] || return 0
  rm -f "$dir/.retry-ring" 2>/dev/null
}

# The re-ring ladder decision for one task. Prints exactly one of:
#   quiet                     nothing due (healthy, within grace or spacing,
#                             or already escalated for the current oldest)
#   ring <record-path>        one doorbell re-ring is due
#   escalate <record-path> <count>   attempt budget spent; surface as stale
#   retry <record-path>       a fire-and-forget record's one retry ring is due
# An empty inbox also resets the ladder bookkeeping so the next message starts
# a fresh ladder.
jg_task_inbox_due_action() {  # <state-dir> <task-id>
  local dir oldest base now grace max ladder rec_base count last
  dir=$(jg_task_inbox_dir "$1" "$2")
  if ! oldest=$(jg_task_inbox_oldest_unhandled "$1" "$2"); then
    rm -f "$dir/.ring-state" "$dir/.escalated" "$dir/.busy-state" \
      "$dir/.busy-escalated" "$dir/.held-escalated" 2>/dev/null || true
    # The one retry ring exists only while config/wait-no-turns is present.
    # Absent, a mark is left untouched and the inbox stays quiet, as before.
    if [ -e "${JG_CONFIG_OVERRIDE:-${JG_HOME:-}/config}/wait-no-turns" ]; then
      base=$(cat "$dir/.retry-ring" 2>/dev/null || true)
      if ! jg_task_inbox_seq_of "$base" >/dev/null || [ ! -f "$dir/$base" ]; then
        rm -f "$dir/.retry-ring" 2>/dev/null || true
      elif [ "$(jg_path_age "$dir/.retry-ring")" -ge "$(jg_task_inbox_grace_secs)" ]; then
        printf 'retry %s' "$dir/$base"
        return 0
      fi
    fi
    printf 'quiet'
    return 0
  fi
  base=${oldest##*/}
  grace=$(jg_task_inbox_grace_secs)
  if [ "$(jg_path_age "$oldest")" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  count=0
  last=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$ladder
EOF
  if [ -n "$rec_base" ] && [ "$rec_base" != "$base" ]; then
    count=0
    last=0
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$(cat "$dir/.escalated" 2>/dev/null || true)" = "$base" ]; then
    printf 'quiet'
    return 0
  fi
  max=$(jg_task_inbox_ring_max)
  if [ "$count" -ge "$max" ]; then
    printf 'escalate %s %s' "$oldest" "$count"
    return 0
  fi
  now=$(date +%s)
  if [ "$((now - last))" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  printf 'ring %s' "$oldest"
}

# Advance the ladder after a delivery attempt. A failed ring or a composer-
# protected skip still consumes budget so neither an unreadable pane nor a
# permanently blocked composer can retry silently forever. A positively dead or
# missing endpoint never enters the ladder: the watcher escalates it directly.
# A concurrently removed inbox is a successful no-op; otherwise failure means
# the caller must surface the unwritable ladder while the record remains
# unhandled.
jg_task_inbox_record_ring() {  # <state-dir> <task-id> <record-path>
  local dir base ladder rec_base count last
  dir=$(jg_task_inbox_dir "$1" "$2")
  base=${3##*/}
  count=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$ladder
EOF
  [ "$rec_base" = "$base" ] || count=0
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ -d "$dir" ] || return 0
  "${BASH_SOURCE[0]%/*}/jg-machine-shadow.sh" task-inbox "$2:${base%.msg}" ring-counted || true  # shadow report of the move (jg-machine-shadow.sh)
  if ! { printf '%s\t%s\t%s\n' "$base" "$((count + 1))" "$(date +%s)" > "$dir/.ring-state"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}

# Mark the current oldest as escalated after its stale wake is durably queued,
# suppressing another wake on later polls. Wake-before-marker ordering favors
# at-least-once recovery: a crash or marker failure can cause a rare duplicate;
# stuck-operator-recovery owns the message from here.
jg_task_inbox_record_escalated() {  # <state-dir> <task-id> <record-path>
  local dir
  dir=$(jg_task_inbox_dir "$1" "$2")
  [ -d "$dir" ] || return 0
  if ! { printf '%s\n' "${3##*/}" > "$dir/.escalated"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}

# ---------------------------------------------------------------------------
# The steering-inbox ladder: ONE walk of one task's unread inbox. Two callers
# run it - the watcher's window loop (bin/jg-watch.sh) and the delivery tick
# (bin/jg-delivery-tick.sh, via jg_task_inbox_walk) - so a steer reaches its
# worker or its lead whatever either cycle does. It owns the order: the due
# action, the endpoint check, the busy deferral, the ring, and the stale row for
# a dead endpoint, a held composer, a stuck-busy pane or a spent budget.
#
# One ring at a time: the step holds <task>.inbox/.ladder.lock, and a caller
# that finds it held does nothing, so a watcher and a tick that meet on one
# inbox type one doorbell. The ring-state spacing then keeps the next attempt
# a grace away.
#
# A caller may name three hooks (function names, in these variables) for the
# parts that depend on where it runs; each has a default for a caller with no
# pane reader of its own:
#   JG_LADDER_BUSY <window> <task> <backend>   0 when the pane is a turn still running
#   JG_LADDER_LOG  <line>                      one line of the ladder's own log
#   JG_LADDER_WAKE <reason>                    after a stale row is queued (the
#                                              watcher ends its cycle on it)
# Returns 0, or 1 when a stale row or marker could not be written (the caller
# stops, as the watcher always did).
# ---------------------------------------------------------------------------
_jg_ladder_busy() {  # <window> <task> <backend>
  local w=$1 task=$2 backend=$3 tail40
  tail40=$(jg_backend_capture "$backend" "$w" 40 "jg-$task" 2>/dev/null || true)
  [ "$(jg_busy_classify_meta "$_JG_LADDER_STATE/$task.meta" "$task" "$_JG_LADDER_STATE" "$tail40" | cut -d' ' -f1)" = busy ]
}
_jg_ladder_log() { :; }
_jg_ladder_wake() { :; }

# True when this task's ladder must stay still: a parked home gets no doorbell
# (core/parked-homes), and a retry ring waits while the worker has a decision of
# its own open. The two readers load on the first use that needs them.
_jg_ladder_skip() {  # <state-dir> <task> [retry]
  # shellcheck source=/dev/null
  declare -F jg_parked_skip_meta >/dev/null || . "$_JG_TASK_INBOX_LIB_DIR/jg-parked-homes-lib.sh"
  jg_parked_skip_meta "$1/$2.meta" "$2" wake-doorbell && return 0
  if [ "${3:-}" = retry ]; then
    # shellcheck source=/dev/null
    declare -F status_own_open_decisions >/dev/null || . "$_JG_TASK_INBOX_LIB_DIR/jg-classify-lib.sh"
    [ -z "$(status_own_open_decisions "$1/$2.status")" ] || return 0
  fi
  return 1
}

_jg_ladder_defer_report() {  # <state> <task> <window> <record> <kind> <sentence>
  local state=$1 task=$2 w=$3 rec=$4 reason
  if [ ! -d "${rec%/*}" ] || [ ! -f "$rec" ]; then
    jg_task_inbox_due_action "$state" "$task" >/dev/null || true
    return 0
  fi
  reason="stale: $w (unread juggernaut instruction: $rec stays unhandled - $6; no doorbell was typed, and it lands as soon as that clears, so no interrupt is needed unless the worker is wedged)"
  jg_wake_append stale "$w" "$reason" || return 1
  if ! jg_task_inbox_record_deferral_reported "$state" "$task" "$rec" "$5"; then
    echo "error: stale wake was queued for $task but its deferral report marker could not be written" >&2
    return 1
  fi
  _JG_LADDER_WAKE_REASON=$reason
}

_jg_ladder_escalate_unavailable() {  # <state> <task> <window> <record>
  local state=$1 task=$2 w=$3 rec=$4 reason
  reason="stale: $w (unread juggernaut instruction: $rec is unhandled and the worker's agent has exited or its endpoint is missing, so the doorbell was not typed; recover the worker)"
  if [ ! -d "${rec%/*}" ] || [ ! -f "$rec" ]; then
    jg_task_inbox_due_action "$state" "$task" >/dev/null || true
    return 0
  fi
  jg_wake_append stale "$w" "$reason" || return 1
  if ! jg_task_inbox_record_escalated "$state" "$task" "$rec"; then
    echo "error: stale wake was queued for $task but its inbox escalation marker could not be written" >&2
    return 1
  fi
  _JG_LADDER_WAKE_REASON=$reason
}

jg_task_inbox_ladder() {  # <state-dir> <task> <window> <backend> <label>
  local state=$1 task=$2 dir lock rc=0
  dir=$(jg_task_inbox_dir "$state" "$task")
  [ -d "$dir" ] || return 0
  lock=$dir/.ladder.lock
  jg_lock_try_acquire "$lock" || return 0
  _JG_LADDER_STATE=$state
  _JG_LADDER_WAKE_REASON=
  _jg_ladder_step "$@" || rc=$?
  jg_lock_release "$lock"
  # The wake hook may end the caller's cycle, so it runs once the lock is free.
  [ -z "$_JG_LADDER_WAKE_REASON" ] || "${JG_LADDER_WAKE:-_jg_ladder_wake}" "$_JG_LADDER_WAKE_REASON"
  return "$rc"
}

_jg_ladder_step() {  # <state-dir> <task> <window> <backend> <label>
  local state=$1 task=$2 w=$3 backend=$4 label=$5 action verb rec count reason='' ring_rc agent_state decision
  local log=${JG_LADDER_LOG:-_jg_ladder_log} busy=${JG_LADDER_BUSY:-_jg_ladder_busy}
  _jg_ladder_skip "$state" "$task" && return 0
  action=$(jg_task_inbox_due_action "$state" "$task") || return 0
  verb=${action%% *}
  [ "$verb" != quiet ] || return 0
  if [ "$verb" = retry ] && _jg_ladder_skip "$state" "$task" retry; then
    return 0
  fi
  rec=${action#* }
  count=
  case "$verb" in
    escalate)
      count=${rec##* }
      rec=${rec% *}
      ;;
  esac
  agent_state=$(jg_backend_agent_state "$backend" "$w" 2>/dev/null || true)
  case "$agent_state" in
    dead|missing)
      if [ "$verb" = retry ]; then
        jg_task_inbox_clear_retry "$state" "$task" "$rec" || true
      else
        _jg_ladder_escalate_unavailable "$state" "$task" "$w" "$rec" || return 1
      fi
      return 0
      ;;
  esac
  if "$busy" "$w" "$task" "$backend"; then
    [ "$verb" != retry ] || return 0
    # The turn really is still running, so nothing may be typed at it. The
    # deferral only defers: it reports the unread instruction once and keeps the
    # message owed, so the ordinary ladder below rings the doorbell on the first
    # non-busy poll once the turn ends - no interrupt, no relaunch.
    decision=$(jg_task_inbox_defer "$state" "$task" "$rec")
    case "$decision" in
      quiet) return 0 ;;
      escalate)
        reason="stale: $w (steering-inbox busy bookkeeping unwritable: ${rec%/*}/.busy-state cannot be written while $rec stays unhandled; inspect the inbox directory)"
        verb=escalate
        ;;
      *)
        _jg_ladder_defer_report "$state" "$task" "$w" "$rec" busy \
          "stuck-busy after ${decision#report } consecutive busy-deferred due doorbells, with the pane reading busy for a turn still running" || return 1
        return 0
        ;;
    esac
  elif [ "$verb" != retry ] && ! jg_task_inbox_clear_busy "$state" "$task"; then
    reason="stale: $w (steering-inbox busy bookkeeping unwritable: ${rec%/*}/.busy-state cannot be reset after a non-busy check; inspect the inbox directory)"
    verb=escalate
  fi
  case "$verb" in
    ring)
      ring_rc=0
      jg_task_inbox_ring "$backend" "$w" "$rec" "$label" || ring_rc=$?
      if [ "$ring_rc" -eq 1 ] \
        && [ "$(jg_task_inbox_unchanged_composer_submit "$state" "$task" "$backend" "$w" "$label")" = submitted ]; then
        "$log" "steer-inbox lead composer text unchanged for $(jg_task_inbox_composer_submit_secs)s was submitted: $task ${rec##*/}"
        ring_rc=0
        jg_task_inbox_ring "$backend" "$w" "$rec" "$label" || ring_rc=$?
      fi
      if [ "$ring_rc" -eq 3 ]; then
        _jg_ladder_escalate_unavailable "$state" "$task" "$w" "$rec" || return 1
        return 0
      fi
      if [ "$ring_rc" -eq 1 ]; then
        # The composer provably holds other text, so the Enter was withheld on
        # purpose. That is a deferral, not a spent attempt: the record stays
        # owed and the one-keypress fix is reported at once instead of the
        # delivery budget being spent toward a silent give-up.
        if jg_task_inbox_deferral_reported "$state" "$task" "$rec" held; then
          "$log" "steer-inbox delivery held: $task ${rec##*/} (already reported)"
          return 0
        fi
        "$log" "steer-inbox delivery held: $task ${rec##*/}${JG_TASK_INBOX_RING_REASON:+ reason=$JG_TASK_INBOX_RING_REASON}"
        _jg_ladder_defer_report "$state" "$task" "$w" "$rec" held \
          "the worker's composer holds other pending text, so submitting the doorbell could submit that text - submit it with 'jg-send.sh $task --key Enter' or clear the composer" || return 1
        return 0
      fi
      if ! jg_task_inbox_record_ring "$state" "$task" "$rec"; then
        if [ ! -f "$rec" ]; then
          jg_task_inbox_due_action "$state" "$task" >/dev/null || true
          return 0
        fi
        if [ -d "${rec%/*}" ]; then
          reason="stale: $w (steering-inbox ladder bookkeeping unwritable: ${rec%/*}/.ring-state cannot be written while $rec stays unhandled; the doorbell cannot advance toward escalation - inspect the inbox directory)"
          jg_wake_append stale "$w" "$reason" || return 1
          _JG_LADDER_WAKE_REASON=$reason
        fi
      fi
      "$log" "steer-inbox delivery attempt: $task ${rec##*/} result=$ring_rc${JG_TASK_INBOX_RING_REASON:+ reason=$JG_TASK_INBOX_RING_REASON}"
      ;;
    retry)
      ring_rc=0
      jg_task_inbox_ring "$backend" "$w" "$rec" "$label" || ring_rc=$?
      if ! jg_task_inbox_clear_retry "$state" "$task" "$rec" && [ -f "$rec" ]; then
        reason="stale: $w (steering-inbox retry mark unremovable: ${rec%/*}/.retry-ring cannot be removed, so $rec would ring on every poll - inspect the inbox directory)"
        jg_wake_append stale "$w" "$reason" || return 1
        _JG_LADDER_WAKE_REASON=$reason
      fi
      "$log" "steer-inbox retry ring: $task ${rec##*/} result=$ring_rc${JG_TASK_INBOX_RING_REASON:+ reason=$JG_TASK_INBOX_RING_REASON}"
      ;;
    escalate)
      reason=${reason:-"stale: $w (unread juggernaut instruction: $rec still unhandled after $count doorbell delivery attempts with an idle pane; inspect the worker)"}
      if [ ! -d "${rec%/*}" ] || [ ! -f "$rec" ]; then
        jg_task_inbox_due_action "$state" "$task" >/dev/null || true
        return 0
      fi
      jg_wake_append stale "$w" "$reason" || return 1
      if ! jg_task_inbox_record_escalated "$state" "$task" "$rec"; then
        echo "error: stale wake was queued for $task but its inbox escalation marker could not be written" >&2
        return 1
      fi
      _JG_LADDER_WAKE_REASON=$reason
      ;;
  esac
}

# The tick's walk: every task with a recorded endpoint and an unread record in
# its inbox gets one ladder step, in one pass, with no watcher and no model.
# A task with no inbox record costs one glob.
jg_task_inbox_walk() {  # <state-dir>
  local state=$1 d task meta target rc=0
  for d in "$state"/*.inbox; do
    [ -d "$d" ] || continue
    compgen -G "$d/*.msg" >/dev/null || continue
    task=${d##*/}; task=${task%.inbox}
    meta=$state/$task.meta
    [ -f "$meta" ] || continue
    target=$(jg_backend_target_of_meta "$meta")
    [ -n "$target" ] || continue
    jg_task_inbox_ladder "$state" "$task" "$target" "$(jg_backend_of_meta "$meta")" "jg-$task" || rc=1
  done
  return "$rc"
}

# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_legacy_of() { printf "%s\n" "${1-}"; }
    jg_compat_legacy_product() { printf "%s\n" "${1-}"; }
    jg_compat_record_ok() { [ "${1-}" = "${2-}" ]; }
    jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d

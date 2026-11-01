#!/usr/bin/env bash
# jg-pending-reply-lib.sh - parent-owned squad_lead missed-report guards.
#
# When the main juggernaut delivers a reply-bearing marked from-juggernaut request
# to a squad_lead, this library records a durable parent-owned pending-reply
# expectation BEFORE delivery, embeds a privacy-safe correlation id in the
# outbound message, and later resolves that expectation only from a correlated
# line in the asked task's own parent status log, or a document it points to -
# never from transport success, chat content, unrelated status activity, or
# another task's line that echoes or quotes the token.
#
# Safety property (captain direction 2026-07-22): a squad_lead agent may ignore
# the marker and answer only in its visible conversation. The parent must notice
# the missing correlated report without scraping that conversation, send exactly
# one automatic recovery request asking for a repost through the parent channel
# (held back, when config/wait-no-turns is present, while the mate waits on its
# own open decision or blocker), and
# escalate once if the recovery turn also completes without a correlated
# report. Never loop, never repeatedly inject, never silently expire unresolved
# records, and never treat wrong-home or structured-home heuristics as
# acknowledgement. A same-basename restatement-copy of the mate home's
# state/<task_id>.status onto the parent channel is a repair of the
# JG_HOME-relative mixup, not acknowledgement of an arbitrary mate-home file.
#
# Record location (parent JG_HOME): one derived cache, rebuilt from the home's bus:
#   state/reply-state.tsv#<corr_id>
# One more durable input, owned by bin/jg-procevent-remote-reply.sh and read
# here: state/remote-replies/<task_id>.caught-up, the remote reply mirror's
# watermark (see the remote reply-channel freshness section below).
# Each waiter is a key=value block owned by this library. Schema:
#   schema=jg-pending-reply.v1
#   corr_id=                privacy-safe correlation token
#   task_id=                squad_lead task id in the parent home
#   parent_home=            absolute parent JG_HOME
#   parent_status=          absolute path of parent state/<task_id>.status
#   parent_status_scan_signature=
#   request_summary=        short sanitized summary (no secrets by design)
#   created_epoch=          when the expectation was created
#   delivered_epoch=        when the marked request was confirmed delivered
#                           (empty until delivery; delivery never resolves)
#   phase=                  awaiting_report | delivery_unknown | recovery_sending |
#                           recovery_sent | recovery_failed | recovery_unknown |
#                           escalated | resolved
#                           An escalated record with an empty delivered_epoch is
#                           a delivery-unknown escalation, not a missed report:
#                           its owner may still resend the same correlation, and
#                           jg_pending_reply_reset_known_undelivered returns it to
#                           awaiting_report for that resend (see the retryable
#                           undelivered escalation note below)
#   turn_seen_busy=         0|1 after delivery for the original request turn
#   request_turn_completed_epoch=
#   recovery_attempted_epoch=
#   recovery_sender_pid=
#   recovery_sender_identity=
#   recovery_sent_epoch=
#   recovery_delivery_outcome=
#   recovery_turn_seen_busy=
#   recovery_turn_completed_epoch=
#   escalated_epoch=
#   escalation_closed_epoch=
#                           when the durable status decision opened by that
#                           escalation was closed again (see the escalation
#                           lifecycle note below); empty until then
#   resolved_epoch=
#   resolved_via=           status | document | helper | empty
#   wrong_home_hits=        count of corr sightings under the squad_lead home
#   wrong_home_first_sighting= encoded path:line identity of the first sighting
#   wrong_home_sightings=   comma-separated encoded path:line identities
#   wrong_home_scan_signature=
#   grace_secs=             bounded grace before recovery, and before the
#                           missed-report escalation, are eligible - measured
#                           from the relevant turn's completion (request or
#                           recovery), never from delivery or send time
#
# Escalation lifecycle: an escalation is not just a message, it OPENS a durable
# keyed decision in the parent status log, and bin/jg-classify-lib.sh's fold is
# the one owner of what closes it. So this library owns both ends of that
# decision: jg_pending_reply_maybe_escalate opens it under a per-request key, and
# jg_pending_reply_close_escalation closes it once the record resolves. Resolving
# the record alone would leave the decision open forever, re-surfacing a settled
# request in every later OPEN DECISIONS fold.
# That per-request key lives in a namespace the fold reserves to this library, so
# no other writer into the same status stream - a local mate appending directly,
# or a remote mate's mirrored line - can take the key over or clear it; see the
# reserved-key rule in bin/jg-classify-lib.sh.
# The operator-facing close of that same keyed decision is still
# jg-send --resolve-key (bin/jg-send.sh header): it must speak the close note
# owned below (jg_pending_reply_resolved_note), because a bare answered: note is
# not a reserved-key transition and would leave the decision open.
#
# Retryable undelivered escalation: a delivery-unknown escalation reports that
# the request may never have reached the mate, so the request stays the owner's
# to resend under the same correlation (jg-send's JG_PENDING_REPLY_EXISTING_CORR
# contract; the remote enqueue deduplicates onto the same record). The resend
# resets the record to awaiting_report and leaves the published escalation
# decision open: a confirmed delivery does not settle the request, only a
# correlated report does. A later escalation reuses that key rather than
# opening a duplicate while the decision stays open, and only the ordinary
# resolve close closes it. Once that close is in the log, the next escalation
# of a record that already escalated and was reset is a new episode: it
# appends a new blocked line for the same key, even one identical to the
# first, and the fold opens the decision again. That reopen belongs to this
# escalation alone; status_event_recorded (bin/jg-classify-lib.sh) stays an
# idempotent retry check for every caller. A delivered record, whatever its
# phase, is never reset. Without this, a wake retried only through its owner
# (bin/jg-backlog-handoff.sh's receiver wake) stayed refused forever once the
# watcher escalated between the lost transport and the next resume.
#
# Sourced by bin/jg-send.sh, bin/jg-watch.sh, bin/jg-squad-lead-report.sh, and
# tests. No side effects on source. set -u / set -e safe.
#
# Tunables (env):
#   JG_PENDING_REPLY_GRACE_SECS   default 120; counted from the request turn's
#                                 completion for the recovery repost, and from
#                                 the recovery turn's completion for the
#                                 missed-report escalation - never from delivery
#   JG_PENDING_REPLY_SEND_HOOK    optional command template for recovery delivery
#                                 (tests); receives task_id and full message as args
#   JG_PENDING_REPLY_NOW          optional fixed epoch for deterministic tests

# This directive does double duty: it also binds _JG_PENDING_REPLY_LIB_DIR as
# the bin/ source prefix so the deliberately undirected lazy sources below
# still resolve for ShellCheck instead of warning SC1091.
# shellcheck source=bin/jg-marker-lib.sh
_JG_PENDING_REPLY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _JG_PENDING_REPLY_LIB_DIR="."
# shellcheck source=bin/jg-marker-lib.sh
. "$_JG_PENDING_REPLY_LIB_DIR/jg-marker-lib.sh"
# shellcheck source=bin/jg-backend.sh
. "$_JG_PENDING_REPLY_LIB_DIR/jg-backend.sh"
# Deliberately undirected: this library consumes no symbols from
# bin/jg-tmux-lib.sh, so following it under ShellCheck's external-source
# traversal would expand that graph for zero cross-file checks.
. "$_JG_PENDING_REPLY_LIB_DIR/jg-tmux-lib.sh"
# Deliberately undirected: bin/jg-classify-lib.sh is already expanded inside
# bin/jg-wake-lib.sh's single directed expansion below; a second directive
# here would re-expand the same transitive graph.
. "$_JG_PENDING_REPLY_LIB_DIR/jg-classify-lib.sh"
# Parked-home gate (core/parked-homes); the shim answers "not parked" without the feature.
# shellcheck source=bin/jg-parked-homes-lib.sh
. "$_JG_PENDING_REPLY_LIB_DIR/jg-parked-homes-lib.sh"

JG_PENDING_REPLY_SCHEMA='jg-pending-reply.v1'
JG_PENDING_REPLY_CORR_RE='corr=[A-Fa-f0-9]{16}'
JG_PENDING_REPLY_GRACE_DEFAULT=120

jg_pending_reply_now() {
  if [ -n "${JG_PENDING_REPLY_NOW:-}" ]; then
    printf '%s' "$JG_PENDING_REPLY_NOW"
    return 0
  fi
  date +%s
}

jg_pending_reply_grace_secs() {
  local g=${JG_PENDING_REPLY_GRACE_SECS:-$JG_PENDING_REPLY_GRACE_DEFAULT}
  case "$g" in
    ''|*[!0-9]*) g=$JG_PENDING_REPLY_GRACE_DEFAULT ;;
  esac
  printf '%s' "$g"
}

# --- one derived state cache, never a store of its own ----------------------
# A waiter's facts are events on the bus (bin/jg-reply-bus.sh). What the readers
# see is ONE derived file, state/reply-state.tsv: the record text blocks of every
# waiter still on the stream, separated by a blank line, in the writers' own keys
# and order. It is rebuilt from the stream alone by `jg_pending_reply_state_sync`,
# which is `jg-reply-bus.sh project` into a scratch directory, so the file is a
# function of the events and can never disagree with them.
#
# There is no per-waiter record file and no second format to keep in step: a block
# IS the record text the bus event carries.
#
# A waiter is addressed by a pointer, "<state>/reply-state.tsv#<corr_id>", so a
# caller that used to hold a record path holds the same identity and the read and
# write helpers keep the shape they always had.

# jg_pending_reply_cache <state-dir>: the cache file this home's waiters live in.
jg_pending_reply_cache() {  # <state-dir>
  printf '%s/reply-state.tsv' "$1"
}

# jg_pending_reply_path <state-dir> <corr_id>: the pointer a caller holds.
jg_pending_reply_path() {  # <state-dir> <corr_id>
  printf '%s#%s' "$(jg_pending_reply_cache "$1")" "$2"
}

# _jg_pending_reply_split <pointer>: file and corr of a pointer, or fail when it
# is not a pointer at all.
_jg_pending_reply_split() {  # <pointer>
  local pointer=$1
  JG_PENDING_REPLY_CACHE_FILE=${pointer%%#*}
  JG_PENDING_REPLY_CACHE_CORR=${pointer##*#}
  [ -n "$JG_PENDING_REPLY_CACHE_CORR" ] || return 1
  [ "$JG_PENDING_REPLY_CACHE_CORR" != "$pointer" ] || return 1
  return 0
}

# _jg_pending_reply_cache_lock <state-dir>: serialise the cache's read-modify-write.
# One lock for the whole file, not one per waiter: it orders file rewrites, and it
# is the only lock this path keeps.
_jg_pending_reply_cache_lock() {  # <state-dir>
  local lock
  lock="$(jg_pending_reply_cache "$1").lock"
  # Deliberately undirected: bin/jg-wake-lib.sh is expanded once at the resolve
  # site; a directed source here would re-expand its whole transitive graph.
  . "$_JG_PENDING_REPLY_LIB_DIR/jg-wake-lib.sh"
  jg_lock_acquire_wait "$lock"
}

_jg_pending_reply_cache_unlock() {  # <state-dir>
  jg_lock_release "$(jg_pending_reply_cache "$1").lock"
}

# _jg_pending_reply_block_awk <corr> <awk body>: run one block-scoped read over the
# cache. RS='' makes each blank-line-separated block one record.
_jg_pending_reply_block_awk() {  # <pointer> <awk-program> [awk-args...]
  local pointer=$1 program=$2 file
  shift 2
  # A pointer that names no waiter, or a cache that is not there, answers "no" and
  # never "yes": a caller must not read an absent block as a present one.
  _jg_pending_reply_split "$pointer" || return 1
  file=$JG_PENDING_REPLY_CACHE_FILE
  [ -f "$file" ] || return 1
  awk -v RS='' -v corr="$JG_PENDING_REPLY_CACHE_CORR" "$@" "$program" "$file" 2>/dev/null
}

# A block belongs to <corr> when one of its lines is exactly corr_id=<corr>. The
# test is shared by every read and write so they can never disagree about which
# block is the waiter.
# shellcheck disable=SC2016 # awk code, not shell expansion.
_JG_PENDING_REPLY_BLOCK_OF='{
  n = split($0, L, "\n"); mine = 0
  for (i = 1; i <= n; i++) if (L[i] == "corr_id=" corr) mine = 1
}'

# jg_pending_reply_get <pointer> <key>: the waiter's current value for one key.
jg_pending_reply_get() {  # <pointer> <key>
  local pointer=$1 key=$2
  _jg_pending_reply_block_awk "$pointer" "$_JG_PENDING_REPLY_BLOCK_OF"'
    mine {
      for (i = 1; i <= n; i++) {
        p = index(L[i], "=")
        if (p && substr(L[i], 1, p - 1) == key) v = substr(L[i], p + 1)
      }
      printf "%s", v
    }' -v key="$key" || true
}

# jg_pending_reply_exists <pointer>: 0 when the waiter has a block.
jg_pending_reply_exists() {  # <pointer>
  _jg_pending_reply_block_awk "$1" "$_JG_PENDING_REPLY_BLOCK_OF"'
    mine { found = 1; exit }
    END { exit !found }'
}

# jg_pending_reply_corrs <state-dir>: every waiter's corr_id, for the callers that
# used to list a directory of record files and now read the one cache.
jg_pending_reply_corrs() {  # <state-dir>
  local file
  file=$(jg_pending_reply_cache "$1")
  # A home that updated still holds its waiters on the bus and not yet in the
  # cache, so the first reader to ask rebuilds it: an upgrade drops no waiter.
  [ -f "$file" ] || jg_pending_reply_state_sync "$1"
  [ -f "$file" ] || return 0
  awk -v RS='' '{
    n = split($0, L, "\n")
    for (i = 1; i <= n; i++) if (index(L[i], "corr_id=") == 1) { print substr(L[i], 9); next }
  }' "$file" 2>/dev/null
}

# jg_pending_reply_record_text <pointer>: the waiter's block, exactly as the
# writers' record text, which is what the bus event carries and what the fold
# reads back.
jg_pending_reply_record_text() {  # <pointer>
  _jg_pending_reply_block_awk "$1" "$_JG_PENDING_REPLY_BLOCK_OF"'
    mine { printf "%s\n", $0; exit }'
}

# jg_pending_reply_block_write <state-dir> <text>: insert one record block. The
# blocks are kept in corr_id order, which is the order the fold writes them in, so
# a live create and a rebuild from the stream produce the same bytes.
jg_pending_reply_block_write() {  # <state-dir> <text>
  local state=$1 text=$2 file corr tmp
  file=$(jg_pending_reply_cache "$state")
  [ -n "$text" ] || return 1
  corr=$(printf '%s\n' "$text" | sed -n 's/^corr_id=//p' | head -1)
  [ -n "$corr" ] || return 1
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
  _jg_pending_reply_cache_lock "$state"
  tmp="$file.tmp.$$"
  if { [ -f "$file" ] && cat "$file"; } | awk -v RS='' -v corr="$corr" -v new="$text" '
    {
      n = split($0, L, "\n"); mine = ""
      for (i = 1; i <= n; i++) if (index(L[i], "corr_id=") == 1) mine = substr(L[i], 9)
      if (!placed && mine > corr) { printf "%s\n\n", new; placed = 1 }
      printf "%s\n\n", $0
    }
    END { if (!placed) printf "%s\n\n", new }' > "$tmp"; then
    chmod 600 "$tmp" 2>/dev/null || true
    if mv -f "$tmp" "$file"; then
      _jg_pending_reply_cache_unlock "$state"
      return 0
    fi
    rm -f -- "$tmp"
  else
    rm -f -- "$tmp"
  fi
  _jg_pending_reply_cache_unlock "$state"
  return 1
}

# jg_pending_reply_set <pointer> <key> <value>: one key of one waiter, then the
# event that carries it. The block is rewritten under the cache lock and published
# after the write, so the cache never shows a fact the stream does not hold.
jg_pending_reply_set() {  # <pointer> <key> <value>
  local pointer=$1 key=$2 value=$3 file corr dir tmp
  _jg_pending_reply_split "$pointer" || return 1
  file=$JG_PENDING_REPLY_CACHE_FILE
  corr=$JG_PENDING_REPLY_CACHE_CORR
  dir=$(dirname "$file")
  [ -f "$file" ] || return 1
  _jg_pending_reply_cache_lock "$dir"
  tmp="$file.tmp.$$"
  if ! awk -v RS='' -v corr="$corr" -v key="$key" -v value="$value" '
    {
      n = split($0, L, "\n"); mine = 0
      for (i = 1; i <= n; i++) if (L[i] == "corr_id=" corr) mine = 1
      if (!mine) { printf "%s\n\n", $0; next }
      seen = 1; hit = 0; o = ""
      for (i = 1; i <= n; i++) {
        p = index(L[i], "=")
        if (p && substr(L[i], 1, p - 1) == key) { L[i] = key "=" value; hit = 1 }
      }
      if (!hit) L[++n] = key "=" value
      for (i = 1; i <= n; i++) o = o L[i] "\n"
      printf "%s\n", o
    }
    END { exit !seen }' "$file" > "$tmp"; then
    rm -f -- "$tmp"
    _jg_pending_reply_cache_unlock "$dir"
    return 1
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  if ! mv -f "$tmp" "$file"; then
    rm -f -- "$tmp"
    _jg_pending_reply_cache_unlock "$dir"
    return 1
  fi
  _jg_pending_reply_cache_unlock "$dir"
  jg_pending_reply_publish_events "$pointer"
}

# jg_pending_reply_discard <pointer>: the waiter is gone. The discard event is the
# fact; the block leaves the cache with it.
jg_pending_reply_discard() {  # <pointer>
  local pointer=$1 file corr dir tmp
  _jg_pending_reply_split "$pointer" || return 0
  file=$JG_PENDING_REPLY_CACHE_FILE
  corr=$JG_PENDING_REPLY_CACHE_CORR
  dir=$(dirname "$file")
  jg_pending_reply_publish_events "$pointer" discard
  [ -f "$file" ] || return 0
  _jg_pending_reply_cache_lock "$dir"
  tmp="$file.tmp.$$"
  if awk -v RS='' -v corr="$corr" '
    {
      n = split($0, L, "\n")
      for (i = 1; i <= n; i++) if (L[i] == "corr_id=" corr) next
      printf "%s\n\n", $0
    }' "$file" > "$tmp"; then
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$file" || rm -f -- "$tmp"
  else
    rm -f -- "$tmp"
  fi
  _jg_pending_reply_cache_unlock "$dir"
  return 0
}

# jg_pending_reply_state_sync <state-dir>: rebuild the cache from the stream. This
# is the fold: the cache is a function of the events and nothing else, because the
# blocks are the same record text `jg-reply-bus.sh project` derives from the bus.
jg_pending_reply_state_sync() {  # <state-dir>
  local state=$1 tmp corr file
  file=$(jg_pending_reply_cache "$state")
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/jg-pending-reply-sync.XXXXXX" 2>/dev/null) || return 0
  # `project` makes its directory only once the bus has answered, so an
  # unreachable bus leaves the cache alone instead of blanking it.
  if "$_JG_PENDING_REPLY_LIB_DIR/jg-reply-bus.sh" --home "$(dirname "$state")" project "$tmp" >/dev/null 2>&1 \
    && [ -d "$tmp/pending-replies" ]; then
    if { for corr in "$tmp/pending-replies"/[0-9a-f]*; do
           [ -f "$corr" ] || continue
           printf '%s\n\n' "$(cat "$corr")"
         done; } > "$file.tmp.$$" 2>/dev/null; then
      chmod 600 "$file.tmp.$$" 2>/dev/null || true
      mv -f "$file.tmp.$$" "$file" || rm -f -- "$file.tmp.$$"
    else
      rm -f -- "$file.tmp.$$"
    fi
  fi
  rm -rf -- "$tmp"
  return 0
}

# --- the event stream -------------------------------------------------------
# The bus is the authority. Every writer below publishes the event that records
# what it just wrote, so a fact the cache shows is a fact the stream holds.
#
# A home whose bus is unreachable is never failed here: the publish skips and the
# cache still serves the guard.
jg_pending_reply_publish_events() {  # <pointer> [discard]
  local pointer=$1 flag="" bus at text tmp
  [ -n "$pointer" ] || return 0
  [ "${2:-}" = discard ] && flag=--discard
  bus="$_JG_PENDING_REPLY_LIB_DIR/jg-reply-bus.sh"
  [ -x "$bus" ] || return 0
  at=$(jg_pending_reply_now)
  if [ -n "$flag" ]; then
    "$bus" --home "$(dirname "${pointer%%#*}")/.." publish "$pointer" --at "$at" --discard >/dev/null 2>&1 || true
    return 0
  fi
  # The event carries the record text, so the publish path stays the one that
  # already validates and derives facts from a record.
  text=$(jg_pending_reply_record_text "$pointer")
  [ -n "$text" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/jg-pending-reply-publish.XXXXXX" 2>/dev/null) || return 0
  printf '%s\n' "$text" > "$tmp" || { rm -f -- "$tmp"; return 0; }
  "$bus" --home "$(dirname "${pointer%%#*}")/.." publish "$tmp" --at "$at" >/dev/null 2>&1 || true
  rm -f -- "$tmp"
  return 0
}

# Privacy-safe correlation id: 16 lowercase hex chars (64 bits of entropy).
jg_pending_reply_new_id() {
  local raw hex
  if command -v openssl >/dev/null 2>&1; then
    raw=$(openssl rand -hex 8 2>/dev/null || true)
  fi
  if [ -z "$raw" ]; then
    raw=$(printf '%s' "$$-$(date +%s%N 2>/dev/null || date +%s)-$RANDOM$RANDOM" | cksum 2>/dev/null | awk '{print $1}')
    hex=$(printf '%s' "$raw$RANDOM$RANDOM" | shasum -a 256 2>/dev/null | awk '{print $1}')
    raw=${hex:0:16}
  fi
  printf '%s' "$(printf '%s' "$raw" | tr 'A-F' 'a-f' | tr -cd 'a-f0-9' | cut -c1-16)"
}

jg_pending_reply_corr_token() {  # <corr_id> [out-var]
  if [ "$#" -ge 2 ]; then
    printf -v "$2" 'corr=%s' "$1"
  else
    printf 'corr=%s' "$1"
  fi
}

# Extract the first corr=<16hex> token from free text, or empty.
jg_pending_reply_extract_corr() {  # <text>
  local text=$1
  printf '%s' "$text" | grep -oE "$JG_PENDING_REPLY_CORR_RE" 2>/dev/null | head -1 | cut -d= -f2- | tr 'A-F' 'a-f' || true
}

# 0 if <text> carries the exact correlation token for <corr_id>, as a whole
# word: xcorr=<id> or corr=<id>ff is a different token, not this one.
jg_pending_reply_text_has_corr() {  # <text> <corr_id>
  local text=$1 corr=$2 token re
  jg_pending_reply_corr_token "$corr" token
  re="(^|[^[:alnum:]_])${token}([^[:alnum:]_]|\$)"
  [[ $text =~ $re ]]
}

# Sanitize a short request summary: single line, bounded, no control chars.
jg_pending_reply_summarize() {  # <text>
  local text=$1 cleaned
  cleaned=$(printf '%s' "$text" | tr '\t\r\n' '   ' | tr -cd '\11\12\15\40-\176' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  # Drop an already-present marker/corr prefix so the durable summary stays short.
  cleaned=${cleaned#"$JG_FROMFIRST_MARK"}
  cleaned=$(printf '%s' "$cleaned" | sed -E "s/^corr=[A-Fa-f0-9]{16}[[:space:]]*//")
  if [ "${#cleaned}" -gt 120 ]; then
    cleaned="${cleaned:0:117}..."
  fi
  printf '%s' "$cleaned"
}

jg_pending_reply_sighting_encode() {  # <path> <line-number>
  local path=$1 line_no=$2 encoded
  case "$line_no" in ''|*[!0-9]*) return 1 ;; esac
  encoded=$(printf '%s' "$path" | LC_ALL=C od -An -v -tx1 | tr -d ' \n') || return 1
  [ -n "$encoded" ] || return 1
  printf 'hex:%s:%s' "$encoded" "$line_no"
}

jg_pending_reply_sighting_display() {  # <encoded-sighting>
  local sighting=$1 body encoded line_no path='' pair byte escaped
  case "$sighting" in hex:*:*) ;; *) return 1 ;; esac
  body=${sighting#hex:}
  line_no=${body##*:}
  encoded=${body%:*}
  case "$line_no" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$encoded" ] && [ $(( ${#encoded} % 2 )) -eq 0 ] || return 1
  while [ -n "$encoded" ]; do
    pair=${encoded:0:2}
    case "$pair" in *[!0-9a-fA-F]*) return 1 ;; esac
    printf -v byte '%b' "\\x$pair"
    path=$path$byte
    encoded=${encoded:2}
  done
  printf -v escaped '%q' "$path"
  printf '%s:%s' "$escaped" "$line_no"
}

jg_pending_reply_corr_reusable() {  # <state-dir> <corr_id> <task_id>
  local state=$1 corr=$2 task_id=$3 rec phase delivered
  printf '%s' "$corr" | grep -Eq '^[A-Fa-f0-9]{16}$' || return 1
  rec=$(jg_pending_reply_path "$state" "$corr")
  jg_pending_reply_exists "$rec" || return 1
  [ "$(jg_pending_reply_get "$rec" task_id)" = "$task_id" ] || return 1
  phase=$(jg_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report|recovery_sending|recovery_sent) return 0 ;;
    delivery_unknown|escalated)
      # Undelivered only: a delivery-unknown escalation stays the owner's to
      # resend, while an escalation after delivery guards a missed report.
      delivered=$(jg_pending_reply_get "$rec" delivered_epoch)
      [ -z "$delivered" ]
      return $?
      ;;
  esac
  return 1
}

# jg_pending_reply_set <pointer> <key> <value>: one key of one waiter, then the
# event that carries it. The row is rewritten under the cache lock and published
# after the write, so the cache never shows a fact the stream does not hold.

# jg_pending_reply_discard <pointer>: the waiter is gone. The discard event is the
# fact; the row leaves the cache with it.

# Embed or replace a correlation token after the from-juggernaut marker.
# Idempotent for the same corr; replaces a different leading corr token.
# Result is assigned to <result-var>.
# Trailing newlines in the request body are preserved: never strip via bare
# $(...) on the body (command substitution removes trailing newlines).
jg_pending_reply_embed_corr() {  # <message> <corr_id> <result-var>
  local message=$1 corr=$2 result_var=$3 body token marked existing
  [ -n "$result_var" ] || return 2
  token=$(jg_pending_reply_corr_token "$corr")
  jg_message_mark_from_juggernaut "$message" marked
  body=${marked#"$JG_FROMFIRST_MARK"}
  # Strip a leading corr=<16hex> plus following blanks (space/tab only).
  existing=${body:0:21}
  case "$existing" in
    corr=[a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9])
      body=${body:21}
      while [ "${body# }" != "$body" ]; do body=${body# }; done
      while [ "${body#$'\t'}" != "$body" ]; do body=${body#$'\t'}; done
      ;;
  esac
  printf -v "$result_var" '%s' "${JG_FROMFIRST_MARK}${token} ${body}"
}

# Create a durable pending-reply expectation. Prints corr_id on success.
# Does not deliver anything. Fails if parent paths cannot be prepared.
jg_pending_reply_create() {  # <parent-home> <state-dir> <task_id> <request-text>
  local parent_home=$1 state=$2 task_id=$3 request_text=$4
  local file corr now summary status_path pointer text
  [ -n "$parent_home" ] && [ -n "$state" ] && [ -n "$task_id" ] || return 2
  file=$(jg_pending_reply_cache "$state")
  mkdir -p "$(dirname "$file")" || return 1
  chmod 700 "$(dirname "$file")" 2>/dev/null || true
  # A cache that is absent while the stream holds waiters is rebuilt first, so an
  # updating home never loses the waiters it already had.
  [ -f "$file" ] || jg_pending_reply_state_sync "$state"
  corr=$(jg_pending_reply_new_id)
  [ "${#corr}" -eq 16 ] || return 1
  pointer=$(jg_pending_reply_path "$state" "$corr")
  # Extremely unlikely collision; regenerate once.
  if jg_pending_reply_exists "$pointer"; then
    corr=$(jg_pending_reply_new_id)
    pointer=$(jg_pending_reply_path "$state" "$corr")
    jg_pending_reply_exists "$pointer" && return 1
  fi
  now=$(jg_pending_reply_now)
  summary=$(jg_pending_reply_summarize "$request_text")
  status_path="$state/${task_id}.status"
  # Prefer absolute parent_status when parent_home/state resolve.
  case "$status_path" in
    /*) ;;
    *) status_path="$(cd "$state" 2>/dev/null && pwd)/${task_id}.status" ;;
  esac
  case "$parent_home" in
    /*) ;;
    *) parent_home=$(cd "$parent_home" 2>/dev/null && pwd) || parent_home=$1 ;;
  esac
  printf -v text '%s\n' \
    "schema=$JG_PENDING_REPLY_SCHEMA" \
    "corr_id=$corr" \
    "task_id=$task_id" \
    "parent_home=$parent_home" \
    "parent_status=$status_path" \
    "parent_status_scan_signature=" \
    "request_summary=$summary" \
    "created_epoch=$now" \
    "delivered_epoch=" \
    "delivery_attempted_epoch=" \
    "phase=awaiting_report" \
    "turn_seen_busy=0" \
    "request_turn_completed_epoch=" \
    "recovery_attempted_epoch=" \
    "recovery_sender_pid=" \
    "recovery_sender_identity=" \
    "recovery_sent_epoch=" \
    "recovery_delivery_outcome=" \
    "recovery_turn_seen_busy=0" \
    "recovery_turn_completed_epoch=" \
    "escalated_epoch=" \
    "resolved_epoch=" \
    "resolved_via=" \
    "wrong_home_hits=0" \
    "wrong_home_first_sighting=" \
    "wrong_home_sightings=" \
    "wrong_home_scan_signature=" \
    "grace_secs=$(jg_pending_reply_grace_secs)"
  jg_pending_reply_block_write "$state" "$text" || return 1
  jg_pending_reply_publish_events "$pointer"
  printf '%s' "$corr"
}

# Mark delivery success for an existing expectation. Never resolves.
jg_pending_reply_mark_delivered() {  # <state-dir> <corr_id> [confirmed-epoch]
  local state=$1 corr=$2 confirmed_epoch=${3-} rec phase delivered now
  rec=$(jg_pending_reply_path "$state" "$corr")
  jg_pending_reply_exists "$rec" || return 1
  phase=$(jg_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report|delivery_unknown|recovery_sending|recovery_sent|escalated|resolved) ;;
    *) return 1 ;;
  esac
  delivered=$(jg_pending_reply_get "$rec" delivered_epoch)
  if [ -z "$delivered" ]; then
    now=${confirmed_epoch:-$(jg_pending_reply_now)}
    jg_pending_reply_set "$rec" delivered_epoch "$now" || return 1
  fi
  if [ "$phase" = delivery_unknown ]; then
    jg_pending_reply_set "$rec" phase awaiting_report || return 1
  fi
  return 0
}

# --- delivery, as one record fact -------------------------------------------
# A delivery attempt, its confirmation and its unknown aging used to live in
# state/pending-replies/.delivery-confirmed-<corr>: a second file per waiter, its
# own writes, and a reconciliation ladder that aged an attempt into an unknown
# delivery. The attempt is the record's own `delivery_attempted_epoch` now, so the
# bus event carries it and the engine decides the unknown delivery from the same
# fact - nothing here reconciles anything.
jg_pending_reply_mark_delivery_attempted() {  # <state-dir> <corr_id> [epoch]
  local state=$1 corr=$2 rec delivered attempted now
  rec=$(jg_pending_reply_path "$state" "$corr")
  jg_pending_reply_exists "$rec" || return 1
  delivered=$(jg_pending_reply_get "$rec" delivered_epoch)
  [ -z "$delivered" ] || return 0
  attempted=$(jg_pending_reply_get "$rec" delivery_attempted_epoch)
  [ -z "$attempted" ] || return 0
  now=${3:-$(jg_pending_reply_now)}
  jg_pending_reply_set "$rec" delivery_attempted_epoch "$now"
}

jg_pending_reply_clear_delivery_attempt() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec attempted
  rec=$(jg_pending_reply_path "$state" "$corr")
  jg_pending_reply_exists "$rec" || return 1
  attempted=$(jg_pending_reply_get "$rec" delivery_attempted_epoch)
  [ -n "$attempted" ] || return 0
  jg_pending_reply_set "$rec" delivery_attempted_epoch ""
}

# A confirmed delivery: the record carries the confirmation and no attempt is left
# to age. Never resolves.
jg_pending_reply_confirm_delivery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 now
  jg_pending_reply_mark_delivered "$state" "$corr" || return 1
  now=$(jg_pending_reply_get "$(jg_pending_reply_path "$state" "$corr")" delivered_epoch)
  jg_pending_reply_clear_delivery_attempt "$state" "$corr" || return $?
  [ -n "$now" ] || return 1
  return 0
}

# Preserve an expectation when a remote transport disconnect makes delivery
# completion unknowable. This never resolves or retries the request; it moves
# the existing prepared record to the owner's explicit unknown-delivery path.
jg_pending_reply_mark_delivery_unknown() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec phase
  rec=$(jg_pending_reply_path "$state" "$corr")
  jg_pending_reply_exists "$rec" || return 1
  phase=$(jg_pending_reply_get "$rec" phase)
  case "$phase" in awaiting_report|delivery_unknown) ;;
    *) return 1 ;;
  esac
  jg_pending_reply_set "$rec" phase delivery_unknown
}

# True when a delivery was attempted and never confirmed: what a resend must know
# before it may reuse this correlation.
jg_pending_reply_delivery_attempt_unresolved() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec delivered attempted
  rec=$(jg_pending_reply_path "$state" "$corr")
  jg_pending_reply_exists "$rec" || return 1
  delivered=$(jg_pending_reply_get "$rec" delivered_epoch)
  [ -z "$delivered" ] || return 1
  attempted=$(jg_pending_reply_get "$rec" delivery_attempted_epoch)
  [ -n "$attempted" ]
}

# A definitive backend rejection, or an owner's idempotent remote resend, makes
# the existing correlation retryable again: the attempt is dropped and the waiter
# returns to awaiting_report. A confirmed delivery can never be reset.
jg_pending_reply_reset_known_undelivered() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec delivered phase attempted
  rec=$(jg_pending_reply_path "$state" "$corr")
  jg_pending_reply_exists "$rec" || return 1
  delivered=$(jg_pending_reply_get "$rec" delivered_epoch)
  [ -z "$delivered" ] || return 1
  phase=$(jg_pending_reply_get "$rec" phase)
  case "$phase" in awaiting_report|delivery_unknown|escalated) ;; *) return 1 ;; esac
  attempted=$(jg_pending_reply_get "$rec" delivery_attempted_epoch)
  [ -n "$attempted" ] || { [ "$phase" = awaiting_report ]; return $?; }
  jg_pending_reply_clear_delivery_attempt "$state" "$corr" || return 1
  [ "$phase" = awaiting_report ] \
    || jg_pending_reply_set "$rec" phase awaiting_report || return 1
  return 0
}

# Drop an undelivered expectation after a failed send so transport failure does
# not masquerade as a missed report later.
jg_pending_reply_discard_undelivered() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec delivered
  rec=$(jg_pending_reply_path "$state" "$corr")
  jg_pending_reply_exists "$rec" || return 0
  delivered=$(jg_pending_reply_get "$rec" delivered_epoch)
  [ -z "$delivered" ] || return 1
  jg_pending_reply_discard "$rec"
}

# 0 if a status line is a correlated acknowledgement for <corr_id>.
# Accepts short status replies and status lines that point at a document.
# Unrelated verbs without the token never match. Stale/wrong corr never match.
# The parent's own pending-reply-missed escalation line must not self-resolve:
# it names the request with pending-reply-id= rather than corr=.
jg_pending_reply_line_resolves() {  # <line> <corr_id>
  local line=$1 corr=$2
  [ -n "$line" ] && [ -n "$corr" ] || return 1
  case "$line" in
    *pending-reply-missed*) return 1 ;;
  esac
  jg_pending_reply_text_has_corr "$line" "$corr"
}

# Scan a status file for a correlated resolve. Prints the matching line or empty.
jg_pending_reply_find_resolve_line() {  # <status-file> <corr_id>
  local status_file=$1 corr=$2 line
  [ -f "$status_file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if jg_pending_reply_line_resolves "$line" "$corr"; then
      printf '%s' "$line"
      return 0
    fi
  done < "$status_file"
  return 0
}

jg_pending_reply_file_signature() {  # <path>
  local path=$1
  [ -f "$path" ] || { printf 'missing'; return 0; }
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    LC_ALL=C /usr/bin/stat -f '%d:%i:%z:%m:%c' "$path" 2>/dev/null || printf 'unreadable'
  else
    LC_ALL=C stat -c '%d:%i:%s:%Y:%Z' "$path" 2>/dev/null || printf 'unreadable'
  fi
}

jg_pending_reply_status_set_signature() {  # <status-dir>
  local status_dir=$1 status_file signature
  {
    for status_file in "$status_dir"/*.status; do
      [ -f "$status_file" ] || continue
      signature=$(jg_pending_reply_file_signature "$status_file")
      printf '%s:%s:%s\n' "${#status_file}" "$status_file" "$signature"
    done
  } | cksum 2>/dev/null | awk '{printf "%s-%s", $1, $2}'
}

# Classify how a resolving line acknowledged the request.
jg_pending_reply_resolve_via_of_line() {  # <line>
  local line=$1
  case "$line" in
    *data/*report*|*report.md*|*document*|*pointer*)
      printf 'document'
      ;;
    *via-helper*|*jg-squad-lead-report*)
      printf 'helper'
      ;;
    *)
      printf 'status'
      ;;
  esac
}

# Idempotently resolve an expectation from a correlated parent report.
# Returns 0 when the record is resolved after the call (already or newly).
# There is no per-correlation lock any more: one acting tick per home is the only
# writer of these records, and the reply wins over any escalation by the order
# this function runs in.
jg_pending_reply_try_resolve() {  # <state-dir> <corr_id> [status-file-override]
  local state=$1 corr=$2 status_override=${3-}
  local rec phase delivered attempted status_file line via now
  rec=$(jg_pending_reply_path "$state" "$corr")
  jg_pending_reply_exists "$rec" || return 1
  phase=$(jg_pending_reply_get "$rec" phase)
  if [ "$phase" = resolved ]; then
    jg_pending_reply_close_escalation "$state" "$corr" || true
    return 0
  fi
  delivered=$(jg_pending_reply_get "$rec" delivered_epoch)
  if [ -z "$delivered" ]; then
    # A reply can land before the transport confirms the delivery, but only once
    # a delivery was attempted: nothing else could have carried the request.
    attempted=$(jg_pending_reply_get "$rec" delivery_attempted_epoch)
    [ -n "$attempted" ] || return 1
  fi
  status_file=$(jg_pending_reply_get "$rec" parent_status)
  # Only the asked task's own status log answers its request: another mate's
  # line echoing or quoting this corr= token must leave the request open.
  if [ -n "$status_override" ]; then
    [ "$status_override" -ef "$status_file" ] || return 1
    status_file=$status_override
  fi
  line=$(jg_pending_reply_find_resolve_line "$status_file" "$corr")
  [ -n "$line" ] || return 1
  via=$(jg_pending_reply_resolve_via_of_line "$line")
  now=$(jg_pending_reply_now)
  jg_pending_reply_set "$rec" phase resolved || return 1
  if [ -z "$delivered" ]; then
    jg_pending_reply_mark_delivered "$state" "$corr" "$now" || return 1
    jg_pending_reply_clear_delivery_attempt "$state" "$corr" || true
  fi
  jg_pending_reply_set "$rec" resolved_epoch "$now" || return 1
  jg_pending_reply_set "$rec" resolved_via "$via" || return 1
  # The record is resolved either way; a failed close stays retryable from the
  # acting tick rather than turning a settled request back into a failure.
  jg_pending_reply_close_escalation "$state" "$corr" || true
  return 0
}

jg_pending_reply_observe_busy() {  # <state-dir> <corr_id> <busy_state>
  local state=$1 corr=$2 busy_state=$3
  local rec phase delivered now seen completed field_seen field_completed
  rec=$(jg_pending_reply_path "$state" "$corr")
  jg_pending_reply_exists "$rec" || return 1
  phase=$(jg_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report|recovery_sent) ;;
    *) return 0 ;;
  esac
  delivered=$(jg_pending_reply_get "$rec" delivered_epoch)
  [ -n "$delivered" ] || return 0
  if [ "$phase" = awaiting_report ]; then
    field_seen=turn_seen_busy
    field_completed=request_turn_completed_epoch
  else
    field_seen=recovery_turn_seen_busy
    field_completed=recovery_turn_completed_epoch
  fi
  seen=$(jg_pending_reply_get "$rec" "$field_seen")
  completed=$(jg_pending_reply_get "$rec" "$field_completed")
  case "$busy_state" in
    busy)
      if [ "$seen" != 1 ]; then
        jg_pending_reply_set "$rec" "$field_seen" 1 || return 1
      fi
      ;;
    idle)
      if [ -z "$completed" ]; then
        # Prefer a busy->idle transition. Also accept a pure idle after delivery
        # when the first observation already missed the busy window (fast turns).
        if [ "$seen" = 1 ] || [ "$seen" = 0 ]; then
          now=$(jg_pending_reply_now)
          jg_pending_reply_set "$rec" "$field_completed" "$now" || return 1
        fi
      fi
      ;;
    unknown)
      # No independent proof; leave completion unset.
      ;;
    *)
      return 2
      ;;
  esac
  return 0
}

jg_pending_reply_fallback_idle_eligible() {  # <record-path>
  local rec=$1 phase start seen grace now age
  phase=$(jg_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report)
      start=$(jg_pending_reply_get "$rec" delivered_epoch)
      seen=$(jg_pending_reply_get "$rec" turn_seen_busy)
      ;;
    recovery_sent)
      start=$(jg_pending_reply_get "$rec" recovery_sent_epoch)
      seen=$(jg_pending_reply_get "$rec" recovery_turn_seen_busy)
      ;;
    *) return 1 ;;
  esac
  [ "$seen" = 1 ] && return 0
  grace=$(jg_pending_reply_get "$rec" grace_secs)
  case "$start" in ''|*[!0-9]*) return 1 ;; esac
  case "$grace" in ''|*[!0-9]*) grace=$(jg_pending_reply_grace_secs) ;; esac
  now=$(jg_pending_reply_now)
  age=$((now - start))
  [ "$age" -ge "$grace" ]
}

# jg_pending_reply_backend_observation: one busy/idle observation of a
# SQUAD_LEAD endpoint, without ever reading its conversation.
#
# Deliberately NOT the semantic busy-state contract (bin/jg-busy-lib.sh).
# That contract covers ordinary task workers, whose turn lifecycle juggernaut
# wires at spawn; a squad_lead is wired only on Pi, for the wake-stall ring,
# because an idle squad_lead pane is healthy and it runs no supervised turn
# sequence of its own. This
# observation exists only to notice a busy-then-idle transition around one
# delivered request, so it is a delivery-confirmation signal in the same
# category as the submit acknowledgement matcher in bin/jg-composer-lib.sh - never task
# state, and never a source consumers can confuse with semantic state.
#
# It stays harness-scoped (jg_busy_lines_match with the recorded harness, no
# global OR of every vendor signature), so one harness's output cannot make
# another read busy, and a weak rendered idle degrades to `fallback-idle`,
# which the caller accepts as idle only after its grace window.
jg_pending_reply_backend_observation() {  # <backend> <target> [expected-label] [harness]
  local backend=$1 target=$2 expected_label=${3-} harness=${4-} native tail40
  native=$(jg_backend_busy_state "$backend" "$target" 2>/dev/null || printf 'unknown')
  case "$native" in
    busy|idle) printf '%s' "$native"; return 0 ;;
  esac
  tail40=$(jg_backend_capture "$backend" "$target" 40 "$expected_label" 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  if printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | jg_busy_lines_match "$harness"; then
    printf 'busy'
  else
    printf 'fallback-idle'
  fi
}

jg_pending_reply_busy_state_from_observation() {  # <record-path> <observation>
  local rec=$1 observation=$2
  case "$observation" in
    busy|idle|unknown) printf '%s' "$observation" ;;
    fallback-idle)
      if jg_pending_reply_fallback_idle_eligible "$rec"; then
        printf 'idle'
      else
        printf 'unknown'
      fi
      ;;
    *) printf 'unknown' ;;
  esac
}

# Explicit turn-completion proof (for tests and turn-end backends that surface
# a completion event without a busy/idle pair).
jg_pending_reply_mark_turn_completed() {  # <state-dir> <corr_id> [which: request|recovery]
  local state=$1 corr=$2 which=${3:-request}
  local rec phase field now
  rec=$(jg_pending_reply_path "$state" "$corr")
  jg_pending_reply_exists "$rec" || return 1
  phase=$(jg_pending_reply_get "$rec" phase)
  case "$which" in
    request) field=request_turn_completed_epoch ;;
    recovery) field=recovery_turn_completed_epoch ;;
    *) return 2 ;;
  esac
  now=$(jg_pending_reply_now)
  jg_pending_reply_set "$rec" "$field" "$now" || return 1
  # Keep phase consistent with which turn completed.
  if [ "$which" = recovery ] && [ "$phase" = awaiting_report ]; then
    : # recovery completion only meaningful after recovery_sent
  fi
  return 0
}

# --- remote reply-channel freshness -----------------------------------------
#
# A LOCAL squad_lead appends its report straight into the parent's
# state/<id>.status, so an absent correlated line there is immediate evidence
# that no report was written. A REMOTE mate's reports reach that same file only
# through the asynchronous mirror in bin/jg-procevent-remote-reply.sh, so the
# same absence proves nothing until that mirror has actually been read past the
# turn that should have produced the report. Without this distinction the guard
# nags a REPOST REQUIRED for a reply the mate did write and the parent simply
# had not received yet - the common case, because the mirror's poll window is
# comparable to the recovery grace.
#
# The mirror therefore publishes one watermark: the epoch at which it last knew
# it had read the remote log through its end. Only that adapter writes it (it
# owns the channel), and only this library reads it. A channel that is behind,
# unarmed, or broken simply never advances the watermark, so the request stays
# durably open and un-nagged; the mirror escalates its own continuity failures.
jg_pending_reply_remote_channel_watermark_path() {  # <state-dir> <task_id>
  printf '%s/remote-replies/%s.caught-up' "$1" "$2"
}

# Record that the mirrored remote reply log for <task_id> was read through its
# end at <epoch> (default now). Called only by the remote reply adapter.
jg_pending_reply_note_remote_channel_caught_up() {  # <state-dir> <task_id> [epoch]
  local state=$1 task_id=$2 epoch=${3-} path dir tmp
  [ -n "$state" ] && [ -n "$task_id" ] || return 2
  case "$epoch" in ''|*[!0-9]*) epoch=$(jg_pending_reply_now) ;; esac
  path=$(jg_pending_reply_remote_channel_watermark_path "$state" "$task_id")
  dir=$(dirname "$path")
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  [ ! -L "$path" ] || return 1
  tmp="$dir/.caught-up.$task_id.$$"
  printf 'caught_up_epoch=%s\n' "$epoch" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$path"
}

# Print the watermark epoch, or nothing when the channel never reported itself
# caught up. Never invents a value.
jg_pending_reply_remote_channel_epoch() {  # <state-dir> <task_id>
  local path epoch
  path=$(jg_pending_reply_remote_channel_watermark_path "$1" "$2")
  [ -f "$path" ] && [ ! -L "$path" ] || return 0
  epoch=$(sed -n 's/^caught_up_epoch=//p' "$path" 2>/dev/null | head -1)
  case "$epoch" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$epoch"
}

# 0 when <task_id> is a squad_lead whose reports cross a machine boundary.
jg_pending_reply_target_is_remote() {  # <state-dir> <task_id>
  local meta="$1/$2.meta"
  [ -f "$meta" ] || return 1
  [ -n "$(jg_meta_get "$meta" remote_host)" ]
}

# 0 when "no correlated report in the parent status log" is admissible evidence
# that the mate never reported: always for a local target, and for a remote one
# only once the mirror has been read through its end at or after <since-epoch>.
jg_pending_reply_missing_report_is_evidence() {  # <state-dir> <task_id> <since-epoch>
  local state=$1 task_id=$2 since=$3 caught
  jg_pending_reply_target_is_remote "$state" "$task_id" || return 0
  case "$since" in ''|*[!0-9]*) return 1 ;; esac
  caught=$(jg_pending_reply_remote_channel_epoch "$state" "$task_id")
  [ -n "$caught" ] || return 1
  [ "$caught" -ge "$since" ]
}

# Build the one automatic recovery message for a pending record.
jg_pending_reply_recovery_message() {  # <record-path>
  local rec=$1 corr summary token msg
  corr=$(jg_pending_reply_get "$rec" corr_id)
  summary=$(jg_pending_reply_get "$rec" request_summary)
  token=$(jg_pending_reply_corr_token "$corr")
  msg="REPOST REQUIRED: previous marked request had no correlated parent report. Reply on the parent status channel including ${token}. Original request: ${summary}"
  jg_pending_reply_embed_corr "$msg" "$corr" msg
  printf '%s' "$msg"
}

# Deliver the recovery message once. Caller must hold phase awaiting_report with
# turn completed and grace elapsed. Uses JG_PENDING_REPLY_SEND_HOOK when set
# (tests), otherwise invokes jg-send with JG_PENDING_REPLY_EXISTING_CORR so a
# second expectation is not created.
jg_pending_reply_send_recovery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2
  local rec phase completed delivered attempted grace now age task_id msg parent_home send_status=0
  local sender_pid sender_identity status_file
  rec=$(jg_pending_reply_path "$state" "$corr")
  jg_pending_reply_exists "$rec" || return 1
  phase=$(jg_pending_reply_get "$rec" phase)
  [ "$phase" = awaiting_report ] || return 1
  attempted=$(jg_pending_reply_get "$rec" recovery_attempted_epoch)
  if [ -n "$attempted" ]; then
    jg_pending_reply_reconcile_recovery "$state" "$corr" || true
    return 1
  fi
  completed=$(jg_pending_reply_get "$rec" request_turn_completed_epoch)
  [ -n "$completed" ] || return 1
  delivered=$(jg_pending_reply_get "$rec" delivered_epoch)
  [ -n "$delivered" ] || return 1
  grace=$(jg_pending_reply_get "$rec" grace_secs)
  case "$grace" in ''|*[!0-9]*) grace=$(jg_pending_reply_grace_secs) ;; esac
  now=$(jg_pending_reply_now)
  # Grace runs from the request turn's completion, not from delivery: delivery
  # only proves the request arrived, while the turn's completion is the
  # earliest moment a correlated report could exist to race against.
  age=$((now - completed))
  [ "$age" -ge "$grace" ] || return 1
  task_id=$(jg_pending_reply_get "$rec" task_id)
  # A remote mate's report may exist and simply not have been mirrored yet.
  jg_pending_reply_missing_report_is_evidence "$state" "$task_id" "$completed" || return 1
  # config/wait-no-turns: a mate waiting on its own open decision or blocker
  # is never poked. The recovery stays unattempted until the answer lands.
  if [ -e "${JG_CONFIG_OVERRIDE:-${JG_HOME:-}/config}/wait-no-turns" ]; then
    [ -z "$(status_own_open_decisions "$state/$task_id.status")" ] || return 1
  fi
  status_file=$(jg_pending_reply_get "$rec" parent_status)
  parent_home=$(jg_pending_reply_get "$rec" parent_home)
  msg=$(jg_pending_reply_recovery_message "$rec")
  sender_pid=${BASHPID:-$$}
  sender_identity=$(jg_pending_reply_pid_identity "$sender_pid") || return 1
  # One fresh, uncached read immediately before firing: a correlated report that
  # landed in the meantime must never be overwritten by the repost. The phase is
  # re-read after the resolve attempt, whatever it returned: a resolve that failed
  # on a later field write has still committed resolved.
  if jg_pending_reply_try_resolve "$state" "$corr" "$status_file" \
    || [ "$(jg_pending_reply_get "$rec" phase)" != awaiting_report ] \
    || ! jg_pending_reply_set "$rec" recovery_sender_pid "$sender_pid" \
    || ! jg_pending_reply_set "$rec" recovery_sender_identity "$sender_identity" \
    || ! jg_pending_reply_set "$rec" recovery_attempted_epoch "$now" \
    || ! jg_pending_reply_set "$rec" phase recovery_sending; then
    return 1
  fi
  if [ -n "${JG_PENDING_REPLY_SEND_HOOK:-}" ]; then
    # Hook receives: task_id message
    # shellcheck disable=SC2086
    if ! eval "$JG_PENDING_REPLY_SEND_HOOK" "$(printf '%q' "$task_id")" "$(printf '%q' "$msg")"; then
      send_status=1
    fi
  else
    if [ -z "$parent_home" ] || [ ! -d "$parent_home" ]; then
      send_status=1
    elif ! env JG_HOME="$parent_home" JG_PENDING_REPLY_EXISTING_CORR="$corr" \
      "$_JG_PENDING_REPLY_LIB_DIR/jg-send.sh" "$task_id" "$msg"; then
      send_status=1
    fi
  fi
  if [ "$send_status" = 0 ]; then
    jg_pending_reply_finish_recovery "$state" "$corr" confirmed
    return $?
  fi
  jg_pending_reply_finish_recovery "$state" "$corr" failed || return 1
  return 1
}

jg_pending_reply_pid_identity() {  # <pid>
  local pid=$1 identity
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  identity=$(COLUMNS=10000 LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$identity" ] || return 1
  printf '%s' "$identity"
}

jg_pending_reply_sender_alive() {  # <record-path>
  local rec=$1 pid expected actual
  pid=$(jg_pending_reply_get "$rec" recovery_sender_pid)
  expected=$(jg_pending_reply_get "$rec" recovery_sender_identity)
  [ -n "$expected" ] || return 1
  actual=$(jg_pending_reply_pid_identity "$pid") || return 1
  [ "$actual" = "$expected" ]
}

jg_pending_reply_finish_recovery() {  # <state-dir> <corr_id> <confirmed|failed>
  local state=$1 corr=$2 outcome=$3 rec phase now sent
  rec=$(jg_pending_reply_path "$state" "$corr")
  jg_pending_reply_exists "$rec" || return 1
  phase=$(jg_pending_reply_get "$rec" phase)
  [ "$phase" = recovery_sending ] || return 1
  jg_pending_reply_set "$rec" recovery_delivery_outcome "$outcome" || return 1
  if [ "$outcome" = confirmed ]; then
    sent=$(jg_pending_reply_get "$rec" recovery_sent_epoch)
    if [ -z "$sent" ]; then
      now=$(jg_pending_reply_now)
      jg_pending_reply_set "$rec" recovery_sent_epoch "$now" || return 1
    fi
    jg_pending_reply_set "$rec" recovery_turn_seen_busy 0 || return 1
    jg_pending_reply_set "$rec" recovery_turn_completed_epoch "" || return 1
    jg_pending_reply_set "$rec" phase recovery_sent || return 1
  else
    [ "$outcome" = failed ] || return 1
    jg_pending_reply_set "$rec" phase recovery_failed || return 1
  fi
}

jg_pending_reply_reconcile_recovery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec phase attempted outcome
  rec=$(jg_pending_reply_path "$state" "$corr")
  jg_pending_reply_exists "$rec" || return 1
  phase=$(jg_pending_reply_get "$rec" phase)
  case "$phase" in awaiting_report|recovery_sending) ;; *) return 1 ;; esac
  attempted=$(jg_pending_reply_get "$rec" recovery_attempted_epoch)
  [ -n "$attempted" ] || return 1
  case "$attempted" in *[!0-9]*) return 1 ;; esac
  outcome=$(jg_pending_reply_get "$rec" recovery_delivery_outcome)
  case "$outcome" in
    confirmed) jg_pending_reply_finish_recovery "$state" "$corr" confirmed; return $? ;;
    failed) jg_pending_reply_finish_recovery "$state" "$corr" failed; return $? ;;
    unknown)
      jg_pending_reply_set "$rec" phase recovery_unknown || return 1
      return 0
      ;;
  esac
  jg_pending_reply_sender_alive "$rec" && return 1
  jg_pending_reply_set "$rec" recovery_delivery_outcome unknown || return 1
  jg_pending_reply_set "$rec" phase recovery_unknown || return 1
}

# The decision key an escalation for <corr_id> opens in the parent status log.
# Per-request rather than the bare default key, so one request's escalation
# neither masks nor is masked by an unrelated decision on the same task.
jg_pending_reply_escalation_key() {  # <corr_id>
  printf 'pending-reply-%s' "$1"
}

# Close-note body the reserved-key fold accepts as this library's resolution.
# The fold's guard (bin/jg-classify-lib.sh _jg_decision_key_transition_allowed)
# requires the note to begin with this namespace's vocabulary token; this is
# that token plus the stable task/id/via fields both the record close and the
# operator --resolve-key path write. Optional <extra> is appended after a space.
jg_pending_reply_resolved_note() {  # <task-id> <corr_id> <via> [extra]
  printf 'pending-reply-resolved: task=%s pending-reply-id=%s via=%s' "$1" "$2" "$3"
  if [ -n "${4:-}" ]; then
    printf ' %s' "$4"
  fi
}

# 0 and prints the close note when <key> is in this library's reserved
# namespace (pending-reply-<corr>). jg-send --resolve-key uses this so an
# operator close speaks the same vocabulary as jg_pending_reply_close_escalation
# instead of writing a silent no-op answered: note.
jg_pending_reply_close_note_for_key() {  # <key> <task-id> <via> [extra]
  case "$1" in
    pending-reply-*)
      jg_pending_reply_resolved_note "$2" "${1#pending-reply-}" "$3" "${4:-}"
      ;;
    *) return 1 ;;
  esac
}

jg_pending_reply_escalation_payload() {  # <record-path> <kind>
  local rec=$1 kind=$2 task_id corr summary outcome token
  task_id=$(jg_pending_reply_get "$rec" task_id)
  corr=$(jg_pending_reply_get "$rec" corr_id)
  summary=$(jg_pending_reply_get "$rec" request_summary)
  [ -n "$task_id" ] && [ -n "$corr" ] || return 1
  case "$kind" in
    missed)
      token=pending-reply-missed
      ;;
    delivery-unknown)
      token=pending-reply-delivery-unknown
      ;;
    recovery-delivery)
      outcome=$(jg_pending_reply_get "$rec" recovery_delivery_outcome)
      case "$outcome" in failed|unknown) ;; *) return 1 ;; esac
      token="pending-reply-recovery-delivery-$outcome"
      ;;
    *) return 1 ;;
  esac
  printf '%s: task=%s pending-reply-id=%s request=%s' "$token" "$task_id" "$corr" "$summary"
}

# The escalation line this library published for <corr_id>, or empty. A legacy
# unkeyed escalation is matched and closed under the shared default key while
# that exact escalation remains open. If an unrelated decision has since taken
# over that key, the close is withheld so the unrelated decision is not cleared.
jg_pending_reply_escalation_line() {  # <status-file> <record-path> <corr_id>
  local status_file=$1 rec=$2 corr=$3 line found='' kind payload own_key untimed
  [ -f "$status_file" ] || return 0
  [ "$(jg_pending_reply_get "$rec" corr_id)" = "$corr" ] || return 0
  own_key=$(jg_pending_reply_escalation_key "$corr")
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$(status_line_verb "$line")" = blocked ] || continue
    _jg_status_untimed "$line" untimed
    for kind in missed delivery-unknown recovery-delivery; do
      payload=$(jg_pending_reply_escalation_payload "$rec" "$kind") || continue
      case "$untimed" in
        "blocked [key=$own_key]: $payload"|"blocked: $payload") found=$line; break ;;
        "blocked [key=$own_key]: $payload "*|"blocked: $payload "*) found=$line; break ;;
      esac
    done
  done < "$status_file"
  printf '%s' "$found"
}

# Close the durable status decision a previous escalation opened for <corr_id>.
# Idempotent, and safe to retry until it succeeds: it appends the closing line
# only while that exact keyed decision is still open in
# bin/jg-classify-lib.sh's fold. Records that never escalated are left untouched.
jg_pending_reply_close_escalation() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec escalated closed parent_status escalation key note
  local open_line open_key open_note now close_line close_rc _task _via
  rec=$(jg_pending_reply_path "$state" "$corr")
  jg_pending_reply_exists "$rec" || return 1
  [ "$(jg_pending_reply_get "$rec" phase)" = resolved ] || return 0
  escalated=$(jg_pending_reply_get "$rec" escalated_epoch)
  [ -n "$escalated" ] || return 0
  closed=$(jg_pending_reply_get "$rec" escalation_closed_epoch)
  [ -z "$closed" ] || return 0
  parent_status=$(jg_pending_reply_get "$rec" parent_status)
  [ -n "$parent_status" ] || return 1
  escalation=$(jg_pending_reply_escalation_line "$parent_status" "$rec" "$corr")
  if [ -n "$escalation" ]; then
    key=$(_jg_decision_key "$escalation") || key=''
    note=$(status_line_note "$escalation")
    while IFS= read -r open_line; do
      [ -n "$open_line" ] || continue
      open_key=${open_line%%$'\t'*}
      [ "$open_key" = "$key" ] || continue
      open_note=${open_line#*$'\t'}
      open_note=${open_note#*$'\t'}
      [ "$open_note" = "$note" ] || continue
      # This close is the home's own bookkeeping, written by the same resolve
      # or tick that already consumed the reply, so it uses the guarded
      # self-announced append (bin/jg-wake-lib.sh, sourced by this function's
      # wrappers) and does not wake the home that wrote it; the escalation
      # OPEN above stays a plain append because a new blocker must wake.
      _task=$(jg_pending_reply_get "$rec" task_id)
      _via=$(jg_pending_reply_get "$rec" resolved_via)
      close_line="resolved [key=${key}]: $(jg_pending_reply_resolved_note "$_task" "$corr" "$_via")"
      close_rc=0
      jg_wake_status_append_self_announced "${parent_status%/*}" "$parent_status" "$close_line" \
        2>/dev/null || close_rc=$?
      [ "$close_rc" -ne 2 ] || return 1
      break
    done <<EOF
$(status_open_decisions "$parent_status")
EOF
  fi
  now=$(jg_pending_reply_now)
  jg_pending_reply_set "$rec" escalation_closed_epoch "$now"
}

# Escalate once after a missed recovery report or failed delivery outcome.
# Retains the durable unresolved record. Never loops.
jg_pending_reply_maybe_escalate() {  # <state-dir> <corr_id>
  local state=$1 corr=$2
  local rec phase completed now payload parent_status line kind first display
  local delivered task_id meta sm_home remote_host grace age key new_episode
  rec=$(jg_pending_reply_path "$state" "$corr")
  jg_pending_reply_exists "$rec" || return 1
  phase=$(jg_pending_reply_get "$rec" phase)
  case "$phase" in
    recovery_sent)
      completed=$(jg_pending_reply_get "$rec" recovery_turn_completed_epoch)
      [ -n "$completed" ] || return 1
      # Grace runs from the recovery turn's completion, the same anchor the
      # recovery repost itself uses (never from delivery or send time).
      grace=$(jg_pending_reply_get "$rec" grace_secs)
      case "$grace" in ''|*[!0-9]*) grace=$(jg_pending_reply_grace_secs) ;; esac
      now=$(jg_pending_reply_now)
      age=$((now - completed))
      [ "$age" -ge "$grace" ] || return 1
      # Same reply-channel evidence rule the recovery repost obeys: a missing
      # correlated report is not a missed report until the mirror caught up.
      jg_pending_reply_missing_report_is_evidence "$state" \
        "$(jg_pending_reply_get "$rec" task_id)" "$completed" || return 1
      ;;
    delivery_unknown|recovery_failed|recovery_unknown) ;;
    *) return 1 ;;
  esac
  delivered=$(jg_pending_reply_get "$rec" delivered_epoch)
  task_id=$(jg_pending_reply_get "$rec" task_id)
  meta="$state/${task_id}.meta"
  if [ -n "$delivered" ] && [ -f "$meta" ]; then
    remote_host=$(jg_meta_get "$meta" remote_host)
    sm_home=$(jg_meta_get "$meta" home)
    if [ -z "$remote_host" ] && [ -n "$sm_home" ]; then
      jg_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" || true
      jg_pending_reply_restatement_copy_same_basename "$state" "$corr" "$sm_home" || true
    fi
  fi
  parent_status=$(jg_pending_reply_get "$rec" parent_status)
  # One fresh, uncached read immediately before firing: a correlated report can
  # land in the instant between the last resolve attempt and this call.
  if jg_pending_reply_try_resolve "$state" "$corr" "$parent_status"; then
    return 0
  fi
  # A resolve that failed on a later field write has still committed resolved.
  [ "$(jg_pending_reply_get "$rec" phase)" = "$phase" ] || return 1
  case "$phase" in
    delivery_unknown) kind=delivery-unknown ;;
    recovery_failed|recovery_unknown) kind='recovery-delivery' ;;
    *) kind=missed ;;
  esac
  payload=$(jg_pending_reply_escalation_payload "$rec" "$kind") || return 1
  if [ "$kind" = missed ]; then
    first=$(jg_pending_reply_get "$rec" wrong_home_first_sighting)
    if display=$(jg_pending_reply_sighting_display "$first"); then
      payload="$payload token seen in $display; parent channel has no corr="
    fi
  fi
  [ -n "$parent_status" ] || return 1
  mkdir -p "$(dirname "$parent_status")" 2>/dev/null || return 1
  key=$(jg_pending_reply_escalation_key "$corr")
  line="blocked [key=$key]: $payload"
  # A record that already escalated reaches here again only after a reset, so
  # a closed decision means the operator settled the earlier episode and this
  # loss is a new one. While the decision is open the identical line is a retry.
  new_episode=1
  if [ -n "$(jg_pending_reply_get "$rec" escalated_epoch)" ]; then
    case $'\n'"$(status_open_decisions "$parent_status")" in
      *$'\n'"$key"$'\t'*) ;;
      *) new_episode=0 ;;
    esac
  fi
  if [ "$new_episode" -eq 0 ] || ! status_event_recorded "$parent_status" "$line"; then
    printf '%s\n' "$(status_stamp_line "$line")" >> "$parent_status" 2>/dev/null || return 1
  fi
  now=$(jg_pending_reply_now)
  jg_pending_reply_set "$rec" escalated_epoch "$now" || return 1
  jg_pending_reply_set "$rec" phase escalated || return 1
  return 0
}

# Detect a correlated report written under the squad_lead home (wrong home)
# without treating it as acknowledgement. A remote route's
# parent-replies.status is its parent channel, not a stranded self-home file.
jg_pending_reply_detect_wrong_home() {  # <state-dir> <corr_id> <squad-lead-home>
  local state=$1 corr=$2 sm_home=$3
  local rec delivered hits first sightings snapshot previous status_file line line_no sighting_base sighting_id phase changed=0
  local remote_parent_channel=0
  rec=$(jg_pending_reply_path "$state" "$corr")
  jg_pending_reply_exists "$rec" || return 1
  [ -n "$sm_home" ] && [ -d "$sm_home" ] || return 0
  phase=$(jg_pending_reply_get "$rec" phase)
  [ "$phase" != resolved ] || return 0
  delivered=$(jg_pending_reply_get "$rec" delivered_epoch)
  [ -n "$delivered" ] || return 0
  snapshot=$(jg_pending_reply_status_set_signature "$sm_home/state")
  previous=$(jg_pending_reply_get "$rec" wrong_home_scan_signature)
  hits=$(jg_pending_reply_get "$rec" wrong_home_hits)
  case "$hits" in ''|*[!0-9]*) hits=0 ;; esac
  first=$(jg_pending_reply_get "$rec" wrong_home_first_sighting)
  if [ "$snapshot" = "$previous" ] && { [ "$hits" = 0 ] || [ -n "$first" ]; }; then
    return 0
  fi
  sightings=$(jg_pending_reply_get "$rec" wrong_home_sightings)
  # shellcheck source=bin/jg-parent-channel-lib.sh
  . "$_JG_PENDING_REPLY_LIB_DIR/jg-parent-channel-lib.sh"
  if jg_parent_channel_destination "$sm_home" "$sm_home/state" >/dev/null 2>&1 \
    && [ "$JG_PARENT_CHANNEL_ROUTE" = remote ]; then
    remote_parent_channel=1
  fi
  for status_file in "$sm_home"/state/*.status; do
    [ -e "$status_file" ] || continue
    if [ "$remote_parent_channel" = 1 ] \
      && [ "$(basename "$status_file")" = parent-replies.status ]; then
      continue
    fi
    sighting_base=$(jg_pending_reply_sighting_encode "$status_file" 0) || continue
    sighting_base=${sighting_base%:0}
    line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      jg_pending_reply_line_resolves "$line" "$corr" || continue
      sighting_id="$sighting_base:$line_no"
      [ -n "$first" ] || first=$sighting_id
      case ",$sightings," in
        *",$sighting_id,"*) continue ;;
      esac
      if [ -n "$sightings" ]; then
        sightings="$sightings,$sighting_id"
      else
        sightings=$sighting_id
      fi
      hits=$((hits + 1))
      changed=1
    done < "$status_file"
  done
  if [ -n "$first" ] && [ -z "$(jg_pending_reply_get "$rec" wrong_home_first_sighting)" ]; then
    jg_pending_reply_set "$rec" wrong_home_first_sighting "$first" || return 1
  fi
  if [ "$changed" = 1 ]; then
    jg_pending_reply_set "$rec" wrong_home_sightings "$sightings" || return 1
    jg_pending_reply_set "$rec" wrong_home_hits "$hits" || return 1
  fi
  jg_pending_reply_set "$rec" wrong_home_scan_signature "$snapshot" || return 1
  return 0
}

# Restatement-copy a same-basename self-home corr= line onto the parent channel.
# Only $sm_home/state/<task_id>.status is copied; arbitrary child status files
# stay evidence, not acknowledgement.
jg_pending_reply_restatement_copy_same_basename() {  # <state-dir> <corr_id> <squad-lead-home>
  local state=$1 corr=$2 sm_home=$3
  local rec task_id parent_status stranded line
  rec=$(jg_pending_reply_path "$state" "$corr")
  jg_pending_reply_exists "$rec" || return 1
  [ -n "$sm_home" ] && [ -d "$sm_home" ] || return 1
  task_id=$(jg_pending_reply_get "$rec" task_id)
  parent_status=$(jg_pending_reply_get "$rec" parent_status)
  [ -n "$task_id" ] && [ -n "$parent_status" ] || return 1
  stranded="$sm_home/state/${task_id}.status"
  [ -f "$stranded" ] && [ ! -L "$stranded" ] || return 1
  [ "$stranded" != "$parent_status" ] || return 1
  line=$(jg_pending_reply_find_resolve_line "$stranded" "$corr")
  [ -n "$line" ] || return 1
  # Deliberately undirected: bin/jg-parent-channel-lib.sh is expanded once at
  # the jg_pending_reply_detect_wrong_home site; each directed site would
  # re-expand its whole transitive graph under ShellCheck's external-source
  # traversal.
  . "$_JG_PENDING_REPLY_LIB_DIR/jg-parent-channel-lib.sh"
  jg_parent_channel_append_once "$parent_status" "$line"
}

# --- the acting tick ---------------------------------------------------------
# One poll of the pending-reply guard, on the bus events and the definition's
# decisions. The engine (bin/jg-reply-engine.sh) decides; this acts. For each
# waiter it FIRST observes and resolves - the reply in the parent status log, the
# mate-home repairs, the endpoint's busy/idle turn completion - and only then asks
# the engine for the decision from the record those observations just wrote, so a
# turn completion and the repost it arms land in the same poll. Nothing here
# reconciles a delivery marker or walks a phase ladder by hand any more.
#
# jg_pending_reply_observe_and_resolve <state-dir> <corr_id>: the observation half.
# It never sends, escalates or resolves by itself beyond the reply line, and it
# returns 0 in every case so one waiter cannot stop the poll.
jg_pending_reply_observe_and_resolve() {  # <state-dir> <corr_id>
  local state=$1 corr=$2
  local rec task_id phase meta backend target label sm_home harness remote_host observation busy
  rec=$(jg_pending_reply_path "$state" "$corr")
  jg_pending_reply_exists "$rec" || return 0
  task_id=$(jg_pending_reply_get "$rec" task_id)
  # Parked-home guard (core/parked-homes): a parked home gets no recovery resend
  # and no missed-report escalation. No-op without the feature checkout.
  jg_parked_skip_meta "$state/${task_id}.meta" "$task_id" pending-reply && return 0
  phase=$(jg_pending_reply_get "$rec" phase)
  if [ "$phase" = resolved ]; then
    # Cheap no-op unless an escalation for this record is still open: the retry
    # that makes the close converge after a transient write failure.
    jg_pending_reply_close_escalation "$state" "$corr" || true
    return 0
  fi
  # A recovery repost whose sender died is reconciled from the sender identity,
  # never from the record's own guess about what happened.
  case "$phase" in
    awaiting_report|recovery_sending)
      if [ -n "$(jg_pending_reply_get "$rec" recovery_attempted_epoch)" ]; then
        jg_pending_reply_reconcile_recovery "$state" "$corr" || true
      fi
      ;;
  esac
  meta="$state/${task_id}.meta"
  backend=tmux
  target=
  sm_home=
  harness=
  if [ -f "$meta" ]; then
    remote_host=$(jg_meta_get "$meta" remote_host)
    backend=$(jg_backend_of_meta "$meta")
    target=$(jg_backend_target_of_meta "$meta")
    sm_home=$(jg_meta_get "$meta" home)
    harness=$(jg_meta_get "$meta" harness)
    if [ -n "$remote_host" ]; then
      target="remote:$task_id"
      sm_home=
    fi
  fi
  # The reply wins over everything else, and idempotently.
  jg_pending_reply_try_resolve "$state" "$corr" && return 0
  # A same-basename restatement-copy in the mate home is a repair, not an
  # acknowledgement of an arbitrary mate-home file.
  if [ -n "$sm_home" ]; then
    jg_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" || true
    if jg_pending_reply_restatement_copy_same_basename "$state" "$corr" "$sm_home"; then
      jg_pending_reply_try_resolve "$state" "$corr" && return 0
    fi
  fi
  phase=$(jg_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report|recovery_sent) ;;
    *) return 0 ;;
  esac
  # The turn completion that arms a timer is only meaningful after delivery.
  [ -n "$(jg_pending_reply_get "$rec" delivered_epoch)" ] || return 0
  [ -n "$target" ] || return 0
  if [ -n "$remote_host" ]; then
    observation=$("$_JG_PENDING_REPLY_LIB_DIR/jg-on.sh" "$task_id" \
      jg-remote-squad-lead-control.sh observe "$task_id" < /dev/null 2>/dev/null || printf 'unknown')
    case "$observation" in busy|idle|fallback-idle|unknown) ;; *) observation=unknown ;; esac
  else
    label="jg-$task_id"
    observation=$(jg_pending_reply_backend_observation "$backend" "$target" "$label" "$harness")
  fi
  busy=$(jg_pending_reply_busy_state_from_observation "$rec" "$observation")
  jg_pending_reply_observe_busy "$state" "$corr" "$busy" || true
  # Re-check the reply after observation in case a concurrent status write landed.
  jg_pending_reply_try_resolve "$state" "$corr" || true
  return 0
}

# jg_pending_reply_decisions <state-dir>: the engine's decision rows for every
# waiter this home holds, one per line as "<id>\t<row>". The docs are built from
# the same record text the stream carries, so the engine folds the facts the cache
# shows and nothing else.
jg_pending_reply_decisions() {  # <state-dir>
  local state=$1 recs_dir corr block docs
  local -a files=()
  [ -s "$(jg_pending_reply_cache "$state")" ] || return 0
  recs_dir=$(mktemp -d "${TMPDIR:-/tmp}/jg-pending-reply-docs.XXXXXX" 2>/dev/null) || return 0
  while IFS= read -r corr; do
    [ -n "$corr" ] || continue
    block=$(jg_pending_reply_record_text "$(jg_pending_reply_path "$state" "$corr")")
    [ -n "$block" ] || continue
    printf '%s\n' "$block" > "$recs_dir/$corr" || continue
    files+=("$recs_dir/$corr")
  done < <(jg_pending_reply_corrs "$state")
  if [ "${#files[@]}" -gt 0 ]; then
    docs=$("$_JG_PENDING_REPLY_LIB_DIR/jg-reply-bus.sh" \
      --home "$(dirname "$state")" docs ${files[@]+"${files[@]}"} 2>/dev/null) || docs=
  fi
  rm -rf -- "$recs_dir"
  [ -n "${docs:-}" ] || return 0
  # One clock for the observation and the decision: the library's own, which a
  # test or a replay pins with JG_PENDING_REPLY_NOW.
  printf '%s\n' "$docs" | "$_JG_PENDING_REPLY_LIB_DIR/jg-reply-engine.sh" \
    decide-stdin "$(jg_pending_reply_now)"
}


# jg_pending_reply_act_on_decisions <state-dir>: perform the rows the engine took.
# Each action keeps its own preconditions, so a decision that the facts have moved
# past is a no-op rather than a second send or a second escalation.
jg_pending_reply_act_on_decisions() {  # <state-dir>
  local state=$1 kind id rest corr now rec task_id
  now=$(jg_pending_reply_now)
  while IFS=$'\t' read -r kind id rest; do
    [ -n "${kind:-}" ] || continue
    [ -n "${id:-}" ] || continue
    corr=${id##*/}
    [ -n "$corr" ] || continue
    # A parked home gets no recovery resend and no escalation, whatever the
    # definition decided for it.
    rec=$(jg_pending_reply_path "$state" "$corr")
    task_id=$(jg_pending_reply_get "$rec" task_id)
    jg_parked_skip_meta "$state/${task_id}.meta" "$task_id" pending-reply && continue
    # The trace line first: it records what the definition decided, even when the
    # action's own preconditions turn the action into a no-op.
    printf '%s\t%s\t%s\t%s\n' "$now" "$kind" "$id" "$rest"
    case "$kind" in
      repost) jg_pending_reply_send_recovery "$state" "$corr" >/dev/null 2>&1 || true ;;
      escalate) jg_pending_reply_maybe_escalate "$state" "$corr" >/dev/null 2>&1 || true ;;
      delivery-unknown) jg_pending_reply_mark_delivery_unknown "$state" "$corr" >/dev/null 2>&1 || true ;;
      answer) jg_pending_reply_close_escalation "$state" "$corr" >/dev/null 2>&1 || true ;;
    esac
  done < <(jg_pending_reply_decisions "$state")
  return 0
}

# jg_pending_reply_tick <state-dir>: one poll. Observe and resolve every waiter,
# then let the engine decide and act on each. Prints the rows acted on, one
# "<epoch>\t<row>" per line, so the caller can keep the decision trace.
jg_pending_reply_tick() {  # <state-dir>
  local state=$1 corr
  while IFS= read -r corr; do
    [ -n "$corr" ] || continue
    jg_pending_reply_observe_and_resolve "$state" "$corr" || true
  done < <(jg_pending_reply_corrs "$state")
  jg_pending_reply_act_on_decisions "$state"
  return 0
}


# True when any open (non-resolved) pending reply exists for a task.
jg_pending_reply_task_has_open() {  # <state-dir> <task_id>
  local state=$1 task_id=$2 corr rec phase tid
  while IFS= read -r corr; do
    [ -n "$corr" ] || continue
    rec=$(jg_pending_reply_path "$state" "$corr")
    tid=$(jg_pending_reply_get "$rec" task_id)
    [ "$tid" = "$task_id" ] || continue
    phase=$(jg_pending_reply_get "$rec" phase)
    [ "$phase" != resolved ] || continue
    return 0
  done < <(jg_pending_reply_corrs "$state")
  return 1
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
    jg_compat_marker_ok() { [ "${1-}" = JUGGERNAUT_OP ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d

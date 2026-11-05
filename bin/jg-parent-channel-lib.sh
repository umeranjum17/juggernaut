#!/usr/bin/env bash
# jg-parent-channel-lib.sh - the one owner of a squad_lead home's parent channel.
#
# WHY THIS EXISTS. A squad_lead is a juggernaut in its own home, and nobody reads
# its chat: the captain and the main juggernaut see only what is appended to the
# parent channel. A mate can satisfy AGENTS.md's address rule in local chat
# while skipping the charter's return-channel instruction, so a PR-ready result,
# finding, decision, blocker, or failure never reaches the parent.
# Four such misses were observed on 2026-09-02 across two mate homes; the
# watcher had delivered the parent's request each time and the work was done.
# The problem is therefore not one missed PR notice but every captain-facing
# outcome that depends on the model remembering to write to the channel.
# The fix is structural: every script that RECORDS a captain-facing outcome in a
# mate home publishes it on the parent channel itself, so delivery never
# depends on the model. This library owns where that channel lives and how a
# line is appended to it. The publishers are:
#   - bin/jg-inactive-reconcile.sh   a direct child's terminal done or failed
#                                    ledger line, on every watcher poll, plus
#                                    the silent-ledger inactive-outcome fallback
#   - bin/jg-pr-check.sh             a registered PR-ready line carrying the
#                                    canonical URL
#   - bin/jg-captain-hold.sh         a task held for the captain and its answer
#   - bin/jg-merge-outcome-lib.sh    a merged PR
#   - bin/jg-teardown.sh             the child's final ledger line, refusing to
#                                    remove the child while it is undelivered
#   - bin/jg-squad-lead-report.sh     a marked request's correlated answer,
#                                    with this resolver choosing its destination
# The mate's own appends are reserved for judgement (bin/jg-brief.sh charter).
# docs/squad-lead-parent-channel.md records the design and its coverage.
#
# THE CHANNEL. It is resolved from the home's own durable identity and parent
# binding, never from a caller's choice:
#   - the .jg-squad-lead-home marker names the mate's id in its parent home;
#   - the .jg-squad-lead-parent record (bin/jg-squad-lead-parent-lib.sh) names
#     the route: a local route reports into the parent home's
#     state/<mate-id>.status, a remote route into this home's own
#     state/parent-replies.status, which the parent's remote reply adapter
#     mirrors line for line into that same parent file
#     (docs/remote-squad-leads.md).
# The parent watcher classifies lines there exactly as it classifies any
# operator's status stream, so a captain-relevant line becomes a parent wake.
#
# Line syntax and retry equivalence are owned by jg-classify-lib.sh.
# An existing destination must be a regular, non-symlinked file; a missing one
# is created with its directory.
#
# Return codes, shared by every entry point that resolves the channel:
#   0  resolved, or appended / already present
#   1  this is a main home (no .jg-squad-lead-home marker): nothing to report
#   2  the identity marker exists but is unusable (symlink, NUL, bad id)
#   3  the parent binding is missing or unreadable
#   4  the append itself failed
# A caller that has already recorded the outcome locally must surface a
# non-zero return rather than treat it as delivered.
#
# Sourced by the publishers above and by tests. No side effects on source.

_JG_PARENT_CHANNEL_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/jg-squad-lead-parent-lib.sh
. "$_JG_PARENT_CHANNEL_LIB_DIR/jg-squad-lead-parent-lib.sh"
# shellcheck source=bin/jg-classify-lib.sh
. "$_JG_PARENT_CHANNEL_LIB_DIR/jg-classify-lib.sh"
# The captain voice check steps aside when its library is not beside this one (a lone copy).
if [ -r "$_JG_PARENT_CHANNEL_LIB_DIR/jg-voice-lib.sh" ]; then
  # shellcheck source=bin/jg-voice-lib.sh
  . "$_JG_PARENT_CHANNEL_LIB_DIR/jg-voice-lib.sh"
else
  jg_voice_apply() { JG_VOICE_OUT=$2; }
fi

# shellcheck disable=SC2034 # Output globals read by sourcing callers.
JG_PARENT_CHANNEL_ID=
# shellcheck disable=SC2034 # Output globals read by sourcing callers.
JG_PARENT_CHANNEL_ROUTE=

# A mate id is used as a file-name component in the parent home, so it is
# accepted only when it is path-safe: no empty value, leading dot, slash, or
# character outside [A-Za-z0-9._-].
_jg_parent_channel_id_valid() {  # <id>
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# The squad_lead identity of <home>, printed, or non-zero for a main home (1)
# or an unusable identity marker (2).
jg_parent_channel_home_id() {  # <home>
  local home=$1 marker id
  marker="$(jg_compat_marker "$home")"
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    return 1
  fi
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
  [ "$(wc -c < "$marker")" -eq "$(LC_ALL=C tr -d '\0' < "$marker" | wc -c)" ] || return 2
  id=$(cat "$marker" 2>/dev/null) || return 2
  _jg_parent_channel_id_valid "$id" || return 2
  printf '%s\n' "$id"
}

# Resolve the channel destination for <home> whose state dir is <state>.
# Prints the destination path and sets JG_PARENT_CHANNEL_ID and
# JG_PARENT_CHANNEL_ROUTE. Returns 1 for a main home, 2 for an unusable
# marker, 3 for a missing or unreadable parent binding.
jg_parent_channel_destination() {  # <home> <state>
  local home=$1 state=$2 id rc=0
  JG_PARENT_CHANNEL_ID=
  JG_PARENT_CHANNEL_ROUTE=
  id=$(jg_parent_channel_home_id "$home") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  jg_squad_lead_parent_record_parse "$(jg_compat_parent_marker "$home")" || return 3
  case "$JG_SQUAD_LEAD_PARENT_ROUTE" in
    local)
      [ -n "$JG_SQUAD_LEAD_PARENT_HOME" ] || return 3
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      JG_PARENT_CHANNEL_ID=$id
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      JG_PARENT_CHANNEL_ROUTE=local
      printf '%s/state/%s.status\n' "$JG_SQUAD_LEAD_PARENT_HOME" "$id"
      ;;
    remote)
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      JG_PARENT_CHANNEL_ID=$id
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      JG_PARENT_CHANNEL_ROUTE=remote
      printf '%s/parent-replies.status\n' "$state"
      ;;
    *) return 3 ;;
  esac
}

# The outbound parent-channel status path that lives INSIDE <state>, printed,
# when <home> is a remote mate; non-zero for a main home, a local mate, or an
# unusable identity or binding. Only the remote route resolves the channel into
# the mate's own state dir, so parent-replies.status there is the mate's parent
# channel rather than a self-home task status file: a home's own status scans
# and decision folds exclude exactly this resolved path (the same special case
# jg-pending-reply-lib.sh's wrong-home detection applies). A local mate's
# channel lives in the parent home's state/<id>.status, which the parent's
# scans must keep classifying, so only the remote route resolves here.
jg_parent_channel_outbound_status() {  # <home> <state>
  local home=$1 state=$2 destination rc=0
  destination=$(jg_parent_channel_destination "$home" "$state") || rc=$?
  [ "$rc" -eq 0 ] || return 1
  # The substitution above ran the resolver in a subshell, so its route global
  # died with it; resolve once more in this shell (stdout discarded, the same
  # shape jg-pending-reply-lib.sh's wrong-home detection uses) so the route
  # check reads the resolver's own verdict rather than re-deriving it.
  jg_parent_channel_destination "$home" "$state" >/dev/null || return 1
  [ "$JG_PARENT_CHANNEL_ROUTE" = remote ] || return 1
  printf '%s\n' "$destination"
}

# Fold <text> onto one bounded line, so a note copied from a child ledger or a
# hold reason cannot break the channel's line framing.
jg_parent_channel_clean_note() {  # <text>
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-1200
}

# Append <line> once, using jg-classify-lib.sh's retry contract. Time-insensitive:
# the caller declaring a new event is the one that stamps it.
jg_parent_channel_append_once() {  # <path> <line>
  local path=$1 line=$2 guard=$_JG_PARENT_CHANNEL_LIB_DIR/jg-path-guard.sh
  # The captain voice file rewrites the note before it is compared or written, so a retry of the
  # same event rewrites to the same line and stays deduplicated. A line is never held back here.
  # A machine close line (`resolved [key=waiting-timer-...]: waiting-timer-...: ...`) is a marker the
  # reader matches, not prose for the captain, so it reaches the channel as written.
  local mkey mnote
  if [ "$(status_line_verb "$line")" = resolved ] \
    && mkey=$(_jg_decision_key "$line" "") && mnote=$(status_line_note "$line") \
    && case $mkey in waiting-timer-*) _jg_decision_key_transition_allowed "$mkey" "$mnote" ;; *) false ;; esac; then
    :
  elif jg_voice_apply parent-channel "$line" --line; then line=$JG_VOICE_OUT; fi
  # The captain cannot open a raw file path on his phone: withhold it at write
  # time, so a worker's evidence path never reaches him and never blocks delivery.
  if [ -x "$guard" ]; then
    line=$(printf '%s\n' "$line" | "$guard" --mask) || return 1
  fi
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
  else
    mkdir -p "$(dirname "$path")" || return 1
  fi
  if status_event_recorded "$path" "$line"; then
    return 0
  fi
  printf '%s\n' "$line" >> "$path"
}

# Publish one parent-facing line from <home>. See the return codes above.
jg_parent_channel_report() {  # <home> <state> <line>
  local home=$1 state=$2 line=$3 destination rc=0
  destination=$(jg_parent_channel_destination "$home" "$state") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  jg_parent_channel_append_once "$destination" "$(status_stamp_line "$line")" || return 4
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

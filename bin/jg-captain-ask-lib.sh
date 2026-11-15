#!/usr/bin/env bash
# Shared fork guard for captain asks; callers supply backlog_cmd (a function reading the home's backlog), SCRIPT_DIR, and fail.
captain_ask_row() {  # <id>; sets CAPTAIN_ASK_SHOW to the row's show output when it is a [captain-ask] item
  local title
  CAPTAIN_ASK_SHOW=''
  [ -n "$1" ] || return 0
  CAPTAIN_ASK_SHOW=$(backlog_cmd show "$1" --full 2>/dev/null) \
    || fail "cannot read $1 to check whether it is a [captain-ask] item; it stays in the backlog until the read succeeds"
  title=$(printf '%s\n' "$CAPTAIN_ASK_SHOW" | sed -n 's/^  title: //p' | head -1)
  case "$title" in
    '') fail "cannot read the title of $1 to check whether it is a [captain-ask] item; it stays in the backlog" ;;
    *'[captain-ask]'*) ;;
    *) CAPTAIN_ASK_SHOW='' ;;
  esac
}

guard_captain_ask() {  # <id>
  local pr
  captain_ask_row "$1"
  [ -n "$CAPTAIN_ASK_SHOW" ] || return 0
  "$SCRIPT_DIR/jg-captain-hold.sh" answered "$1" && return 0
  # A Recon delivers its report instead of an answer or a PR.
  if printf '%s\n' "$CAPTAIN_ASK_SHOW" | grep -q "^  links: .*report:data/$1/report\.md" \
    && [ -s "$DATA/$1/report.md" ]; then return 0; fi
  for pr in $(printf '%s\n' "$CAPTAIN_ASK_SHOW" | sed -n 's/^  links: //p' | grep -o 'pr:[^" ,]*' | sed 's/^pr://'); do
    [ "$(gh pr view "$pr" --json state -q .state 2>/dev/null)" = MERGED ] && return 0
  done
  fail "$1 is a [captain-ask] item with no recorded captain answer (bin/jg-captain-hold.sh answer) and no merged PR (bin/jg-backlog.sh update --pr); it cannot leave the backlog"
}

# Closing, cancelling or deleting a captain-asked row: delivery (a merged PR or a Recon
# report) closes it; otherwise it needs the captain's quoted words, or a board confirm card
# he answered. A recorded answer alone is not enough. Callers set CAPTAIN_QUOTE and CONFIRM_CARD.
guard_captain_ask_close() {  # <id>
  local pr
  captain_ask_row "$1"
  [ -n "$CAPTAIN_ASK_SHOW" ] || return 0
  if printf '%s\n' "$CAPTAIN_ASK_SHOW" | grep -q "^  links: .*report:data/$1/report\.md" \
    && [ -s "$DATA/$1/report.md" ]; then return 0; fi
  for pr in $(printf '%s\n' "$CAPTAIN_ASK_SHOW" | sed -n 's/^  links: //p' | grep -o 'pr:[^" ,]*' | sed 's/^pr://'); do
    if [ "$(gh pr view "$pr" --json state -q .state 2>/dev/null)" = MERGED ]; then return 0; fi
  done
  if [ -n "$(printf '%s' "$CAPTAIN_QUOTE" | tr -d '[:space:]')" ]; then
    captain_ask_record_closure "$1" "captain words: $CAPTAIN_QUOTE"
    return 0
  fi
  if [ -n "$CONFIRM_CARD" ]; then
    [ "$CONFIRM_CARD" != "$1" ] \
      || fail "$1 cannot confirm its own close: its recorded answer is not the captain's word to close it; use a separate confirm card"
    backlog_cmd show "$CONFIRM_CARD" --full 2>/dev/null | grep -qF -- "$1" \
      || fail "confirm card $CONFIRM_CARD does not name $1; $1 is a [captain-ask] item and stays in the backlog"
    "$SCRIPT_DIR/jg-captain-hold.sh" answered "$CONFIRM_CARD" >/dev/null 2>&1 \
      || fail "$1 is a [captain-ask] item and confirm card $CONFIRM_CARD has no recorded captain answer; it cannot leave the backlog"
    captain_ask_record_closure "$1" "answered board confirm card: $CONFIRM_CARD"
    return 0
  fi
  fail "$1 is a [captain-ask] item with no delivery (merged PR or Recon report); closing, cancelling or deleting it needs --captain-quote '<his words>' or --confirm-card <answered card id>. If the captain rejected the options, redo them instead of cancelling"
}

captain_ask_record_closure() {  # <id> <evidence line>
  if ! { mkdir -p "$DATA" && printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$1" "$2" >> "$DATA/captain-closures.md"; }; then
    fail "cannot record the captain's closing words for $1; it stays in the backlog"
  fi
  # shellcheck disable=SC2034  # CLOSE_NOTE_ARGS is read by bin/jg-backlog.sh, which sources this file
  case "${verb:-}" in
    done|close) CLOSE_NOTE_ARGS=(--note "Closed on $2") ;;
  esac
}

# A raw hold would revive an old answer's record; the sanctioned hold starts a new hold set.
guard_captain_ask_hold() {  # <id>
  captain_ask_row "$1"
  [ -z "$CAPTAIN_ASK_SHOW" ] || fail "$1 is a [captain-ask] item; hold it with bin/jg-captain-hold.sh hold so the new hold is recorded"
}

# Build approval. A ship may be built for a [captain-ask] ticket, or a ticket marked
# `born-from: recon|plan`, only on one record of the captain's yes; no second record is written
# to confirm it (decision D1). captain_ask_build_basis names the record a ticket rests on:
#   1. `approved-by-captain: <ref> sig=<hmac>` in its body. Only captain_ask_approval_line writes
#      one: bin/jg-captain-hold.sh answer (his recorded board answer) and bin/jg-inbox.sh approve
#      (his own note) call it. The sig is an HMAC over the ticket id and ref under
#      state/captain-approval.key (mode 0600, made on first write), so a hand-written line, or one
#      copied from another ticket, never verifies.
#   2. `owner-words: note:<id> "<his words>"` in its body: an order that carries the owner's own
#      words. Note <id> must be a captain chat note (`[chat ...]`, his channel record) in this
#      home's inbox, or in its parent's for a Squad Lead home, and its text must hold those words
#      verbatim as whole words.
# A `born-from:` ticket with neither rests on its `parent:` ticket's record 1 or 2: a slice of a
# report starts on the report's recorded build answer.
captain_ask_approval_sig() {  # <ticket> <ref> <key-file>; prints the hex HMAC
  printf '%s\n%s' "$1" "$2" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$(cat "$3")" -r | cut -d' ' -f1
}

captain_ask_approval_line() {  # <ticket> <ref>; prints the signed line, making the key if absent
  local key="${STATE:?}/captain-approval.key"
  case "$2" in ''|*[!A-Za-z0-9._:-]*) fail "approval reference must be a plain token (a note id or answer digest): $2" ;; esac
  command -v openssl >/dev/null 2>&1 || fail "openssl is required to sign a captain approval"
  if [ ! -s "$key" ]; then
    mkdir -p "$STATE" || fail "cannot make $STATE"
    (umask 077; openssl rand -hex 32 > "$key") || fail "cannot make the captain approval key at $key"
  fi
  printf 'approved-by-captain: %s sig=%s\n' "$2" "$(captain_ask_approval_sig "$1" "$2" "$key")"
}

captain_ask_build_gated() {  # <show-output>; 0 when a ship build needs the captain's approval
  printf '%s\n' "$1" | sed -n 's/^  title: //p' | head -1 | grep -qF '[captain-ask]' && return 0
  printf '%s\n' "$1" | grep -Eq 'born-from: *(recon|plan)([^A-Za-z]|$)'
}

# A Squad Lead home holds no key of its own for the owner's yes: the line was signed in its parent
# home, so the parent home's own copy of this file recomputes the HMAC under the parent's key. The
# key never leaves that home and no key is made here. CAPTAIN_ASK_PARENT_NOTE says why the parent
# could not answer, so a refusal can tell a wait on the parent from a bad line.
captain_ask_parent_sig() {  # <ticket> <ref>; prints the parent home's HMAC, else sets CAPTAIN_ASK_PARENT_NOTE
  local parent lib
  CAPTAIN_ASK_PARENT_NOTE=''
  declare -F jg_squad_lead_parent_record_parse >/dev/null \
    && jg_squad_lead_parent_record_parse "$(jg_compat_parent_marker "${JG_HOME:-}")" || return 1
  [ "$JG_SQUAD_LEAD_PARENT_ROUTE" = local ] && parent=$JG_SQUAD_LEAD_PARENT_HOME || return 1
  lib="$parent/bin/jg-captain-ask-lib.sh"
  if [ ! -r "$lib" ] || [ ! -s "$parent/state/captain-approval.key" ]; then
    CAPTAIN_ASK_PARENT_NOTE="the main home $parent cannot verify the approval now (its key or its verifier is missing); the ticket waits on Main"
    return 1
  fi
  STATE="$parent/state" bash -c 'fail() { echo "$*" >&2; exit 1; }; . "$1" && captain_ask_approval_sig "$2" "$3" "$STATE/captain-approval.key"' \
    _ "$lib" "$1" "$2" 2>/dev/null \
    || { CAPTAIN_ASK_PARENT_NOTE="the main home $parent did not answer the approval check; the ticket waits on Main"; return 1; }
}

captain_ask_approved_ref() {  # <ticket> <show-output>; prints the ref of the first line that verifies
  local key="${STATE:?}/captain-approval.key" ref sig want
  while read -r ref sig; do
    [ -n "$ref" ] || continue
    if [ -s "$key" ] && [ "$sig" = "$(captain_ask_approval_sig "$1" "$ref" "$key")" ]; then printf '%s\n' "$ref"; return 0; fi
    if want=$(captain_ask_parent_sig "$1" "$ref") && [ "$sig" = "$want" ]; then printf '%s\n' "$ref"; return 0; fi
  done < <(printf '%s\n' "$2" | grep -Eo 'approved-by-captain: [A-Za-z0-9._:-]+ sig=[0-9a-f]{64}' | sed -E 's/^approved-by-captain: ([^ ]+) sig=/\1 /')
  return 1
}

captain_ask_build_approved() {  # <ticket> <show-output>; 0 when a line in the body verifies
  captain_ask_approved_ref "$1" "$2" >/dev/null
}

captain_ask_body() {  # <show-output>; prints the decoded body
  local value
  value=$(printf '%s\n' "$1" | sed -n 's/^  body: //p' | head -1)
  case "$value" in \"*\") printf '%s' "$value" | jq -r . ;; *) printf '%s\n' "$value" ;; esac
}

captain_ask_chat_text() {  # <note-id>; prints the words of that captain chat note, its [chat ...] tag dropped
  local dir file inboxes=("${STATE:?}/inbox")
  case "$1" in ''|*[!A-Za-z0-9._-]*|*..*) return 1 ;; esac
  if declare -F jg_squad_lead_parent_record_parse >/dev/null \
    && jg_squad_lead_parent_record_parse "$(jg_compat_parent_marker "${JG_HOME:-}")" && [ -n "$JG_SQUAD_LEAD_PARENT_HOME" ]; then
    inboxes+=("$JG_SQUAD_LEAD_PARENT_HOME/state/inbox")
  fi
  for dir in "${inboxes[@]}"; do
    for file in "$dir/$1.note" "$dir/handled/$1.note"; do
      [ -f "$file" ] || continue
      # A note is its header, a `--` line, then the body jg-inbox.sh note wrote; a body
      # that does not open with the [chat ...] tag is not his channel record and prints nothing.
      awk 'found == 2 { print; next }
        found == 1 { if (sub(/^\[chat [^]]*\][[:space:]]*/, "")) { found = 2; print; next } exit }
        /^--$/ { found = 1 }' "$file"
      return 0
    done
  done
  return 1
}

captain_ask_build_basis() {  # <ticket> <show-output>; prints the record a build of it rests on
  local ref note words text
  if ref=$(captain_ask_approved_ref "$1" "$2"); then
    printf 'the captain'\''s recorded approval %s\n' "$ref"
    return 0
  fi
  while IFS=$'\t' read -r note words; do
    text=$(captain_ask_chat_text "$note" | tr -s '[:space:]' ' ') && [ -n "$text" ] || continue
    words=$(printf '%s' "$words" | tr -s '[:space:]' ' ')
    if printf '%s\n' "$text" | grep -qFw -- "$words"; then
      printf 'the owner'\''s words in chat note %s\n' "$note"
      return 0
    fi
  done < <(captain_ask_body "$2" | sed -nE 's/^[[:space:]]*owner-words:[[:space:]]*note:([A-Za-z0-9._-]+)[[:space:]]+"(.*[^[:space:]].*)"[[:space:]]*$/\1\t\2/p')
  return 1
}

captain_ask_parent_basis() {  # <ticket> <show-output>; 0 when a born-from: recon|plan ticket's parent rests on a record
  local parent
  printf '%s\n' "$2" | grep -Eq 'born-from: *(recon|plan)([^A-Za-z]|$)' || return 1
  parent=$(printf '%s\n' "$2" | sed -nE 's/^  parent:[[:space:]]*([A-Za-z0-9._-]+)[[:space:]]*$/\1/p' | head -1)
  [ -n "$parent" ] || parent=$(captain_ask_body "$2" | sed -nE 's/^[[:space:]]*parent:[[:space:]]*([A-Za-z0-9._-]+)[[:space:]]*$/\1/p' | head -1)
  [ -n "$parent" ] && [ "$parent" != "$1" ] || return 1
  captain_ask_build_basis "$parent" "$(backlog_cmd show "$parent" --full 2>/dev/null)"
}

# A follow-up stated ahead: a ticket body line `on-report: triage-build <harness> <model> <effort>` says what
# happens when its Recon report lands. The line is the captain's order, so it counts only while the ticket
# rests on one of the three records captain_ask_build_basis reads (his recorded approval, his own words in a
# chat note, or the parent's record); a typed line with none of them is never run.
captain_ask_on_report() {  # <ticket> <show-output>; prints "<harness> <model> <effort>" or names why it is not run
  local line words
  line=$(captain_ask_body "$2" | sed -nE 's/^[[:space:]]*on-report:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' | head -1)
  [ -n "$line" ] || { echo "$1 has no on-report line" >&2; return 2; }
  # shellcheck disable=SC2086  # the line is split into its words on purpose
  set -- "$1" "$2" $line
  if [ "$#" -ne 6 ] || [ "$3" != triage-build ] || [ -n "$(printf '%s' "$4$5$6" | tr -d 'A-Za-z0-9._:/-')" ]; then
    echo "the on-report line of $1 must read: on-report: triage-build <harness> <model> <effort>" >&2
    return 2
  fi
  captain_ask_build_basis "$1" "$2" >/dev/null || captain_ask_parent_basis "$1" "$2" >/dev/null \
    || { echo "the on-report line of $1 rests on no record of the captain's yes (his recorded approval, his words in a chat note, or the parent's record), so it is not run" >&2; return 3; }
  printf '%s %s %s\n' "$4" "$5" "$6"
}

# Reads its rows with bin/jg-backlog-transition-lib.sh's jg_backlog_row_show over $DATA, which
# bin/jg-spawn.sh and bin/jg-send.sh source; any row it cannot read is refused, never passed.
guard_captain_ask_build() {  # <ticket>; refuses an unapproved build, else names its record on stderr
  local show parent='' basis
  show=$(jg_backlog_row_show "$(jg_backlog_data_absolute "${DATA:?}")" "$1" --full) \
    || fail "cannot read $1 to check whether a build of it needs the captain's approval: $show"
  captain_ask_build_gated "$show" || return 0
  if basis=$(captain_ask_build_basis "$1" "$show"); then
    printf 'approval: %s starts on %s\n' "$1" "$basis" >&2
    return 0
  fi
  if printf '%s\n' "$show" | grep -Eq 'born-from: *(recon|plan)([^A-Za-z]|$)'; then
    # The parent is the row's parent-child edge, which the card prints; a body line is the fallback.
    parent=$(printf '%s\n' "$show" | sed -nE 's/^  parent:[[:space:]]*([A-Za-z0-9._-]+)[[:space:]]*$/\1/p' | head -1)
    [ -n "$parent" ] || parent=$(captain_ask_body "$show" | sed -nE 's/^[[:space:]]*parent:[[:space:]]*([A-Za-z0-9._-]+)[[:space:]]*$/\1/p' | head -1)
  fi
  if [ -n "$parent" ] && [ "$parent" != "$1" ] \
    && basis=$(captain_ask_build_basis "$parent" "$(jg_backlog_row_show "$(jg_backlog_data_absolute "$DATA")" "$parent" --full)"); then
    printf 'approval: %s starts on %s on its parent %s\n' "$1" "$basis" "$parent" >&2
    return 0
  fi
  # The verifier runs in a subshell, so ask once more here to learn whether the parent was reachable.
  if printf '%s\n' "$show" | grep -q 'approved-by-captain:'; then captain_ask_parent_sig "$1" probe >/dev/null || true; fi
  [ -z "${CAPTAIN_ASK_PARENT_NOTE:-}" ] || printf 'approval: %s\n' "$CAPTAIN_ASK_PARENT_NOTE" >&2
  fail "$1 is a [captain-ask] or Recon/plan-born ticket with no record of the captain's yes, so no worker may be told to build it. Any one record is enough: his recorded answer (bin/jg-captain-hold.sh answer) or his note (bin/jg-inbox.sh approve <note-id> $1) writes an approved-by-captain line; an order carries his words as owner-words: note:<chat-note-id> \"<his words>\"; a Recon/plan-born slice rests on its parent: ticket's record. A report, a recommendation or an option pick is not one"
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
# A Squad Lead home reads the owner's chat notes in its parent home too (captain_ask_chat_text).
# shellcheck source=bin/jg-squad-lead-parent-lib.sh
[ ! -r "$_jg_d/jg-squad-lead-parent-lib.sh" ] || . "$_jg_d/jg-squad-lead-parent-lib.sh"
unset _jg_d

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
# `born-from: recon|plan`, only when its body carries `approved-by-captain: <ref> sig=<hmac>`.
# Only captain_ask_approval_line writes one: bin/jg-captain-hold.sh answer (the captain's
# recorded answer) and bin/jg-inbox.sh approve (his own note) call it. The sig is an HMAC over
# the ticket id and ref under state/captain-approval.key (mode 0600, made on first write), so
# a hand-written line, or one copied from another ticket, never verifies.
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

captain_ask_build_approved() {  # <ticket> <show-output>; 0 when a line in the body verifies
  local key="${STATE:?}/captain-approval.key" ref sig
  [ -s "$key" ] || return 1
  while read -r ref sig; do
    [ -n "$ref" ] && [ "$sig" = "$(captain_ask_approval_sig "$1" "$ref" "$key")" ] && return 0
  done < <(printf '%s\n' "$2" | grep -Eo 'approved-by-captain: [A-Za-z0-9._:-]+ sig=[0-9a-f]{64}' | sed -E 's/^approved-by-captain: ([^ ]+) sig=/\1 /')
  return 1
}

guard_captain_ask_build() {  # <ticket> <show-output>; refuses an unapproved build
  captain_ask_build_gated "$2" || return 0
  captain_ask_build_approved "$1" "$2" && return 0
  fail "$1 is a [captain-ask] or Recon/plan-born ticket with no approved-by-captain line, so no worker may be told to build it. The captain's recorded answer (bin/jg-captain-hold.sh answer) or his own note (bin/jg-inbox.sh approve <note-id> $1) writes that line; a report, a recommendation or an option pick does not"
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

#!/usr/bin/env bash
# Shared fork guard for captain asks; callers supply backlog_cmd (a function reading the home's backlog), SCRIPT_DIR, and fail.
captain_ask_row() {  # <id>; sets CAPTAIN_ASK_SHOW to the row's show output when it is a [captain-ask] item
  CAPTAIN_ASK_SHOW=''
  [ -n "$1" ] || return 0
  CAPTAIN_ASK_SHOW=$(backlog_cmd show "$1" --full 2>/dev/null) \
    || fail "cannot read $1 to check whether it is a [captain-ask] item; it stays in the backlog until the read succeeds"
  printf '%s\n' "$CAPTAIN_ASK_SHOW" | grep -q '^  title: ' \
    || fail "cannot read the title of $1 to check whether it is a [captain-ask] item; it stays in the backlog"
  captain_ask_itself "$CAPTAIN_ASK_SHOW" || CAPTAIN_ASK_SHOW=''
}

# The ask itself, from a show output: the store's `ask:` line (bin/jg-beads-view.py's ask_role), which reads the captain-ask label
# and, until the one-time pass (jg-backlog.sh retag) has run, the tag at the front of an old title. A slice under an ask is not the ask.
captain_ask_itself() {  # <show-output>
  printf '%s\n' "$1" | grep -qx '  ask: ask'
}

captain_ask_root() {  # <ticket>; follow the store's parent edges in this home
  local id=$1 show parent seen=' '
  while [ -n "$id" ] && [[ $seen != *" $id "* ]]; do
    show=$(backlog_cmd show "$id" --full) || return 1
    if captain_ask_itself "$show"; then printf '%s\n' "$id"; return 0; fi
    seen+="$id "
    parent=$(printf '%s\n' "$show" | sed -n 's/^  parent: //p' | head -1)
    case $parent in *[!A-Za-z0-9._-]*) return 1 ;; esac
    id=$parent
  done
  return 1
}

# Repair filers record their origin in the store's created_by field. Titles and
# body text are descriptions, so neither can qualify a ticket for this order.
captain_ask_repair_filer() {
  case "$1" in check:repair|alert:repair) return 0 ;; *) return 1 ;; esac
}

captain_ask_filer() (  # <ticket>; read the stored actor instead of the ticket text.
  set -o pipefail
  jg_backlog_bd "$JG_HOME" show "$1" --json | jq -r '(if type == "array" then .[0] else . end).created_by // ""'
)

captain_ask_repair_order() (  # Print the standing ask only while its approval verifies.
  local order=jg-m7h show home=$JG_HOME repair_state=${STATE:?}
  if [ -e "$(jg_compat_marker "$home")" ]; then
    jg_squad_lead_parent_record_parse "$(jg_compat_parent_marker "$home")" || return 1
    [ "$JG_SQUAD_LEAD_PARENT_ROUTE" = local ] || return 1
    home=$JG_SQUAD_LEAD_PARENT_HOME
    repair_state=$home/state
  fi
  show=$(jg_backlog_beads_read "$home/config" show "$order" --full) || return 1
  captain_ask_itself "$show" || return 1
  JG_HOME="$home" STATE="$repair_state" captain_ask_build_basis "$order" "$show" >/dev/null || return 1
  printf '%s\n' "$order"
)

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
#      (his own note), backlog add and Main's plan route call it. The sig is an HMAC over the ticket id and ref under
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
  local key="${STATE:?}/captain-approval.key" tmp sig
  case "$2" in ''|*[!A-Za-z0-9._:-]*) fail "approval reference must be a plain token (a note id or answer digest): $2" ;; esac
  command -v openssl >/dev/null 2>&1 || fail "openssl is required to sign a captain approval"
  if [ ! -s "$key" ]; then
    mkdir -p "$STATE" || fail "cannot make $STATE"
    tmp=$(mktemp "$STATE/.captain-approval.XXXXXX") || fail "cannot stage captain approval key"
    if openssl rand -hex 32 > "$tmp"; then ln "$tmp" "$key" 2>/dev/null || true; fi
    rm -f "$tmp"
    [ -s "$key" ] || fail "cannot make the captain approval key at $key"
  fi
  sig=$(captain_ask_approval_sig "$1" "$2" "$key")
  [[ $sig =~ ^[a-f0-9]{64}$ ]] || fail "cannot sign the captain approval for $1"
  printf 'approved-by-captain: %s sig=%s\n' "$2" "$sig"
}

captain_ask_latest_chat() {  # print the newest chat note's id in this home
  local note latest=''
  for note in "$STATE/inbox/"*.note "$STATE/inbox/handled/"*.note; do
    [ -f "$note" ] && [ ! -L "$note" ] && [[ -z $latest || $note -nt $latest ]] || continue
    if awk '/^--$/ { if (getline > 0 && /^\[chat [^]]+\]( |$)/) ok=1; exit } END { exit !ok }' "$note"; then
      latest=$note
    fi
  done
  [ -n "$latest" ] || return 1
  note=${latest##*/}
  printf '%s\n' "${note%.note}"
}

captain_ask_route_file() {  # <show-output> [ticket]
  local file
  file=$(captain_ask_body "$1" | sed -n 's/^Captain order route: \(\/.*\)$/\1/p' | tail -1)
  if [ -z "$file" ] && [ -n "${2:-}" ] && [ -s "${STATE:?}/routed-orders/${2//./-}" ]; then
    read -r file < "$STATE/routed-orders/${2//./-}" || return 1
  fi
  printf '%s\n' "$file"
}

captain_ask_route_guard() {  # <ticket> <show-output>; accepts a routed row only on Main's signature
  local file owner=main marker
  file=$(captain_ask_route_file "$2" "$1")
  [ -n "$file" ] || return 0
  marker=$(jg_compat_marker "${JG_HOME:-}")
  if [ -f "$marker" ]; then owner=$(cat "$marker"); fi
  captain_ask_own_ref "$1" "$2" "route:$owner:" >/dev/null && return 0
  fail "cannot verify Main's approval for $1. Main must restore the lead's local parent binding or its approval key if missing, then run bin/jg-plan-route.sh $(printf '%q' "$file")"
}

captain_ask_build_gated() {  # <show-output>; 0 when a ship build needs the captain's approval
  captain_ask_itself "$1" && return 0
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

captain_ask_own_ref() {  # <ticket> <show-output>; prints the ref of the first line of the row's own body that verifies
  local key="${STATE:?}/captain-approval.key" ref sig want
  while read -r ref sig; do
    [ -n "$ref" ] || continue
    if [[ $ref != "${3:-}"* ]]; then continue; fi
    if { [[ $ref != route:* ]] || [ ! -e "$(jg_compat_marker "${JG_HOME:-}")" ]; } \
      && [ -s "$key" ] && [ "$sig" = "$(captain_ask_approval_sig "$1" "$ref" "$key")" ]; then printf '%s\n' "$ref"; return 0; fi
    if want=$(captain_ask_parent_sig "$1" "$ref") && [ "$sig" = "$want" ]; then printf '%s\n' "$ref"; return 0; fi
  done < <(captain_ask_body "$2" | sed -nE 's/^approved-by-captain: ([A-Za-z0-9._:-]+) sig=([0-9a-f]{64})$/\1 \2/p')
  return 1
}

# A workflow step row (core/workflows/set.py) that builds from a report names the owner step that gates it: `plan-approved-on: <A>`.
# The row rests on the yes of A and no other: every row R that A's metadata `wf_approved_row` names (comma separated; a council
# that stands in for the owner step), else A itself, must have the same `parent:` line as the building row and carry an
# approved-by-captain line that verifies for R's own id. One hop: R's own plan-approved-on is never followed. A row that cannot
# be read is a refusal naming it. The metadata is not in a card, so it is read through the tables' own command.
captain_ask_body_line() {  # <show-output> <key>; prints the value of the first `<key>: <value>` line of the decoded body
  captain_ask_body "$1" | sed -nE "s/^[[:space:]]*$2:[[:space:]]*([A-Za-z0-9._-]+)[[:space:]]*\$/\1/p" | head -1
}

captain_ask_plan_ref() {  # <ticket> <show-output>; prints the ref of the yes the gate row rests on
  local gate parent rows='' r rshow ref first=''
  gate=$(captain_ask_body_line "$2" plan-approved-on)
  [ -n "$gate" ] || return 1
  declare -F jg_backlog_row_show >/dev/null && [ -n "${DATA:-}" ] || return 1
  parent=$(captain_ask_body_line "$2" parent)
  [ -n "$parent" ] || return 1
  if ! rshow=$(jg_backlog_row_show "$(jg_backlog_data_absolute "$DATA")" "$gate" --full); then
    echo "approval: the plan row $gate that $1 names cannot be read" >&2
    return 1
  fi
  rows=$(JG_HOME="${JG_HOME:-}" python3 -I "${SCRIPT_DIR:?}/../core/item-store/adapters/bd_compat.py" show "$gate" --json 2>/dev/null \
    | jq -r '.[0].metadata.wf_approved_row // ""' 2>/dev/null | tr ',' ' ')
  [ -n "${rows// /}" ] || rows=$gate
  for r in $rows; do
    if ! rshow=$(jg_backlog_row_show "$(jg_backlog_data_absolute "$DATA")" "$r" --full); then
      echo "approval: the plan row $r that $1 rests on cannot be read" >&2
      return 1
    fi
    [ "$(captain_ask_body_line "$rshow" parent)" = "$parent" ] || return 1
    ref=$(captain_ask_own_ref "$r" "$rshow") || return 1
    [ -n "$first" ] || first=$ref
  done
  printf '%s\n' "$first"
}

captain_ask_approved_ref() {  # <ticket> <show-output>; prints the ref of the yes the row rests on: its own line, else its gate row's
  captain_ask_own_ref "$1" "$2" || captain_ask_plan_ref "$1" "$2"
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
  local show parent='' basis filer
  # shellcheck source=bin/jg-backlog-lib.sh
  . "$SCRIPT_DIR/jg-backlog-lib.sh" || fail "cannot load backlog access to check build approval for $1"
  show=$(jg_backlog_row_show "$(jg_backlog_data_absolute "${DATA:?}")" "$1" --full) \
    || fail "cannot read $1 to check whether a build of it needs the captain's approval: $show"
  captain_ask_route_guard "$1" "$show"
  filer=$(captain_ask_filer "$1") || fail "cannot read the filer of $1 to check repair approval"
  if captain_ask_repair_filer "$filer"; then
    basis=$(captain_ask_repair_order) || fail "$1 needs the recorded standing approval on jg-m7h"
    printf 'approval: %s starts on standing repair order %s\n' "$1" "$basis" >&2
    return 0
  fi
  captain_ask_build_gated "$show" || return 0
  if basis=$(captain_ask_build_basis "$1" "$show"); then
    printf 'approval: %s starts on %s\n' "$1" "$basis" >&2
    return 0
  fi
  # A row that names its gate (plan-approved-on:) rests on that owner step's yes, never on its parent's.
  if printf '%s\n' "$show" | grep -Eq 'born-from: *(recon|plan)([^A-Za-z]|$)' && [ -z "$(captain_ask_body_line "$show" plan-approved-on)" ]; then
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

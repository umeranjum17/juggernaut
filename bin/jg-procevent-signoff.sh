#!/usr/bin/env bash
# sign-off adapter for the generic process-to-event runner: captain answers
# given on a sign-off board come in, and captain holds go out as board cards.
#
# Usage:
#   jg-procevent-signoff.sh arm
#   jg-procevent-signoff.sh retire
#   jg-procevent-signoff.sh raise <task-id> <title> <reason> <done|release> [--must <category>]
#   jg-procevent-signoff.sh poll
#   jg-procevent-signoff.sh answers <result-file>
#   jg-procevent-signoff.sh ack <result-file>
#   jg-procevent-signoff.sh relisten
#
# arm        Opt this home in: check that sign-off-axi runs, bind the source to
#            the keyed-answer intake (bin/jg-captain-hold.sh bind), and register
#            the `signoff` source with bin/jg-procevent.sh. Nothing here runs
#            until a home arms it, so an unarmed home behaves exactly as before.
#            Arming is per home; squad_lead homes arm themselves.
# retire     Opt out: retire the registration and drop the binding.
# raise      Called by `jg-captain-hold.sh hold` after a hold is recorded. While
#            enabled it raises one board card keyed by this home's tag, the task
#            id and the hold-set stamp of that hold, so every hold gets its own
#            live card; the hold reason is its `about` and the given close
#            mode; otherwise it is a silent no-op. A failure, including a missing
#            sign-off-axi, exits nonzero with sign-off's own output; the caller
#            fails the hold command with that output (the hold stays recorded).
#            --must <category> is the board gate (bin/jg-ask-gate-lib.sh): the
#            category goes into the card's detail field, and under the
#            when-it-matters leash a raise with none is refused and recorded for
#            Overwatch (bin/jg-board-gate.sh route) instead of being posted.
# poll       The blocking child the runner executes; never run it in a
#            conversational turn. It prints one JSON object per line for each
#            deliverable answer, `{"key","answer","label","close","at"}` with the
#            bare task id as key, and exits 0. With nothing deliverable it blocks
#            in `sign-off-axi wait` for up to 600 seconds, rests when still
#            nothing is deliverable, and exits 75 with no output, the runner's
#            clean empty wait, so `relisten` polls again.
# answers    This adapter's half of the keyed-answer contract in
#            bin/jg-procevent.sh: read the captured poll lines and print
#            `<task-id>\t<answer>\t<label>\t<close>` for each, with tabs and
#            newlines inside the answer or label turned into spaces (the intake
#            stores them that way too). It records nothing.
# ack        Run by the runner only after the keyed-answer intake exits 0 or 3 for
#            this result: it records each answer in the captured poll lines as
#            delivered. The intake exits 0 when every answer was taken, and 3 when
#            every skip is permanent (the reserved reconcile value, already closed,
#            not held for the captain, unknown close mode, migrated hold whose marker
#            line matches several rows), so only a transient skip or failure leaves
#            an answer undelivered; a migrated-hold scan that cannot read its graph,
#            or an ambiguous configured-prefix match, is transient.
#
# An answer is deliverable only when its key carries this home's tag, its bare
# task id is one this home still holds for the captain (`jg-captain-hold.sh
# open --identity`), its key names that hold's current stamp, and it was not
# already acknowledged. The open hold is the cursor: an answer saved while no
# poll ran is still found on the next round, and an answer on an earlier card
# never resolves a re-held task. An answer the intake fails on, or skips for a transient reason, stays
# deliverable and is offered again on the next round. Answers on the same board from other
# agents are never read as Juggernaut's. What an answer DOES is owned by the
# keyed-answer intake in bin/jg-captain-hold.sh; this adapter maps nothing and
# closes nothing.
#
# Board keys are `jg-<tag>-<task-id>-<stamp>`, where <tag> is a stable digest of
# JG_HOME and <stamp> is the hold-set stamp in alphanumerics only. The default
# board is shared by every home on the machine, so the tag keeps one home from
# being handed another home's answer, and the stamp gives each hold occurrence
# its own card. sign-off-axi must be on PATH: without it `arm`
# refuses, and `raise` prints an install hint and fails, so a hold is kept and
# fails the hold command. Cards and answers use sign-off's default board
# (~/.sign-off/decisions.json), the one `sign-off-axi open` shows.
# ponytail: one default board per machine; add a board option when a home needs its own.
# sign-off-axi has no command to withdraw a card, so a hold answered through
# another channel leaves its card waiting on the board.
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
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
export JG_HOME

# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-procevent-lib.sh
. "$SCRIPT_DIR/jg-procevent-lib.sh"
# shellcheck source=bin/jg-ask-gate-lib.sh
. "$SCRIPT_DIR/jg-ask-gate-lib.sh"
# shellcheck source=bin/jg-board-record-lib.sh
. "$SCRIPT_DIR/jg-board-record-lib.sh"

SOURCE_ID=signoff
DELIVERED="$STATE/signoff-delivered"
# How long a round rests when nothing is deliverable after a wait (no board yet,
# nothing waiting, or the tool failing), so an idle home does not spin.
IDLE_REST=30
WAIT_SECS=600

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

signoff() {
  command -v sign-off-axi >/dev/null 2>&1 \
    || { printf 'sign-off-axi is not on PATH; install it from https://github.com/umeranjum17/sign-off\n' >&2; return 127; }
  sign-off-axi "$@"
}

home_key_prefix() {
  printf 'jg-%s-' "$(printf '%s' "$JG_HOME" | cksum | awk '{printf "%08x", $1}')"
}

stamp_token() { printf '%s' "$1" | tr -cd 'A-Za-z0-9'; }

cmd_enabled() { [ -f "$(jg_procevent_registry_dir "$STATE")/$SOURCE_ID.source" ]; }

cmd_arm() {
  local out
  out=$(signoff --version 2>&1) \
    || die "sign-off-axi does not run here: $out"
  "$SCRIPT_DIR/jg-captain-hold.sh" bind "$SOURCE_ID" >/dev/null || die "could not bind $SOURCE_ID to the keyed-answer intake"
  "$SCRIPT_DIR/jg-procevent.sh" register signoff "$SOURCE_ID" -- "$SCRIPT_DIR/jg-procevent-signoff.sh" poll || exit 1
  printf 'armed: %s\nsign-off-axi: %s\n' "$SOURCE_ID" "$out"
}

cmd_retire() {
  "$SCRIPT_DIR/jg-procevent.sh" retire "$SOURCE_ID" || exit 1
  "$SCRIPT_DIR/jg-captain-hold.sh" unbind "$SOURCE_ID" >/dev/null || exit 1
}

ANSWER_NOTE='Answer yes or no. The hold stays open until you answer.'

# Card text per sign-off's question standard.
strip_tags() {
  local s=$1 prev=
  while [ "$s" != "$prev" ]; do
    prev=$s
    s=$(printf '%s' "$s" | sed -E 's/^[[:space:]]*(\[[^]]*\]|[Cc][Aa][Pp][Tt][Aa][Ii][Nn] [Hh][Oo][Ll][Dd]:|[Cc][Aa][Pp][Tt][Aa][Ii][Nn]:|[Ss][Aa][Yy] [Yy][Ee][Ss] [Oo][Rr] [Nn][Oo]:)[[:space:]]*//')
  done
  printf '%s' "$s"
}

card_flat() {
  printf '%s' "$1" | tr '\t\n' '  ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

card_title() {  # <reason>; prints the last question sentence, or the first sentence when it has none; empty when nothing is left
  local flat head sentence
  flat=$(card_flat "$1")
  head=$(printf '%s' "$flat" | sed -nE 's/^(.*\?)( |$).*/\1/p')
  if [ -n "$head" ]; then
    sentence=$(printf '%s' "${head%\?}" | sed -E 's/^(.*(\. |\? ))?//')
  else
    sentence=$(printf '%s' "$flat" | sed -E 's/[.!] .*$//')
  fi
  title=$(strip_tags "$sentence" | sed -E 's/[[:space:].?!]+$//' | awk '{n = NF < 12 ? NF : 12; for (i = 1; i <= n; i++) printf "%s%s", $i, i < n ? " " : ""}')
  [ -n "$title" ] && printf '%s?' "$title"
  return 0
}

card_why() {  # <reason>
  printf '%s %s' "$(card_flat "$1" | cut -c1-$((200 - ${#ANSWER_NOTE} - 1)))" "$ANSWER_NOTE"
}

built_title() {  # <task-title>
  local words
  words=$(strip_tags "$(card_flat "$1")" | tr -d '?' | awk '{n = NF < 6 ? NF : 6; for (i = 1; i <= n; i++) printf "%s%s", $i, i < n ? " " : ""}')
  printf 'What is your call on %s?' "$words"
}

cmd_raise() {
  local out identity title rc=0 must='' refusal rec args=() detail=() ticket='' card_key=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --must) shift; must=${1-}; [ -n "$must" ] || usage ;;
      *) args+=("$1") ;;
    esac
    shift
  done
  [ "${#args[@]}" -eq 4 ] || usage
  set -- "${args[@]}"
  cmd_enabled || return 0
  # The card rules (bin/jg-ask-gate-lib.sh) come first, because a hold his own
  # stop order created, or one worded in our own vocabulary, is not a question
  # for him at all. Then the must gate: a card carries its category in its
  # detail field, and under the when-it-matters leash nothing else is raised.
  title=$(card_title "$3")
  [ -n "$title" ] || title=$(built_title "$2")
  refusal=$(jg_ask_card_refusal "$1" 2 "$title" "$3") || true
  [ -n "$refusal" ] || refusal=$(jg_ask_gate_refusal "$must") || true
  if [ -n "$refusal" ]; then
    rec=$("$SCRIPT_DIR/jg-board-gate.sh" route --title "$3" --filer signoff --ref "$1" 2>&1) || rec=''
    printf '%s\n' "$refusal" >&2
    [ -z "$rec" ] || printf 'recorded for Overwatch: %s\n' "${rec#overwatch: }" >&2
    return 1
  fi
  [ -z "$must" ] || detail=(--detail "must: $must")
  identity=$("$SCRIPT_DIR/jg-captain-hold.sh" open "$1" --identity 2>/dev/null) || {
    printf 'sign-off card not raised: the hold identity of %s could not be read\n' "$1" >&2
    return 1
  }
  # Name the ticket the board shows, so the reason this hold records renders
  # beside that ticket's On hold row (bin/jg-ticket.sh owns the ticket id).
  ticket=$("$SCRIPT_DIR/jg-ticket.sh" id "$1" 2>/dev/null) || ticket=''
  [ -z "$ticket" ] || detail+=(--ticket "$ticket")
  card_key="$(home_key_prefix)$1-$(stamp_token "${identity%%#*}")"
  out=$(signoff raise --key "$card_key" \
    --title "$title" --ask-ref "$1" --about "$3" --why "$(card_why "$3")" \
    ${detail[@]+"${detail[@]}"} \
    --outcome yes="Answer recorded: yes." \
    --outcome no="Answer recorded: no." \
    --recommend yes --recommend-reason "The hold records no recommendation." \
    --default no --close "$4" 2>&1) || rc=$?
  case "$out" in
    *"already answered"*)
      printf 'sign-off card for %s is already answered; reusing it\n' "$1" >&2
      return 0
      ;;
    *"already holds a different question"*)
      printf 'sign-off card for %s already exists with another question; keeping it\n' "$1" >&2
      return 0
      ;;
  esac
  [ "$rc" -eq 0 ] || {
    printf 'sign-off-axi raise failed: %s\n' "$out" >&2
    return 1
  }
  # The must category rides in the card's detail field, and a feed rebuild writes
  # its own detail. Record it beside the board too, so the category outlives a
  # rebuild (bin/jg-board-record-lib.sh).
  if [ -n "$must" ] && [ -n "$card_key" ]; then
    board_now=$(jg_question_board)
    [ -z "$board_now" ] \
      || jg_board_detail_record "$board_now" "$card_key" "must: $must" \
      || printf 'sign-off card %s raised but its must category was not recorded beside the board\n' "$card_key" >&2
  fi
  printf 'sign-off card on the board for %s\n' "$1" >&2
}

# Print every deliverable answer as one JSON object per line, keyed by bare task id.
deliverable() {
  local json prefix line key stamp answer at identity
  prefix=$(home_key_prefix)
  json=$(signoff answers --json 2>/dev/null) || return 0
  printf '%s\n' "$json" \
    | jq -c --arg prefix "$prefix" '
        to_entries[] | select(.key | startswith($prefix))
        | (.key[($prefix | length):]) as $rest
        | {key: ($rest | sub("-[^-]*$"; "")), stamp: ($rest | sub("^.*-"; "")), answer: (.value.answer // ""), label: (.value.label // ""), close: (.value.close // ""), at: (.value.at // "")}' 2>/dev/null \
    | while IFS= read -r line; do
        key=$(jq -r '.key' <<<"$line")
        stamp=$(jq -r '.stamp' <<<"$line")
        answer=$(jq -r '.answer' <<<"$line")
        at=$(jq -r '.at' <<<"$line")
        jg_procevent_source_id_valid "$key" && [ -n "$answer" ] && [ -n "$at" ] || continue
        [ ! -f "$DELIVERED" ] || ! grep -qxF "$key"$'\t'"$at" "$DELIVERED" || continue
        identity=$("$SCRIPT_DIR/jg-captain-hold.sh" open "$key" --identity 2>/dev/null) || continue
        [ "$stamp" = "$(stamp_token "${identity%%#*}")" ] || continue
        jq -c 'del(.stamp)' <<<"$line"
      done
}

cmd_poll() {
  local found
  [ "$#" -eq 0 ] || usage
  found=$(deliverable)
  if [ -z "$found" ]; then
    signoff wait --json --timeout "$WAIT_SECS" >/dev/null 2>&1
    found=$(deliverable)
    [ -n "$found" ] || sleep "$IDLE_REST"
  fi
  [ -n "$found" ] || exit 75
  printf '%s\n' "$found"
}

cmd_answers() {
  local file=${1-} line key answer at
  [ -f "$file" ] || die "result file does not exist: $file"
  while IFS= read -r line; do
    key=$(jq -r '.key' <<<"$line")
    answer=$(jq -r '.answer' <<<"$line")
    at=$(jq -r '.at' <<<"$line")
    jg_procevent_source_id_valid "$key" && [ -n "$answer" ] && [ -n "$at" ] || continue
    jq -r '[.key, .answer, .label, .close] | map(gsub("[\n\r\t]"; " ")) | join("\t")' <<<"$line"
  done < "$file"
}

cmd_ack() {
  local file=${1-} line key at
  [ -f "$file" ] || die "result file does not exist: $file"
  while IFS= read -r line; do
    key=$(jq -r '.key' <<<"$line")
    at=$(jq -r '.at' <<<"$line")
    jg_procevent_source_id_valid "$key" && [ -n "$at" ] || continue
    printf '%s\t%s\n' "$key" "$at" >> "$DELIVERED"
  done < "$file"
}

case "${1-}" in
  arm) shift; cmd_arm "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  raise) shift; cmd_raise "$@" ;;
  poll) shift; cmd_poll "$@" ;;
  answers) shift; cmd_answers "$@" ;;
  ack) shift; cmd_ack "$@" ;;
  relisten) exit 0 ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac

#!/usr/bin/env bash
# jg-question-card.sh - post the board card for a question to the owner, then
# print its key so the reply can cite it.
#
# Usage:
#   jg-question-card.sh post --ask-ref <ref> --title "<one question>" [sign-off-axi raise flags...]
#   jg-question-card.sh post --board <decisions.json> ... (the same flags)
#   jg-question-card.sh post --route <lead> [--decision-key <slug>] ... (the same flags)
#   jg-question-card.sh post --must design-pick --raised-by <ticket> ... (a design card)
#   jg-question-card.sh answer <card-key> --words "<the captain's words>" [--board <decisions.json>]
#   jg-question-card.sh keys
#
# The owner's rule (2026-10-25): "if you ask questions as well make sure they
# are posted, posting questions will be stricter way of working". A question to
# him must exist as a board card, and a chat-only question is a violation.
# bin/jg-turnend-guard.sh flags a reply that ends in a question while no open
# card is cited, and its banner points here.
#
# post   Post the question through sign-off-axi (this command re-implements none
#        of its question standard, options, outcomes or board rules - pass its
#        own flags through: --why, --outcome yes=..., --recommend, --default,
#        --option, --silent-by, --filer, ...), then print the card key alone on
#        stdout. Everything sign-off-axi prints goes to stderr. It refuses
#        without --title and --ask-ref, because a new Decide card needs both.
#        His board is his decisions alone, and bin/jg-ask-gate-lib.sh owns the
#        rules applied here: one plain question about the product or about
#        money, two clear options, and nothing internal in the words - no Main
#        number, no task, lane, hook, card or file name, no path. A stop-order
#        hold and a stuck worker are never cards. A card a rule refuses is
#        printed as one line naming the rule, recorded for Main, and not posted.
#        When the identical question is already open under a key, that key is
#        printed instead of posting a second card.
#        --route <lead> names the lead (a task id in this home) that owns the
#        question; the board-answers check (bin/jg-board-answers.sh) then sends
#        the answer straight to that lead and closes its decision <slug>
#        (default: the card key). Cards Main files for a lead name it. Neither
#        flag reaches sign-off-axi.
#        With no --route, the lead is found from the card's own names: the
#        --decision-key, --key or --ask-ref that is a task recorded in this home
#        or an open decision of one. No single match refuses the post and names
#        the flag: pass --route <lead>, or --route main for a card Main owns
#        (its answer then wakes Main, as before).
#        A design card (--must design-pick) must name the ticket that raised it
#        with --raised-by <ticket>, a task in this home's backlog; without one,
#        or with one this home lacks, the post is refused and nothing is posted.
#        The post also files a `[design-ux]` backlog row keyed by the card and
#        linked to that ticket (bin/jg-captain-hold.sh design-card), so the open
#        pick stops the ticket's merge and its linked work; the answer closes the
#        row (bin/jg-board-answers.sh). A card a script files as an alert, with
#        --filer, is not a design ask and is exempt. Only this path files the row: a card posted
#        straight through sign-off-axi, or into another home's board, does not.
#        --must <category> is the gate (bin/jg-ask-gate-lib.sh): it is written
#        into the card's detail field as "must: <category>", and on the
#        when-it-matters leash a post with none is refused and recorded for
#        Overwatch (bin/jg-board-gate.sh route) instead of posted.
#        --record <url> is the card's deep link to its full record, written into
#        the detail field because raise has no link flag. The two-layer check is
#        shadow-first: it names the failing rule, logs it, and posts the card.
# answer Record the captain's chat answer on its card, in the same turn he gave
#        it: sign-off-axi has no command for this, so the line sign-off-axi
#        itself writes for a board answer is appended to the board's answers log
#        (answer = his exact words, label "Answered in chat"). The card then
#        reads as answered, and the board-answers check (bin/jg-board-answers.sh)
#        carries it to the lead that owns a routed card, or skips the wake for an
#        unrouted one since Main heard it first. Refused for a key that is not an
#        open card. bin/jg-turnend-guard.sh flags a turn that ends after a chat
#        answer while its card still waits, in Main and lead homes alike.
# keys   Print the key of every card still open on the board.
#
# The board is the one sign-off-axi reads: the explicit --board file, else the
# board sign-off-axi's own walk finds. Nothing here stores a private copy.
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
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/jg-question-lib.sh
. "$SCRIPT_DIR/jg-question-lib.sh"
# shellcheck source=bin/jg-ask-gate-lib.sh
. "$SCRIPT_DIR/jg-ask-gate-lib.sh"
# shellcheck source=bin/jg-board-link-lib.sh
. "$SCRIPT_DIR/jg-board-link-lib.sh"
# shellcheck source=bin/jg-board-record-lib.sh
. "$SCRIPT_DIR/jg-board-record-lib.sh"
# shellcheck source=bin/jg-captain-card-lib.sh
. "$SCRIPT_DIR/jg-captain-card-lib.sh"
# shellcheck source=bin/jg-classify-lib.sh
. "$SCRIPT_DIR/jg-classify-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'jg-question-card: %s\n' "$1" >&2; exit 1; }

require_signoff() {
  jg_question_signoff_available \
    || die "sign-off-axi is not on PATH; install it from https://github.com/umeranjum17/sign-off"
  command -v jq >/dev/null 2>&1 || die "jq is required to read the board"
}

# Split --board out of the pass-through arguments: sign-off-axi takes the board
# file as its positional argument, before every flag.
split_board() {
  BOARD=''
  ROUTE=''
  DECISION_KEY=''
  MUST=''
  RECORD=''
  RAISED=''
  ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --board)
        shift
        [ $# -gt 0 ] || die "--board needs a value"
        BOARD=$1
        ;;
      --record)
        shift
        [ $# -gt 0 ] || die "--record needs a link to the full record"
        RECORD=$1
        ;;
      --route)
        shift
        [ $# -gt 0 ] || die "--route needs a lead task id"
        ROUTE=$1
        ;;
      --decision-key)
        shift
        [ $# -gt 0 ] || die "--decision-key needs a key"
        DECISION_KEY=$1
        ;;
      --raised-by)
        shift
        [ $# -gt 0 ] || die "--raised-by needs the ticket that raised the card"
        RAISED=$1
        ;;
      --must)
        shift
        [ $# -gt 0 ] || die "--must needs a category ($(jg_ask_categories_words))"
        MUST=$1
        ;;
      *) ARGS+=("$1") ;;
    esac
    shift
  done
}

# The lead that owns this card, found from the names the card carries: a task of
# this home called by one of them, or one whose status has that key as an open
# decision. Sets ROUTE (and DECISION_KEY for a matched open decision); returns
# 1 unless exactly one task matches.
resolve_owner_lead() {
  local state=${JG_STATE_OVERRIDE:-${JG_HOME:-/nonexistent}/state} meta id c found='' n=0 dk=''
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    for c in "$DECISION_KEY" "$(flag_value --key)" "$(flag_value --ask-ref)" "$RAISED"; do
      [ -n "$c" ] || continue
      if [ "$id" = "$c" ] || status_open_decisions "$state/$id.status" 2>/dev/null | grep -q "^$c"$'\t'; then
        [ "$id" = "$c" ] || dk=$c
        found=$id; n=$((n + 1))
        break
      fi
    done
  done
  [ "$n" -eq 1 ] || return 1
  ROUTE=$found
  [ -n "$DECISION_KEY" ] || DECISION_KEY=$dk
}

set_detail() {  # <value>: keep exactly one --detail pair in ARGS
  local out=() i=0
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    if [ "${ARGS[$i]}" = --detail ]; then i=$((i + 2)); continue; fi
    out+=("${ARGS[$i]}")
    i=$((i + 1))
  done
  ARGS=(${out[@]+"${out[@]}"} --detail "$1")
}

flag_value() {  # <flag> -> the value that follows it
  local want=$1 i=0
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    if [ "${ARGS[$i]}" = "$want" ]; then
      printf '%s\n' "${ARGS[$((i + 1))]:-}"
      return 0
    fi
    i=$((i + 1))
  done
  return 0
}

option_count() {  # -> how many --outcome/--option entries ARGS carries
  local i=0 n=0
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    case "${ARGS[$i]}" in --outcome|--option) n=$((n + 1)) ;; esac
    i=$((i + 1))
  done
  printf '%s
' "$n"
}

option_text() {  # -> every option's label and outcome, as one line of card text
  local i=0 words=''
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    case "${ARGS[$i]}" in --outcome|--option) words="$words ${ARGS[$((i + 1))]:-}" ;; esac
    i=$((i + 1))
  done
  printf '%s\n' "$words"
}

# A card the gate refuses is still an ask this home owes an answer to, so it is
# recorded for Overwatch (bin/jg-board-gate.sh route) and never posted.
refuse() {  # <the refusal line>
  local filer rec
  filer=$(flag_value --filer)
  rec=$("$SCRIPT_DIR/jg-board-gate.sh" route --title "$(flag_value --title)" --filer "${filer:-${SIGN_OFF_FILER:-unknown}}" --ref "$(flag_value --ask-ref)" 2>&1) \
    || rec=''
  printf '%s\n' "$1" >&2
  [ -z "$rec" ] || printf 'recorded for Overwatch: %s\n' "${rec#overwatch: }" >&2
  exit 1
}

cmd_post() {
  local title ask_ref before after key board out link rc=0 refusal rec filer detail raised_rc RECORD=''
  split_board "$@"
  require_signoff
  title=$(flag_value --title)
  ask_ref=$(flag_value --ask-ref)
  [ -n "$title" ] || die "refused: post needs --title \"<the one question>\"; it is the card's title"
  [ -n "$ask_ref" ] || die "refused: post needs --ask-ref <the owner message or hold this question answers>; sign-off-axi requires it for a new Decide card"

  # The card rules (bin/jg-ask-gate-lib.sh): his board carries his decisions
  # only, so a stop-order hold, a stuck worker, an internal name or a card with
  # no two clear options is refused here, by rule, before sign-off-axi sees it.
  refusal=$(jg_ask_card_refusal "$ask_ref" "$(option_count)" "$title" \
    "$(flag_value --why)" "$(flag_value --about)" "$(flag_value --detail)" "$(option_text)") || true
  [ -z "$refusal" ] || refuse "$refusal"

  # The card's deep link to its record rides in its detail field, rule 4 of
  # bin/jg-captain-card-lib.sh, because sign-off-axi's raise has no link flag.
  if [ -n "$RECORD" ]; then
    detail=$(flag_value --detail)
    set_detail "${detail:+$detail }record: $RECORD"
  fi

  # The board gate (bin/jg-ask-gate-lib.sh): the card's detail field carries its
  # must category, and under the when-it-matters leash no other ask is posted.
  if [ -n "$MUST" ]; then
    detail=$(flag_value --detail)
    [ "$(jg_ask_card_category "$detail")" = "$MUST" ] || detail="${detail:+$detail }must: $MUST"
    set_detail "$detail"
  else
    MUST=$(jg_ask_card_category "$(flag_value --detail)")
  fi
  if ! refusal=$(jg_ask_gate_refusal "$MUST" "$BOARD"); then
    refuse "$refusal"
  fi

  # A design card names the ticket that raised it, so the open pick can stop that
  # ticket's merge (bin/jg-captain-hold.sh design-card); checked before anything posts.
  if [ "$MUST" = design-pick ] && [ -z "$(flag_value --filer)" ]; then
    [ -n "$RAISED" ] || die "refused: a design card must name the ticket that raised it; pass --raised-by <ticket>"
    raised_rc=0
    "$SCRIPT_DIR/jg-captain-hold.sh" open "$RAISED" --distinguish-absent >/dev/null 2>&1 || raised_rc=$?
    case "$raised_rc" in 0|1) ;; 3) die "refused: --raised-by '$RAISED' is not a ticket in this home's backlog" ;; *) die "refused: could not read this home's backlog to check --raised-by '$RAISED'" ;; esac
  fi

  if [ "$ROUTE" = main ]; then
    # An explicit Main-owned card: its answer wakes Main, so no lead is recorded.
    ROUTE=''
    [ -z "$DECISION_KEY" ] || die "refused: --decision-key closes a lead's decision, so it cannot go with --route main"
  elif [ -z "$ROUTE" ]; then
    resolve_owner_lead \
      || die "refused: no single lead owns this card; pass --route <lead> (a task id in this home), or --route main for a card Main owns"
  fi
  [ -z "$DECISION_KEY" ] || [ -n "$ROUTE" ] || die "refused: --decision-key only closes a lead's decision, so it needs --route <lead>"
  # Check the lead first: a refused route must not leave an unrouted card behind.
  [ -z "$ROUTE" ] || [ -f "${JG_STATE_OVERRIDE:-${JG_HOME:-/nonexistent}/state}/$ROUTE.meta" ] \
    || die "refused: --route '$ROUTE' is not a task recorded in this home (is JG_HOME set?)"
  # The two-layer check (bin/jg-captain-card-lib.sh): shadow-first, so a card that
  # still falls short of the card layer is named and logged, then posted.
  jg_captain_card_shadow card \
    "$(printf '%s\n%s\n%s\n%s' "$title" "$(flag_value --why)" "$(flag_value --detail)" "$(option_text)")" \
    "$(option_count)"

  before=$(jg_question_open_keys)
  if [ -n "$BOARD" ]; then
    out=$(sign-off-axi raise "$BOARD" ${ARGS[@]+"${ARGS[@]}"} 2>&1) || rc=$?
  else
    out=$(sign-off-axi raise ${ARGS[@]+"${ARGS[@]}"} 2>&1) || rc=$?
  fi
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || die "sign-off-axi refused the card (exit $rc); fix the flag it named and post again"

  after=$(jg_question_open_keys)
  key=$(comm -13 <(printf '%s\n' "$before" | sed '/^$/d' | LC_ALL=C sort) \
                <(printf '%s\n' "$after" | sed '/^$/d' | LC_ALL=C sort) | head -1)
  if [ -z "$key" ]; then
    # No new open key means sign-off kept a card that already exists under the
    # key we asked for (the same question again, or its answer): that card is
    # this post's card, so cite it instead of another open one.
    key=$(flag_value --key)
    [ -n "$key" ] || key=$(printf '%s\n' "$after" | sed '/^$/d' | head -1)
    [ -n "$key" ] || die "sign-off-axi accepted the card but the board shows no open card; run sign-off-axi status and report this"
  fi
  [ -z "$ROUTE" ] || "$SCRIPT_DIR/jg-board-answers.sh" route "$key" "$ROUTE" "$DECISION_KEY" >&2 \
    || die "the card $key is posted but its route to $ROUTE was not recorded; run jg-board-answers.sh route $key $ROUTE"
  { [ "$MUST" != design-pick ] || [ -n "$(flag_value --filer)" ]; } || "$SCRIPT_DIR/jg-captain-hold.sh" design-card "$key" --raised-by "$RAISED" --title "$title" >&2 \
    || die "the card $key is posted but its design row was not filed; run jg-captain-hold.sh design-card $key --raised-by $RAISED --title ..."
  # The detail field is where the card's must category lives, and a rebuild of
  # the feed writes its own detail. Record it beside the board as well, so the
  # category outlives any rebuild (bin/jg-board-record-lib.sh).
  detail=$(flag_value --detail)
  if [ -n "$(jg_ask_card_category "$detail")" ]; then
    board_now=${BOARD:-$(jg_question_board)}
    [ -z "$board_now" ] \
      || jg_board_detail_record "$board_now" "$key" "$detail" \
      || printf 'jg-question-card: posted %s but could not record its detail beside the board\n' "$key" >&2
  fi
  printf '%s\n' "$key"
  link=$(jg_board_link decide "$key") && printf 'link: %s\n' "$link" >&2
  # The captain channel sends this card to the captain by the new path
  # (bin/jg-bus.sh): it records and publishes the event and changes
  # nothing the board does.
  # Each --option value=label becomes a button in the chat; a card with none is yes or no.
  local opts=() i=0
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    [ "${ARGS[$i]}" != --option ] || opts+=(--option "${ARGS[$((i + 1))]:-}")
    i=$((i + 1))
  done
  [ "${#opts[@]}" -gt 0 ] || opts=(--option yes=Yes --option no=No)
  "$SCRIPT_DIR/jg-bus.sh" publish card "$key" "$title" "${opts[@]}" ${link:+--link "$link"} >/dev/null 2>&1 || true
  return 0
}

cmd_answer() {
  local key='' words='' board log close at state seen
  while [ $# -gt 0 ]; do
    case "$1" in
      --words) shift; [ $# -gt 0 ] || die "--words needs the captain's words"; words=$1 ;;
      --board) shift; [ $# -gt 0 ] || die "--board needs a value"; BOARD=$1 ;;
      -*) die "answer: unknown flag $1" ;;
      *) [ -z "$key" ] || die "answer takes one card key"; key=$1 ;;
    esac
    shift
  done
  [ -n "$key" ] || die "answer needs a card key (jg-question-card.sh keys lists them)"
  [ -n "$words" ] || die "refused: answer needs --words \"<the captain's exact words>\""
  require_signoff
  jg_question_open_keys | grep -qxF -- "$key" || die "refused: '$key' is not a card still open on the board"
  [ -n "${BOARD:-}" ] || BOARD=$(jg_question_board)
  [ -n "$BOARD" ] || BOARD=$HOME/.sign-off/decisions.json
  [ -f "$BOARD" ] || die "no board file at $BOARD"
  log=$(jg_question_answers_log "$BOARD")
  close=$(jq -r --arg k "$key" '[(.items // .decisions // [])[]? | select(.key == $k) | .close][0] // "done"' "$BOARD" 2>/dev/null)
  [ -n "$close" ] || close="done"
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -cn --arg k "$key" --arg a "$words" --arg c "$close" --arg at "$at" \
    '{key: $k, answer: $a, label: "Answered in chat", close: $c, at: $at}' >> "$log" \
    || die "cannot write the answer to $log"
  # Main heard this answer first: an unrouted card needs no wake saying so.
  state=${JG_STATE_OVERRIDE:-${JG_HOME:-}/state}
  seen=$state/.board-answers-seen
  if [ -n "${JG_HOME:-${JG_STATE_OVERRIDE:-}}" ] && [ -f "$seen" ] && [ ! -f "$state/board-routes/$key" ]; then
    printf '%s\t%s\n' "$key" "$at" >> "$seen"
  fi
  "$SCRIPT_DIR/jg-bus.sh" publish card-close "$key" "answered" --answer "$words" >/dev/null 2>&1 || true
  printf 'answered: %s\n' "$key"
}

cmd_keys() {
  require_signoff
  jg_question_open_keys
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  post) cmd_post "$@" ;;
  answer) cmd_answer "$@" ;;
  keys) cmd_keys ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac

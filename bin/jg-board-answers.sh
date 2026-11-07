#!/usr/bin/env bash
# jg-board-answers.sh - carry each board answer to the lead that needs it, as a
# standing watcher check, so no answer waits on Main reading it.
#
# Usage:
#   jg-board-answers.sh route <card-key> <lead> [<decision-key>]
#   jg-board-answers.sh route-answer <card-key> <at> <answer> [<label>]
#   jg-board-answers.sh [check|poll]
#   jg-board-answers.sh arm | rearm | disarm
#   jg-board-answers.sh tick
#
# route  Record that <lead> (a task id in this home) owns the card; written by
#        `jg-question-card.sh post --route <lead> [--decision-key <slug>]`. The
#        decision key defaults to the card key.
# route-answer
#        Take ONE answer to its routed lead now, with the same marked line and
#        the same decision close the check sends, and record it as answered so
#        a later pass does not send it twice. This is the route a captain reply
#        that arrives from the bus (bin/jg-bus.sh reply) takes, so a reply is
#        routed by exactly the rule a board answer is routed by. It refuses a
#        card with no route: that answer stays with Main, as it does today.
#        Prints `routed: <card-key> -> <lead>` on success.
# check  One deterministic pass, no model. Read the board's answers through
#        sign-off-axi, then for each:
#          ROUTED: send the lead one marked answer line (card key, answer, time,
#            card link) with bin/jg-send.sh, closing the lead's open decision
#            key with --resolve-key (a squad_lead with no open key gets a
#            fire-and-forget line); Main gets one `info:` line. A failed send is
#            retried each pass and reported once. When the lead moves that
#            record to its inbox's handled/ (the acknowledgement), the card is
#            archived (dismiss, done-elsewhere).
#          UNROUTED: raise one check wake for Main in this pass (answer text
#            first); the line is printed instead only when the wake cannot be
#            raised, so the answer is never lost. Reported once; answers already
#            on the board at the first pass are recorded, not reported.
# arm    Write state/board-answers.check.sh, bind it with jg-check-register.sh,
#        and run one pass; a report that pass makes is printed, never dropped.
#        rearm is the same without the pass. disarm removes the shim and its
#        trust binding and leaves a marker so tick does not arm it again.
# tick   What the watcher runs every JG_FAST_CHECK_INTERVAL seconds (30), apart
#        from its slow check sweep, so an answer wakes within the minute. Heals
#        first: a registration that is missing, unbound, edited or not private
#        is re-armed, and when that fails ONE line names the check and the
#        cause (state/.board-answers-rearm-alert holds it until it recovers).
#        Then one `check` pass. An unreadable board is reported once, not on
#        every tick. A re-arm is logged to state/board-answers.rearm.log. A
#        Squad Lead home, or a state directory that is not this home's own,
#        is never armed by tick.
# A design card (jg-question-card.sh post --must design-pick) also has a marker
# state/design-cards/<card-key>; its answer is recorded on the card's backlog row
# (jg-captain-hold.sh design-pick), which releases the work linked to it.
# State: state/board-routes/<card-key>, state/.board-answers-seen. Unrouted keys
# starting `jg-` belong to the captain-hold card adapter and are skipped.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
ROUTES="$STATE/board-routes"
SEEN="$STATE/.board-answers-seen"
CLOSED="$STATE/.board-answers-card-closed"
SHIM="$STATE/board-answers.check.sh"
DISARMED="$STATE/.board-answers-disarmed"
ALERTED="$STATE/.board-answers-rearm-alert"
UNREADABLE="$STATE/.board-answers-unreadable"
# shellcheck source=bin/jg-compat.sh
. "$SCRIPT_DIR/jg-compat.sh"
# shellcheck source=bin/jg-question-lib.sh
. "$SCRIPT_DIR/jg-question-lib.sh"
# shellcheck source=bin/jg-board-link-lib.sh
. "$SCRIPT_DIR/jg-board-link-lib.sh"
# shellcheck source=bin/jg-classify-lib.sh
. "$SCRIPT_DIR/jg-classify-lib.sh"
# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"
# shellcheck source=bin/jg-check-lib.sh
. "$SCRIPT_DIR/jg-check-lib.sh"
die() { printf 'jg-board-answers: %s\n' "$1" >&2; exit "${2:-1}"; }
key_ok() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
rget() { sed -n "s/^$2=//p" "$ROUTES/$1" 2>/dev/null | tail -1; }
rput() { printf '%s=%s\n' "$2" "$3" >> "$ROUTES/$1"; }
say() { printf '%s\n' "${1:0:400}"; }

cmd_route() {
  local key=${1-} lead=${2-} dk=${3-}
  { key_ok "$key" && key_ok "$lead"; } || die "route needs a card key and a lead task id" 2
  [ -z "$dk" ] || key_ok "$dk" || die "invalid decision key '$dk'" 2
  [ -f "$STATE/$lead.meta" ] || die "refused: '$lead' is not a task recorded in this home"
  mkdir -p "$ROUTES" || die "cannot create $ROUTES"
  printf 'lead=%s\ndecision=%s\n' "$lead" "${dk:-$key}" > "$ROUTES/$key" || die "cannot record the route for $key"
}

deliver() {  # <key> <lead> <decision> <text> <delivery-id>; 0 = recorded in the lead's inbox
  local key=$1 lead=$2 dk=$3 text=$4 id=$5 args=()
  if [ -n "$dk" ] && status_open_decisions "$STATE/$lead.status" 2>/dev/null | grep -q "^$dk"$'\t'; then
    args=(--resolve-key "$dk")
  elif jg_compat_meta_is_squad_lead "$STATE/$lead.meta"; then
    args=(--fire-and-forget "$id")
  fi
  JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/jg-send.sh" "$lead" ${args[@]+"${args[@]}"} "$text" 2>&1
}

# The one owner of the marked answer line a lead reads. A board answer and a
# captain reply that arrived on the bus are the same event, so both send the
# captain's words in the one shape the lead's acknowledgement looks for.
answer_text() {  # <key> <at> <answer> <label> <note> <link>
  printf 'board-answer [key=%s at=%s]: the captain answered "%s"%s%s.%s Move this record to handled/ to acknowledge; no other reply is owed.' \
    "$1" "$2" "$3" "${4:+ ($4)}" "${5:+ - note: $5}" "${6:+ Card: $6.}"
}

# A design card's answer closes its backlog row, which releases the work linked to it
# (bin/jg-captain-hold.sh design-pick). Only a card with a marker pays for the backlog read.
designed() {  # <card-key> <answer>
  [ -f "$STATE/design-cards/$1" ] || return 0
  "$SCRIPT_DIR/jg-captain-hold.sh" design-pick "$1" --words "$2" >/dev/null 2>&1 || true
}

# A board that cannot be read is said in full by `check`; under `tick` (a pass
# every half minute) the same words are said once and again only after a pass
# that read the board, so a missing tool cannot wake Main every tick.
unreadable() {
  if [ -z "${BOARD_ANSWERS_TICK:-}" ]; then say "$1"; return; fi
  [ "$(cat "$UNREADABLE" 2>/dev/null)" = "$1" ] && return
  printf '%s\n' "$1" > "$UNREADABLE" 2>/dev/null || true
  say "$1"
}

cmd_check() {
  local json board key answer label note at lead dk link text id out first=0 report='' shown
  jg_question_signoff_available || { unreadable "board answers cannot be read: sign-off-axi is not on PATH"; return 0; }
  board=$(jg_question_board)
  json=$(sign-off-axi answers ${board:+"$board"} --json 2>/dev/null) || { unreadable "board answers cannot be read: sign-off-axi answers failed"; return 0; }
  rm -f -- "$UNREADABLE"
  [ -f "$SEEN" ] || { first=1; : > "$SEEN"; }
  mkdir -p "$ROUTES"
  while IFS=$'\037' read -r key at answer label note; do
    key_ok "$key" && [ -n "$at" ] && [ -n "$answer" ] || continue
    designed "$key" "$answer"
    # The chat message for this card shows the board's answer and drops its buttons. A repeat is a no-op there.
    if ! grep -qxF "$key" "$CLOSED" 2>/dev/null; then
      printf '%s\n' "$key" >> "$CLOSED"
      case "$label" in ''|"Answered in chat") shown=$answer ;; *) shown=$label ;; esac
      [ "$first" = 1 ] || "$SCRIPT_DIR/jg-bus.sh" publish card-close "$key" "answered" --answer "$shown" >/dev/null 2>&1 || true
    fi
    link=$(JG_HOME="$JG_HOME" jg_board_link answered "$key" 2>/dev/null)
    lead=$(rget "$key" lead)
    if [ -z "$lead" ]; then
      case "$key" in jg-*) continue ;; esac
      grep -qxF "$key"$'\t'"$at" "$SEEN" && continue
      printf '%s\t%s\n' "$key" "$at" >> "$SEEN"
      [ "$first" = 1 ] && continue
      text="$(say "$answer${label:+ ($label)}${note:+ - $note} | board answer on $key at $at, not routed to a lead${link:+ | $link}")"
      # A real wake in this pass, one per answer (the key carries the answer time); the line
      # is only printed when the wake cannot be raised, so the answer is never lost.
      # shellcheck source=/dev/null
      ( . "$SCRIPT_DIR/jg-wake-lib.sh" && jg_wake_append check "board-answer-unmapped-$key-$at" "check: $text" ) >/dev/null 2>&1 \
        || report="${report}${text}"$'\n'
      continue
    fi
    if [ "$(rget "$key" answered)" != "$at" ]; then
      dk=$(rget "$key" decision)
      id=$(printf '%s' "$key|$at" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16)
      text="$(answer_text "$key" "$at" "$answer" "$label" "$note" "$link")"
      if out=$(deliver "$key" "$lead" "$dk" "$text" "$id"); then
        rput "$key" answered "$at"
        report="${report}$(say "info: board answer \"$answer\" on $key went to $lead; nothing for Main to do")"$'\n'
      elif [ "$(rget "$key" failed)" != "$at" ]; then
        rput "$key" failed "$at"
        report="${report}$(say "board answer \"$answer\" on $key could not reach $lead (retrying each pass): ${out//$'\n'/ }")"$'\n'
      fi
    elif [ -z "$(rget "$key" archived)" ] && grep -qsF "board-answer [key=$key at=$at]" "$STATE/$lead.inbox/handled/"*.msg; then
      sign-off-axi dismiss "$key" ${board:+"$board"} --reason done-elsewhere >/dev/null 2>&1 && rput "$key" archived 1
    fi
  done < <(printf '%s\n' "$json" | jq -r 'to_entries[] | select(.value.answer != null and .value.at != null)
    | [.key, .value.at, .value.answer, (.value.label // ""), (.value.note // "")] | map(tostring | gsub("[\n\r\t\u001f]"; " ")) | join("\u001f")' 2>/dev/null)
  [ -z "$report" ] || printf '%s' "$report"
}

cmd_route_answer() {
  local key=${1-} at=${2-} answer=${3-} label=${4-} lead dk link text id out
  key_ok "$key" || die "route-answer needs a card key" 2
  { [ -n "$at" ] && [ -n "$answer" ]; } || die "route-answer needs the answer time and the captain's answer" 2
  mkdir -p "$ROUTES"
  designed "$key" "$answer"
  lead=$(rget "$key" lead)
  if [ -z "$lead" ]; then
    case "$key" in jg-*) die "refused: $key belongs to the captain-hold adapter, not a routed card" 3 ;; esac
    die "refused: card $key is not routed to a lead, so its answer stays with Main as it does today" 3
  fi
  dk=$(rget "$key" decision)
  link=$(JG_HOME="$JG_HOME" jg_board_link answered "$key" 2>/dev/null)
  id=$(printf '%s' "$key|$at" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16)
  text=$(answer_text "$key" "$at" "$answer" "$label" '' "$link")
  out=$(deliver "$key" "$lead" "$dk" "$text" "$id") || die "the answer could not reach $lead: ${out//$'\n'/ }"
  rput "$key" answered "$at"
  printf 'routed: %s -> %s\n' "$key" "$lead"
}

write_registration() {  # 0 = shim written and bound; else the cause on stdout
  local tmp err
  tmp=$(umask 077; mktemp "$STATE/.jg-board-answers.XXXXXX" 2>&1) || { printf 'cannot write the check shim: %s' "$tmp"; return 1; }
  { printf '#!/usr/bin/env bash\nexport JG_HOME=%q\nexec %q check\n' "$JG_HOME" "$SCRIPT_DIR/jg-board-answers.sh" > "$tmp" \
    && chmod 0700 "$tmp" && mv -fT -- "$tmp" "$SHIM"; } || { rm -f -- "$tmp"; printf 'cannot write the check shim'; return 1; }
  err=$(JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-check-register.sh" board-answers 2>&1 >/dev/null) \
    || { printf 'cannot register the check: %s' "${err:-no reason given}"; return 1; }
  rm -f -- "$DISARMED"
}

cmd_rearm() {
  local cause
  cause=$(write_registration) || die "$cause"
}

cmd_arm() {
  cmd_rearm
  printf 'armed: board-answers\n'
  cmd_check
}

registration_ok() { jg_custom_check_registered "$STATE" board-answers; }

cmd_tick() {
  local cause
  export BOARD_ANSWERS_TICK=1
  if [ ! -e "$DISARMED" ] && ! registration_ok; then
    # Squad Lead homes are read by their primary home, and a state directory
    # that is not this home's own is a fixture or an override: neither is armed here.
    # With no board file there is nothing to watch yet; the tick after one appears arms.
    if [ -e "$(jg_compat_marker "$JG_HOME")" ] || [ "$STATE" != "$JG_HOME/state" ] || [ ! -d "$STATE" ] \
      || [ -z "$(jg_question_board)" ]; then
      return 0
    fi
    if cause=$(write_registration) && registration_ok; then
      printf '%s re-armed: board-answers\n' "$(date +%s)" >> "$STATE/board-answers.rearm.log" 2>/dev/null || true
      rm -f -- "$ALERTED"
    else
      cause=${cause:-the registration did not verify after it was written}
      if [ "$(cat "$ALERTED" 2>/dev/null)" != "$cause" ]; then
        printf '%s\n' "$cause" > "$ALERTED" 2>/dev/null || true
        say "board-answers check is not registered and could not be re-armed, so board answers do not reach Main: $cause"
      fi
      return 0
    fi
  fi
  cmd_check
}

case "${1:-check}" in
  route) shift; cmd_route "$@" ;;
  route-answer) shift; cmd_route_answer "$@" ;;
  check|poll) cmd_check ;;
  arm) cmd_arm ;;
  rearm) cmd_rearm ;;
  tick) cmd_tick ;;
  disarm) rm -f -- "$SHIM" "$STATE/board-answers.check-trust"; : > "$DISARMED"; printf 'disarmed: board-answers\n' ;;
  *) die "unknown command: $1" 2 ;;
esac

#!/usr/bin/env bash
# jg-board-answers.sh - carry each board answer to the lead that needs it, as a
# standing watcher check, so no answer waits on Main reading it.
#
# Usage:
#   jg-board-answers.sh route <card-key> <lead> [<decision-key>]
#   jg-board-answers.sh route-answer <card-key> <at> <answer> [<label>]
#   jg-board-answers.sh [check|poll]
#   jg-board-answers.sh arm | disarm
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
#          UNROUTED: print one line, full answer text first; the watcher turns
#            it into a wake for Main. Reported once; answers already on the
#            board at the first pass are recorded, not reported.
# arm    Write state/board-answers.check.sh, bind it with jg-check-register.sh,
#        and run one pass. disarm removes the shim and its trust binding.
# State: state/board-routes/<card-key>, state/.board-answers-seen. Unrouted keys
# starting `jg-` belong to the captain-hold card adapter and are skipped.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
ROUTES="$STATE/board-routes"
SEEN="$STATE/.board-answers-seen"
SHIM="$STATE/board-answers.check.sh"
# shellcheck source=bin/jg-compat.sh
. "$SCRIPT_DIR/jg-compat.sh"
# shellcheck source=bin/jg-question-lib.sh
. "$SCRIPT_DIR/jg-question-lib.sh"
# shellcheck source=bin/jg-board-link-lib.sh
. "$SCRIPT_DIR/jg-board-link-lib.sh"
# shellcheck source=bin/jg-classify-lib.sh
. "$SCRIPT_DIR/jg-classify-lib.sh"
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

cmd_check() {
  local json board key answer label note at lead dk link text id out first=0 report=''
  jg_question_signoff_available || { say "board answers cannot be read: sign-off-axi is not on PATH"; return 0; }
  board=$(jg_question_board)
  json=$(sign-off-axi answers ${board:+"$board"} --json 2>/dev/null) || { say "board answers cannot be read: sign-off-axi answers failed"; return 0; }
  [ -f "$SEEN" ] || { first=1; : > "$SEEN"; }
  mkdir -p "$ROUTES"
  while IFS=$'\037' read -r key at answer label note; do
    key_ok "$key" && [ -n "$at" ] && [ -n "$answer" ] || continue
    link=$(JG_HOME="$JG_HOME" jg_board_link answered "$key" 2>/dev/null)
    lead=$(rget "$key" lead)
    if [ -z "$lead" ]; then
      case "$key" in jg-*) continue ;; esac
      grep -qxF "$key"$'\t'"$at" "$SEEN" && continue
      printf '%s\t%s\n' "$key" "$at" >> "$SEEN"
      [ "$first" = 1 ] && continue
      report="${report}$(say "$answer${label:+ ($label)}${note:+ - $note} | board answer on $key at $at, not routed to a lead${link:+ | $link}")"$'\n'
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

cmd_arm() {
  local tmp
  tmp=$(umask 077; mktemp "$STATE/.jg-board-answers.XXXXXX") || die "cannot write the check shim"
  { printf '#!/usr/bin/env bash\nexport JG_HOME=%q\nexec %q check\n' "$JG_HOME" "$SCRIPT_DIR/jg-board-answers.sh" > "$tmp" \
    && chmod 0700 "$tmp" && mv -f -- "$tmp" "$SHIM"; } || { rm -f -- "$tmp"; die "cannot write the check shim"; }
  JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-check-register.sh" board-answers || die "cannot register the check"
  cmd_check > /dev/null
  printf 'armed: board-answers\n'
}

case "${1:-check}" in
  route) shift; cmd_route "$@" ;;
  route-answer) shift; cmd_route_answer "$@" ;;
  check|poll) cmd_check ;;
  arm) cmd_arm ;;
  disarm) rm -f -- "$SHIM" "$STATE/board-answers.check-trust"; printf 'disarmed: board-answers\n' ;;
  *) die "unknown command: $1" 2 ;;
esac

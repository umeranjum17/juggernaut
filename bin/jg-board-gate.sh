#!/usr/bin/env bash
# jg-board-gate.sh - the board-ask gate's record, count, and scheduled checks.
#
# Usage:
#   jg-board-gate.sh route --title "<the ask>" [--filer <id>] [--ref <id>]
#   jg-board-gate.sh decided <record-id> --words "<what Main decided>"
#   jg-board-gate.sh waiting
#   jg-board-gate.sh check | arm | disarm
#
# The captain's leash (2026-10-30): "asking when it matters is not working at
# all - it's asking random questions that should go to overwatch not to my
# board". bin/jg-ask-gate-lib.sh owns the category list and the refusal the
# raising paths apply; this script owns what the refusal leaves behind and what
# happens to asks that are already waiting.
#
# route    Turn a refused ask into an Overwatch decision record in
#          $DATA/overwatch-decisions.md, so Main answers it and the record says
#          "Main decided". Prints `overwatch: <record-id> <path>`.
# decided  Replace that record's open line with Main's decision.
# waiting  Print the count of waiting asks that carry a must category. It is the
#          only waiting count this home owns: the gate keeps every non-must ask
#          off the board, so the board's own waiting count is this one. A key the
#          board's dismissal record settles is not counted, and a card whose
#          detail field lost its category to a rebuild is counted from the
#          category's own record (bin/jg-board-record-lib.sh).
# check    One no-model pass over the board, run as a watcher check:
#          - a card the board's own records settle is left alone: a key its owner
#            dismissed stays dismissed when a rebuild puts the card back, and a
#            card keeps the must category it was filed with even after a rebuild
#            dropped its detail field (bin/jg-board-record-lib.sh);
#          - every open ask with no must category is recorded for Overwatch and
#            dismissed from the captain's board, since it is not his to answer;
#          - every must ask waiting over 48 hours is re-pinged once;
#          - every merge recorded in the last 30 minutes with no live board
#            Evidence card for its PR reports here.
#          Each line wakes Main, the board's owner. The set of offending keys is
#          recorded beside the gate (state/.board-gate/unrouted.set) and the pass
#          alerts once for it: the same unchanged set stays silent, and only an
#          addition, a removal or an edit to it alerts again, so a card the board
#          refuses to remove cannot wake Main every cycle. A card is routed once,
#          however many passes see it. A re-ping and a healthy board are silent
#          after the first pass. A report card is not an ask (its kind is not a
#          decision), so the gate ignores it.
# arm      Write state/board-gate.check.sh and bind it with jg-check-register.sh;
#          bin/jg-bootstrap.sh arms it on a primary home. disarm retires it.
# Environment: JG_HOME, JG_STATE_OVERRIDE and JG_DATA_OVERRIDE as in other bin/
# scripts. The board is --board, else JG_PROOF_BOARD, else the `--board` of
# config/post-merge, else the board sign-off-axi's own walk finds.
# JG_BOARD_GATE_REFIRE_SECS (default 600) spaces one unproven merge's re-reports.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
RECORDS="$DATA/overwatch-decisions.md"
GATE_DIR="$STATE/.board-gate"
REFIRE_SECS=${JG_BOARD_GATE_REFIRE_SECS:-600}
NOW=${JG_BOARD_GATE_NOW:-$(date +%s)}
BOARD=${BOARD:-}
# shellcheck source=bin/jg-compat.sh
. "$SCRIPT_DIR/jg-compat.sh"
# shellcheck source=bin/jg-classify-lib.sh
. "$SCRIPT_DIR/jg-classify-lib.sh"
# shellcheck source=bin/jg-question-lib.sh
. "$SCRIPT_DIR/jg-question-lib.sh"
# shellcheck source=bin/jg-ask-gate-lib.sh
. "$SCRIPT_DIR/jg-ask-gate-lib.sh"
# shellcheck source=bin/jg-board-link-lib.sh
. "$SCRIPT_DIR/jg-board-link-lib.sh"
# shellcheck source=bin/jg-board-record-lib.sh
. "$SCRIPT_DIR/jg-board-record-lib.sh"

OPEN_ASKS='.decisions[]? | select((.dismissed // false) != true and .decided == null and ((.kind // .type // "decision") == "decision"))'

die() { printf 'jg-board-gate: %s\n' "$1" >&2; exit "${2:-1}"; }
clean_line() { printf '%s' "${1-}" | tr '\n\r\t' '   '; }

board_file() {
  local b=${BOARD}
  [ -n "$b" ] || b=${JG_PROOF_BOARD:-}
  [ -n "$b" ] || b=$(sed -n "s/.*--board[= ]'\{0,1\}\([^' ]*\).*/\1/p" "$CONFIG/post-merge" 2>/dev/null | head -n 1)
  [ -n "$b" ] || b=$(jg_question_board)
  printf '%s\n' "$b"
}

board_list() {  # <board file>
  command -v sign-off-axi >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 1
  sign-off-axi list "$1" --json 2>/dev/null
}

mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# A tag names a file, and its text can hold any character a title or key does,
# so the file name is a lowercase slug of it with a fixed cap, plus the text's
# checksum so two tags that slug the same stay two files.
tag_file() {  # <tag> -> the path of this tag's record
  local slug
  slug=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | tr -s '-' | cut -c1-48)
  printf '%s/%s-%s\n' "$GATE_DIR" "${slug#-}" "$(printf '%s' "$1" | cksum | awk '{printf "%08x", $1}')"
}

first_time() {  # <tag>: 0 the first pass that sees it, then 1
  local f
  f=$(tag_file "$1")
  [ ! -e "$f" ] || return 1
  mkdir -p "$GATE_DIR" 2>/dev/null && : > "$f" 2>/dev/null || return 1
  return 0
}

refire_ok() {  # <tag>: 0 when this tag may report now, and records the report
  local f fired=0
  f=$(tag_file "$1")
  mkdir -p "$GATE_DIR" 2>/dev/null || return 1
  [ ! -f "$f" ] || fired=$(sed -n 's/^fired=//p' "$f" | tail -1)
  case "$fired" in ''|*[!0-9]*) fired=0 ;; esac
  [ "$fired" -eq 0 ] || [ $((NOW - fired)) -ge "$REFIRE_SECS" ] || return 1
  printf 'fired=%s\n' "$NOW" > "$f.tmp" && mv -f -- "$f.tmp" "$f"
}

route_record() {  # <title> <filer> <ref> -> prints the record id
  local title id
  title=$(clean_line "$1")
  id="owd-$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%s' "$title" | cksum | awk '{printf "%08x", $1}')"
  [ -f "$RECORDS" ] && grep -qxF "## $id" "$RECORDS" && { printf '%s\n' "$id"; return 0; }
  mkdir -p "$DATA" || return 1
  {
    printf '\n## %s\n' "$id"
    printf -- '- Ask: %s\n' "$title"
    printf -- '- Asked by: %s\n' "$(clean_line "${2:-unknown}")"
    [ -z "${3-}" ] || printf -- '- Ask ref: %s\n' "$(clean_line "$3")"
    printf -- '- Must category: none\n'
    printf -- '- Main decided: open - Main answers it: bin/jg-board-gate.sh decided %s --words "<what Main decided>"\n' "$id"
  } >> "$RECORDS" || return 1
  printf '%s\n' "$id"
}

cmd_route() {
  local title='' filer='' ref='' id
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1-} ;;
      --filer) shift; filer=${1-} ;;
      --ref) shift; ref=${1-} ;;
      *) die "route: unknown flag $1" 2 ;;
    esac
    shift
  done
  [ -n "$title" ] || die 'route needs --title "<the ask>"' 2
  id=$(route_record "$title" "$filer" "$ref") || die "cannot write $RECORDS"
  printf 'overwatch: %s %s\n' "$id" "$RECORDS"
}

cmd_decided() {
  local id=${1-} words='' tmp
  [ -z "$id" ] || shift
  while [ "$#" -gt 0 ]; do
    case "$1" in --words) shift; words=${1-} ;; *) die "decided: unknown flag $1" 2 ;; esac
    shift
  done
  case "$id" in owd-*) ;; *) die "decided needs the record id route printed" 2 ;; esac
  [ -n "$words" ] || die 'decided needs --words "<what Main decided>"' 2
  if [ ! -f "$RECORDS" ] || ! grep -qxF "## $id" "$RECORDS"; then
    die "no Overwatch record $id in $RECORDS"
  fi
  words=$(clean_line "$words")
  tmp=$(umask 077; mktemp "$DATA/.overwatch-decisions.XXXXXX") || die "cannot stage $RECORDS"
  awk -v id="$id" -v line="- Main decided: $words ($(date -u +%Y-%m-%dT%H:%MZ))" '
    /^## / { on = ($0 == "## " id) }
    on && /^- Main decided:/ { print line; next }
    { print }' "$RECORDS" > "$tmp" || { rm -f -- "$tmp"; die "cannot update $RECORDS"; }
  mv -f -- "$tmp" "$RECORDS" || { rm -f -- "$tmp"; die "cannot update $RECORDS"; }
  printf 'decided: %s\n' "$id"
}

cmd_waiting() {
  local board json count
  board=$(board_file)
  [ -n "$board" ] || die 'no board to count; set SIGN_OFF_HOME, JG_PROOF_BOARD or config/post-merge --board'
  json=$(board_list "$board") || die "cannot read $board with sign-off-axi"
  count=$(printf '%s' "$json" | jq -r "$OPEN_ASKS"' | [(.key // ""), (.detail // "")] | map(gsub("[\\n\\r\\t]"; " ")) | join("\u001f")' 2>/dev/null \
    | while IFS=$'\x1f' read -r key detail; do
        [ -n "$key" ] || continue
        # A card its owner dismissed is not waiting on anyone, however often a
        # rebuild puts it back (bin/jg-board-record-lib.sh).
        jg_board_dismissed "$board" "$key" && continue
        # The category a card was filed with outlives a rebuild that dropped its
        # detail field, so the count reads it from the record as well.
        cat=$(jg_ask_card_category "$detail")
        [ -n "$cat" ] || cat=$(jg_ask_card_category "$(jg_board_detail_of "$board" "$key")")
        [ -z "$cat" ] || printf '%s\n' "$key"
      done | wc -l | tr -d ' ')
  printf '%s\n' "${count:-0}"
}

# The record a card key already has, else nothing: the gate routes one card once,
# so a pass that cannot remove the card does not append the same ask again.
routed_id() {  # <card key>
  [ -f "$RECORDS" ] || return 0
  awk -v ref="- Ask ref: $(clean_line "$1")" '
    /^## / { id = substr($0, 4) }
    $0 == ref { print id; exit }' "$RECORDS" 2>/dev/null
}

# Alert once for one set of offending keys: the set this pass alerted on is a
# record beside the gate, so the same unchanged set stays silent until an
# addition, a removal or an edit changes it. This is the shape the wake classes
# use for a repeated event (bin/jg-wake-lib.sh _jg_wake_realert_record): the
# event's own identity is recorded where it was delivered, and an unchanged one
# cannot be delivered again.
alert_key_set() {  # <keys file> <buffered lines file>
  local keys=$1 lines=$2 rec=$GATE_DIR/unrouted.set new old
  new=$(sort -u "$keys" 2>/dev/null)
  old=$(cat "$rec" 2>/dev/null)
  [ "$new" != "$old" ] || return 0
  cat "$lines"
  if [ -n "$new" ]; then printf '%s\n' "$new" > "$rec.tmp"; else : > "$rec.tmp"; fi \
    && mv -f -- "$rec.tmp" "$rec" 2>/dev/null
  rm -f -- "$rec.tmp" 2>/dev/null || true
  return 0
}

# The one of sign-off-axi's three dismiss reasons that fits what the gate knows
# of a card: a newer open card from the same filer with the same title replaced
# it, an Overwatch record Main already decided answered it elsewhere, else it is
# not relevant. No other value is ever sent.
dismiss_reason() {  # <board json> <key> <filer> <title> <filed> <record id>
  local newer
  newer=$(printf '%s' "$1" | jq -r --arg k "$2" --arg f "$3" --arg t "$4" --arg at "$5" "$OPEN_ASKS"' | select((.key // "") != $k and (.filer // "") == $f and (.title // "") == $t and (.filed // "") > $at) | .key' 2>/dev/null | head -n 1)
  if [ -n "$newer" ]; then printf 'replaced\n'; return 0; fi
  if [ -f "$RECORDS" ] && awk -v id="$6" '
      /^## / { on = ($0 == "## " id) }
      on && /^- Main decided:/ && $0 !~ /^- Main decided: open/ { found = 1 }
      END { exit !found }' "$RECORDS"; then
    printf 'done-elsewhere\n'; return 0
  fi
  printf 'not-relevant\n'
}

# Route one ask off the board, or re-ping one must ask.
ask_sweep() {  # <board json> <board>
  local key filed detail filer title cat epoch id
  local lines=$GATE_DIR/.unrouted.lines keys=$GATE_DIR/.unrouted.keys
  mkdir -p "$GATE_DIR" 2>/dev/null || return 0
  : > "$lines" && : > "$keys" || return 0
  # A detail field can hold line breaks, and a bare join would then read each of
  # its lines as another ask: the fields are flattened before they are joined.
  printf '%s' "$1" | jq -r "$OPEN_ASKS"' | [(.key // ""), (.filed // ""), (.detail // ""), (.filer // ""), (.title // "")] | map(gsub("[\\n\\r\\t]"; " ")) | join("\u001f")' 2>/dev/null \
    | while IFS=$'\x1f' read -r key filed detail filer title; do
        [ -n "$key" ] || continue
        # A dismissal is a record, not an absence: a card its owner dismissed
        # and a rebuild put back has nobody waiting on it, so the gate neither
        # routes it again nor re-pings it.
        jg_board_dismissed "$2" "$key" && continue
        cat=$(jg_ask_card_category "$detail")
        [ -n "$cat" ] || cat=$(jg_ask_card_category "$(jg_board_detail_of "$2" "$key")")
        if [ -z "$cat" ]; then
          id=$(routed_id "$key")
          [ -n "$id" ] || id=$(route_record "${title:-$key}" "$filer" "$key") || continue
          printf '%s\n' "$key" >> "$keys"
          # sign-off-axi takes one of its three own reasons, so a card that is
          # not the captain's to answer leaves the board with the one that fits.
          if sign-off-axi dismiss "$key" "$2" --reason "$(dismiss_reason "$1" "$key" "$filer" "$title" "$filed" "$id")" >/dev/null 2>&1; then
            printf 'board ask routed to Overwatch, not a must: %s - %s (record %s)\n' "$key" "$title" "$id" >> "$lines"
          else
            printf 'board ask has no must category and could not be dismissed: %s - %s (record %s)\n' "$key" "$title" "$id" >> "$lines"
          fi
          continue
        fi
        case "$filed" in
          *.*) filed=${filed%%.*}Z ;;
          *Z) ;;
          '') continue ;;
          *) continue ;;
        esac
        epoch=$(jg_utc_iso_to_epoch "$filed") || continue
        [ $((NOW - epoch)) -ge 172800 ] || continue
        first_time "pinged-$key" || continue
        printf 'must ask waiting over 48h: %s - %s (%s)\n' "$key" "$title" "$cat"
      done
  alert_key_set "$keys" "$lines"
  rm -f -- "$lines" "$keys" 2>/dev/null || true
}

has_evidence() {  # <board json> <merge key> <pr url>
  printf '%s' "$1" | jq -e --arg k "$2" --arg u "$3" '
    any(.decisions[]?;
      ((.dismissed // false) != true)
      and (((.kind // .type // "") == "evidence"))
      and (((.key // "") | startswith($k)) or ((.link // "") == $u)))' >/dev/null 2>&1
}

merge_sweep() {  # <board json>
  local marker id pr mtime key meta
  for marker in "$STATE"/*.pr-poll-merge-notified; do
    [ -f "$marker" ] || continue
    id=${marker##*/}; id=${id%.pr-poll-merge-notified}
    mtime=$(mtime_of "$marker") || continue
    case "$mtime" in ''|*[!0-9]*) continue ;; esac
    [ $((NOW - mtime)) -lt 1800 ] || continue
    meta=$STATE/$id.meta
    pr=$(sed -n 's/^pr=//p' "$meta" 2>/dev/null | tail -1)
    case "$pr" in http://?*|https://?*) ;; *) continue ;; esac
    key=$(jg_board_merge_key "$pr")
    has_evidence "$1" "$key" "$pr" && continue
    refire_ok "merge-$key" || continue
    printf 'merge landed with no board Evidence card: %s %s (expected card %s)\n' "$id" "$pr" "$key"
  done
}

cmd_check() {
  local board json
  board=$(board_file)
  json=$(board_list "$board") || return 0
  ask_sweep "$json" "$board"
  merge_sweep "$json"
}

cmd_arm() {
  local marker shim=$STATE/board-gate.check.sh tmp
  marker=$(jg_compat_marker "$JG_HOME")
  { [ ! -e "$marker" ] && [ ! -L "$marker" ]; } || die 'a Squad Lead home is read by its primary home; not armed' 2
  tmp=$(umask 077; mktemp "$STATE/.jg-board-gate.XXXXXX") || die 'cannot write the check shim'
  { printf '#!/usr/bin/env bash\nexport JG_HOME=%q\nexec %q check\n' "$JG_HOME" "$SCRIPT_DIR/jg-board-gate.sh" > "$tmp" \
    && chmod 0700 "$tmp" && mv -f -- "$tmp" "$shim"; } || { rm -f -- "$tmp"; die 'cannot write the check shim'; }
  JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-check-register.sh" board-gate >/dev/null || die 'cannot register the check'
  printf 'armed: board-gate\n'
}

case "${1:-waiting}" in
  route) shift; cmd_route "$@" ;;
  decided) shift; cmd_decided "$@" ;;
  waiting) cmd_waiting ;;
  check) cmd_check ;;
  arm) cmd_arm ;;
  disarm) JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-check-unregister.sh" board-gate ;;
  -h|--help|help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; exit 2 ;;
  *) die 'usage: route|decided|waiting|check|arm|disarm (see the header)' 2 ;;
esac

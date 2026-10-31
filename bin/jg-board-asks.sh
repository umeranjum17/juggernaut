#!/usr/bin/env bash
# jg-board-asks.sh - turn the feed a board rebuild just built into the feed that
# may be posted, by keeping the two records the board already holds.
#
# Usage:
#   jg-board-asks.sh rebuild --from <feed.json> --board <board.json> [--out <file>]
#
# rebuild  Read the freshly built feed (`{"schema":2,"answers_only":true,"items":[...]}`)
#          and print the same feed with three corrections, each decided by a
#          record beside the board rather than by what the sources happen to hold:
#
#          1. A card keeps its detail field. The detail is where a card's must
#             category lives (bin/jg-ask-gate-lib.sh), and a rebuild that writes
#             its own detail, or none, used to drop it. A surviving card's
#             category comes from the card itself, else from the card-detail
#             record, and is written back into the detail field it just rebuilt.
#          2. A key its owner dismissed is dropped. sign-off-axi appends every
#             dismissal to <board>.dismissed.jsonl, so a dismissal is a record,
#             not an absence: re-posting the key does not un-dismiss it, and the
#             rebuild must not put the card back.
#          3. A key already live on the board under another filer is dropped,
#             because another home is waiting on that same ask.
#
#          One line per dropped card goes to stderr, naming the record that
#          dropped it, so a run says what it removed instead of silently
#          shrinking the board. --out writes the corrected feed to that file and
#          prints nothing, so a caller can post only a change.
#
# The poster stays sign-off-axi's own, unchanged:
#   sign-off-axi post <board> --from <feed> --replace --filer captain-board-feed
# This command never writes to the board, the feed or either record.
# Environment: JG_BOARD_FEED_FILER (default captain-board-feed), the filer whose
# items this rebuild owns; jq must be on PATH, and every path is an argument.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/jg-board-record-lib.sh
. "$SCRIPT_DIR/jg-board-record-lib.sh"
# shellcheck source=bin/jg-ask-gate-lib.sh
. "$SCRIPT_DIR/jg-ask-gate-lib.sh"

FILER=${JG_BOARD_FEED_FILER:-captain-board-feed}

die() { printf 'jg-board-asks: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}

# The last line per key from one sidecar record, as a JSON array.
# <board> <sidecar name> <jq filter that maps the lines to what is kept>
record_last() {
  local file
  file=$(jg_board_sidecar "$1" "$2") || { printf '[]\n'; return 0; }
  [ -f "$file" ] || { printf '[]\n'; return 0; }
  # A torn line is skipped, the way sign-off-axi skips it, so one bad line
  # cannot hide the record behind it.
  jq -s "$3" "$file" 2>/dev/null || printf '[]\n'
}

# The detail a card already carries, for a card the board still has: its own
# detail field, else the detail it was posted with.
own_detail() {  # <key>
  local d
  d=$(jq -r --arg k "$1" 'map(select(.key == $k)) | last | .detail // ""' <<<"$LIVE" 2>/dev/null) || d=''
  [ -n "$d" ] || d=$(jq -r --arg k "$1" 'map(select(.key == $k)) | last | .detail // ""' <<<"$HELD" 2>/dev/null) || d=''
  printf '%s\n' "$d"
}

# 0 when another home already has this key live on the board.
held_elsewhere() {  # <key>
  jq -e --arg k "$1" --arg f "$FILER" \
    'any(.[]?; .key == $k and ((.filer // $f) != $f))' <<<"$LIVE" >/dev/null 2>&1
}

# The item with the must category it already carried written back into its own
# detail field, or unchanged when it carried none.
keep_category() {  # <item-json>
  local key cat was new_cat detail
  key=$(jq -r '.key // ""' <<<"$1" 2>/dev/null) || return 0
  case "$key" in ''|*[!A-Za-z0-9._-]*) printf '%s\n' "$1"; return 0 ;; esac
  was=$(own_detail "$key")
  cat=$(jg_ask_card_category "$was")
  [ -n "$cat" ] || { printf '%s\n' "$1"; return 0; }
  detail=$(jq -r '.detail // ""' <<<"$1" 2>/dev/null) || detail=''
  new_cat=$(jg_ask_card_category "$detail")
  [ "$new_cat" = "$cat" ] && { printf '%s\n' "$1"; return 0; }
  # Keep the detail the rebuild wrote, minus any category it put there, and add
  # back the one the card was filed with.
  detail=${detail%must:*}
  detail=${detail%"${detail##*[! ]}"}
  [ -n "$detail" ] && detail="$detail must: $cat" || detail="must: $cat"
  jq -c --arg d "$detail" '. + {detail: $d}' <<<"$1" 2>/dev/null || printf '%s\n' "$1"
}

cmd_rebuild() {
  local from='' board='' out='' items item key dropped='' kept='' feed
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from) shift; from=${1-} ;;
      --board) shift; board=${1-} ;;
      --out) shift; out=${1-} ;;
      *) die "rebuild: unknown flag $1" 2 ;;
    esac
    shift
  done
  [ -n "$from" ] && [ -n "$board" ] || die 'rebuild needs --from <feed.json> and --board <board.json>' 2
  [ -f "$from" ] || die "no feed at $from"
  [ -f "$board" ] || die "no board at $board"
  command -v jq >/dev/null 2>&1 || die 'jq is required to read the board'

  # The two records beside the board, and the board's own live cards, read once.
  # shellcheck disable=SC2016  # jq program text: $l is a jq variable.
  DISMISSED=$(record_last "$board" dismissed.jsonl \
    'reduce .[] as $l ({}; .[$l.key] = ($l.dismissed == true)) | to_entries | map(select(.value)) | map(.key)') \
    || DISMISSED='[]'
  # shellcheck disable=SC2016  # jq program text: $l is a jq variable.
  HELD=$(record_last "$board" card-detail.jsonl \
    'reduce .[] as $l ({}; .[$l.key] = $l.detail) | to_entries | map(select((.value // "") != "")) | map({key, detail: .value})') \
    || HELD='[]'
  LIVE=$(jq -c '[(.items // .decisions // [])[]]' "$board" 2>/dev/null) || LIVE='[]'
  [ -n "$LIVE" ] || LIVE='[]'
  items=$(jq -c '(.items // .decisions // [])[]' "$from" 2>/dev/null) \
    || die "the feed at $from could not be read as board items"

  while IFS= read -r item; do
    [ -n "$item" ] || continue
    key=$(jq -r '.key // ""' <<<"$item" 2>/dev/null) || continue
    case "$key" in ''|*[!A-Za-z0-9._-]*) kept="$kept$item"$'\n'; continue ;; esac
    if jq -e --arg k "$key" 'index($k) != null' <<<"$DISMISSED" >/dev/null 2>&1; then
      dropped="$dropped"$'dropped '"$key"$': dismissed by its owning home\n'
      continue
    fi
    if held_elsewhere "$key"; then
      dropped="$dropped"$'dropped '"$key"$': already live on the board under another filer\n'
      continue
    fi
    kept="$kept$(keep_category "$item")"$'\n'
  done <<EOF
$items
EOF

  [ -z "$dropped" ] || printf '%s' "$dropped" >&2
  feed=$(printf '%s' "$kept" | jq -c -s '{schema: 2, answers_only: true, items: .}') \
    || die "the feed at $from could not be read as board items"
  if [ -n "$out" ]; then
    printf '%s\n' "$feed" > "$out" || die "cannot write $out"
    return 0
  fi
  printf '%s\n' "$feed"
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  rebuild) cmd_rebuild "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac

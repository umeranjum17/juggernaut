#!/usr/bin/env bash
# jg-board-ledger.sh - keep a durable record of the board's proof cards and alarm when
# one leaves the board without a dismissal record, or when a merge lands with no card.
#
#   jg-board-ledger.sh scan    [<board.json>]
#   jg-board-ledger.sh archive <backup.json> [--board <live.json>]
#   jg-board-ledger.sh arm | disarm
#
# A board item carries `key`, `filed`, `link`, `title`, `kind` and `dismissed`. A
# dismissal never edits the item: sign-off-axi appends a line to
# `<board stem>.dismissed.jsonl` beside the board, so that sidecar is the only record
# that a card left on purpose, and this script writes neither file.
#
# scan appends every evidence key it has not seen before to
# $JG_HOME/state/board-evidence-ledger.jsonl, one object per line with exactly `key`,
# `filed`, `link`, `title`. It then prints one line per ledger key that is no longer a
# live item and has no line in the sidecar, and one line when state/fleet-ledger.jsonl
# records a `task.merged` in the last 30 minutes with no card filed in that window:
#
#   proof card <key> left the board with no dismissal
#   no proof card filed since the merge at <ISO>; checked at <ISO>
#
# Each prints once, and a card back on the board is armed again. The watcher supplies
# the `check: ` prefix, so these are payloads, not whole reasons. archive writes the
# evidence cards of an old backup that are in neither the live board nor the sidecar
# into data/board-evidence-archive.jsonl, keeping lost history searchable off the
# board; nothing is posted, restored or deleted.
#
# The board is the argument, else $JG_PROOF_BOARD, else the `--board` of
# config/post-merge. arm writes state/board-evidence-ledger.check.sh and binds it with
# jg-check-register.sh; disarm retires it. state/.board-evidence-alerted.json holds the
# alerted keys and the reported merge time.
#
# Environment: JG_HOME, JG_STATE_OVERRIDE, JG_CONFIG_OVERRIDE, JG_DATA_OVERRIDE.
# Exit: 0 on success or when this is only a watcher check, 2 on a usage error or an
# unreadable board.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$REPO_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
LEDGER=$STATE/board-evidence-ledger.jsonl
ALERT=$STATE/.board-evidence-alerted.json
ARCHIVE=$DATA/board-evidence-archive.jsonl

die() { printf 'jg-board-ledger: %s\n' "$1" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq is not installed"

# One object per evidence item: the four ledger fields, plus whether it is live.
EVIDENCE='(.items // .decisions // [])[] | select((((.kind // .type) // "") == "evidence") and (.key != null))
  | {key: .key, filed: (.filed // null), link: (.link // null), title: (.title // null),
     live: ((.dismissed // false) != true)}'

dismissed_path() {  # <board.json>
  case $1 in *.json) printf '%s.dismissed.jsonl\n' "${1%.json}" ;; *) printf '%s.dismissed.jsonl\n' "$1" ;; esac
}

default_board() {
  [ -z "${JG_PROOF_BOARD:-}" ] || { printf '%s\n' "$JG_PROOF_BOARD"; return 0; }
  [ -r "$CONFIG/post-merge" ] || return 1
  local b
  b=$(sed -n "s/.*--board[= ]'\{0,1\}\([^' ]*\).*/\1/p" "$CONFIG/post-merge" 2>/dev/null | head -n 1)
  [ -n "$b" ] && printf '%s\n' "$b"
}

keys_of() {  # <jsonl>: every record's key, one per line
  [ -r "$1" ] || return 0
  jq -r 'select(type == "object") | .key // empty' "$1" 2>/dev/null
}

board_keys() {  # <board.json>: every item's key, one per line
  [ -r "$1" ] || return 0
  jq -r '(.items // .decisions // [])[] | .key // empty' "$1" 2>/dev/null
}

holds() {  # <newline list> <key>
  [ -n "$2" ] || return 1
  printf '%s\n' "$1" | grep -Fxq -- "$2"
}

# Keys with a dismissal record: the sidecar beside the board, or an item's own flag.
dismissed_keys() {  # <board.json>
  keys_of "$(dismissed_path "$1")"
  jq -r '(.items // .decisions // [])[] | select((.dismissed // false) == true) | .key // empty' \
    "$1" 2>/dev/null
}

iso() {  # <epoch>
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "$1"
}

cmd_scan() {
  local board=${1:-} out seen live dismissed prev alerted rearm now fleet merge_ts fresh k line
  [ -n "$board" ] || board=$(default_board) || return 0
  [ -r "$board" ] || { printf 'board is absent: %s\n' "$board"; return 0; }
  out=$(jq -c "$EVIDENCE" "$board" 2>/dev/null) || die "cannot read the board: $board"
  mkdir -p "$STATE" || die "cannot create $STATE"

  # 1. Append every evidence key this ledger has never seen.
  seen=$(keys_of "$LEDGER")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    k=$(printf '%s' "$line" | jq -r '.key')
    holds "$seen" "$k" && continue
    printf '%s' "$line" | jq -c 'del(.live)' >>"$LEDGER" || die "cannot append to $LEDGER"
    seen=$seen$'\n'$k
  done <<EOF
$out
EOF

  live=$(printf '%s\n' "$out" | jq -r 'select(.live) | .key' 2>/dev/null)
  dismissed=$({ printf '%s\n' "$out" | jq -r 'select(.live | not) | .key' 2>/dev/null; dismissed_keys "$board"; } | sed '/^$/d')
  prev=$(cat "$ALERT" 2>/dev/null) || prev='{}'
  alerted=$(jq -r '(.keys // [])[]' <<<"${prev:-{}}" 2>/dev/null)

  # 2. Wake once per ledger key the board no longer shows without a dismissal
  #    record, and keep the still-absent ones quiet next time. A key back on the
  #    board drops out of the baseline, so losing it again wakes again.
  rearm=
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    holds "$live" "$k" && continue
    holds "$dismissed" "$k" && continue
    rearm=$rearm$'\n'$k
    holds "$alerted" "$k" && continue
    printf 'proof card %s left the board with no dismissal\n' "$k"
  done <<EOF
$(keys_of "$LEDGER")
EOF

  # 4. Alarm 2: a merge landed and no proof card followed it.
  now=$(date +%s)
  fleet=/dev/null
  [ -r "$STATE/fleet-ledger.jsonl" ] && fleet=$STATE/fleet-ledger.jsonl
  merge_ts=$(jq -s --argjson now "$now" --argjson w 1800 '
    (map(select(.event == "task.merged" and ((.ts | type) == "number"))) | map(.ts) | max) as $mt
    | if $mt == null or ($now - $mt) < 0 or ($now - $mt) > $w then empty else $mt end' \
    "$fleet" 2>/dev/null)
  if [ -n "$merge_ts" ]; then
    fresh=$(jq -s --argjson mt "$merge_ts" '
      map(select(type == "object") | (.filed // empty)
        | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch empty
        | select(. >= $mt)) | length' "$LEDGER" 2>/dev/null)
    if [ "${fresh:-0}" = 0 ] && [ "$(jq -r '.merge // empty' <<<"${prev:-{}}" 2>/dev/null)" != "$merge_ts" ]; then
      printf 'no proof card filed since the merge at %s; checked at %s\n' \
        "$(iso "$merge_ts")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    else
      merge_ts=$(jq -r '.merge // empty' <<<"${prev:-{}}" 2>/dev/null)
    fi
  fi

  if ! { printf '{"keys": %s, "merge": %s}\n' \
      "$(printf '%s' "$rearm" | jq -R . | jq -s -c 'map(select(length > 0))')" \
      "${merge_ts:-null}" >"$ALERT.tmp.$$" && mv -f -- "$ALERT.tmp.$$" "$ALERT"; }; then
    rm -f -- "$ALERT.tmp.$$"
    die "cannot write $ALERT"
  fi
}

cmd_archive() {  # <backup.json> [<live.json>]
  local backup=${1:-} board=${2:-} known n=0 out k line
  [ -n "$backup" ] && [ -r "$backup" ] || die "cannot read the backup: ${backup:-none}"
  [ -n "$board" ] || board=$(default_board) || board=''
  known=$({ board_keys "$board"; dismissed_keys "$board"; dismissed_keys "$backup"
    keys_of "$ARCHIVE"; } | sed '/^$/d')
  mkdir -p "$DATA" || die "cannot create $DATA"
  out=$(jq -c "$EVIDENCE" "$backup" 2>/dev/null) || die "cannot read the backup: $backup"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    k=$(printf '%s' "$line" | jq -r '.key')
    holds "$known" "$k" && continue
    printf '%s' "$line" | jq -c 'del(.live)' >>"$ARCHIVE" || die "cannot append to $ARCHIVE"
    known=$known$'\n'$k
    n=$((n + 1))
  done <<EOF
$out
EOF
  printf 'archived %s proof card(s) to %s\n' "$n" "$ARCHIVE"
}

cmd_arm() {
  local shim=$STATE/board-evidence-ledger.check.sh tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  tmp=$(umask 077; mktemp "$STATE/.jg-board-ledger.XXXXXX") || die "cannot write the check shim"
  { printf '#!/usr/bin/env bash\nexport JG_HOME=%q\nexec %q\n' "$JG_HOME" "$SCRIPT_DIR/jg-board-ledger.sh" >"$tmp" \
    && chmod 0700 "$tmp" && mv -f -- "$tmp" "$shim"; } || { rm -f -- "$tmp"; die "cannot write the check shim"; }
  JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-check-register.sh" board-evidence-ledger >/dev/null \
    || die "cannot register the check"
  printf 'armed: board-evidence-ledger\n'
}

CMD=${1:-scan}
[ $# -gt 0 ] && shift
case $CMD in
  scan) cmd_scan "${1:-}" ;;
  archive)
    backup=${1:-}
    [ $# -gt 0 ] && shift
    board=''
    while [ $# -gt 0 ]; do
      [ "$1" = --board ] && [ -n "${2:-}" ] || die "usage: archive <backup.json> [--board <live.json>]"
      board=$2
      shift 2
    done
    cmd_archive "$backup" "$board" ;;
  arm) cmd_arm ;;
  disarm) JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-check-unregister.sh" board-evidence-ledger ;;
  *) die "usage: scan [<board.json>] | archive <backup.json> [--board <live.json>] | arm | disarm" ;;
esac

#!/usr/bin/env bash
# cursor.sh - reads data/moves.log from a byte cursor, so a slow observer costs the new moves only (H33).
#
# Usage: cursor.sh last <ticket>   print the last move line of a ticket (nothing when it has none)
#        cursor.sh read <name>     print the whole move lines this named reader has not read yet, then move its cursor
# State, under state/observer-cursors/ (never the log): moves.last holds `#offset <bytes>` then one `<ticket><TAB><move line>` row
# per ticket; <name>.read holds the reader's offset. Only whole lines are read: a half-written last line waits for its newline.
# A log shorter than the cursor was replaced, so the cursor starts again at byte 0. The log is only read.
set -u
export LC_ALL=C
cmd=${1:-}; arg=${2:-}
case "$cmd:$arg" in last:?*|read:?*) ;; *) echo "usage: cursor.sh last <ticket> | read <name>" >&2; exit 2 ;; esac
case "$arg" in */*|*[!A-Za-z0-9._:-]*) echo "cursor.sh: bad name '$arg'" >&2; exit 2 ;; esac
STATE=${JG_STATE_OVERRIDE:-${JG_HOME:?JG_HOME is not set}/state}; DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}
LOG=$DATA/moves.log; DIR=$STATE/observer-cursors
mkdir -p "$DIR" || exit 1
tmp=$(mktemp -d "$DIR/.tmp.XXXXXX") || exit 1; trap 'rm -rf -- "$tmp"' EXIT

# whole_from <offset>: write the whole lines of the log past <offset> to $tmp/new; print the offset after them.
whole_from() {
  local off=$1 size n partial
  size=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  [ "$size" -ge "$off" ] || off=0
  tail -c +$((off + 1)) "$LOG" > "$tmp/new" 2>/dev/null || : > "$tmp/new"
  n=$(wc -c < "$tmp/new"); partial=0
  if [ "$n" -gt 0 ] && [ "$(tail -c 1 "$tmp/new" | od -An -c | tr -d ' ')" != '\n' ]; then partial=$(tail -n 1 "$tmp/new" | wc -c); fi
  head -c $((n - partial)) "$tmp/new" > "$tmp/whole"
  printf '%s %s' "$off" $((off + n - partial))
}

if [ "$cmd" = read ]; then
  f=$DIR/$arg.read; off=$(cat "$f" 2>/dev/null); case "$off" in ''|*[!0-9]*) off=0 ;; esac
  # shellcheck disable=SC2046  # two plain integers
  set -- $(whole_from "$off")
  cat "$tmp/whole"; printf '%s\n' "$2" > "$tmp/off" && mv -f -- "$tmp/off" "$f"
  exit 0
fi

idx=$DIR/moves.last; off=$(sed -n '1s/^#offset //p' "$idx" 2>/dev/null); case "$off" in ''|*[!0-9]*) off=0 ;; esac
# shellcheck disable=SC2046  # two plain integers
set -- $(whole_from "$off")
start=$1 end=$2
{
  printf '#offset %s\n' "$end"
  { if [ "$start" -eq "$off" ]; then tail -n +2 "$idx" 2>/dev/null; fi
    awk -F'\t' '{ print $2 "\t" $0 }' "$tmp/whole"; } \
    | awk -F'\t' '{ r[$1] = $0 } END { for (k in r) print r[k] }' | LC_ALL=C sort
} > "$tmp/idx" && mv -f -- "$tmp/idx" "$idx"
awk -F'\t' -v t="$arg" 'NR > 1 && $1 == t { sub(/^[^\t]*\t/, ""); print; exit }' "$idx"

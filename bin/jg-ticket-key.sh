#!/usr/bin/env bash
# jg-ticket-key.sh - readable ticket keys (JG-101) as an alias over backlog slugs.
#
# Usage: jg-ticket-key.sh assign <slug> [<project>]   mint and print the slug's key (prints the old one if it has one)
#        jg-ticket-key.sh resolve <key|slug>          print the slug a key names; a slug prints as itself
#        jg-ticket-key.sh key-of <slug>               print the slug's key, or nothing
#        jg-ticket-key.sh sync                        key every open ticket that has none, oldest first
#        jg-ticket-key.sh annotate                    stdin->stdout: put each listed ticket's key first on its row
#        jg-ticket-key.sh annotate-show               stdin->stdout: add `key:` under the `id:` line of a shown ticket
#
# A key is a registered prefix of 2-4 capital letters plus a running number. The long slug
# stays the internal id and is never stored twice: $DATA/ticket-keys.tsv holds only
# `KEY<TAB>slug`, so the key resolves to the slug and the slug to its key. The prefix is
# registered in the home, never invented per ticket: config/ticket-prefixes holds
# `<project> <PREFIX>` lines and config/ticket-prefix the home default; with neither, nothing
# is keyed and the commands that need a prefix say so.
#
# A number is never reused. $DATA/ticket-counters.tsv holds `PREFIX<TAB>last-number`, the
# counter only moves up, and it starts from the highest number already in the key map, so a
# closed or deleted ticket keeps its retired key and a new ticket can never collide with it.
#
# Backfill order is creation order: the item's `(since YYYY-MM-DD)` date, then slug, so the
# same backlog always yields the same keys.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
KEYS="$DATA/ticket-keys.tsv"
COUNTERS="$DATA/ticket-counters.tsv"
BACKLOG="$DATA/backlog.md"
TAB=$'\t'
# shellcheck source=bin/jg-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/jg-tasks-axi-lib.sh"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
die() { printf 'jg-ticket-key: %s\n' "$*" >&2; exit 2; }

prefix_for() {  # [<project>]
  local p='' project=${1-} f
  f="$CONFIG/ticket-prefixes"
  if [ -n "$project" ] && [ -r "$f" ]; then
    p=$(awk -v p="$project" '$1 == p { print $2; exit }' "$f")
  fi
  if [ -z "$p" ] && [ -r "$CONFIG/ticket-prefix" ]; then
    p=$(tr -d '[:space:]' < "$CONFIG/ticket-prefix")
  fi
  case "$p" in
    [A-Z][A-Z]|[A-Z][A-Z][A-Z]|[A-Z][A-Z][A-Z][A-Z]) printf '%s' "$p" ;;
    '') return 1 ;;
    *) die "ticket prefix '$p' must be 2-4 capital letters" ;;
  esac
}

LOCKDIR=
lock() {
  mkdir -p "$DATA" || die "cannot create $DATA"
  LOCKDIR="$DATA/.ticket-keys.lock"
  for _ in $(seq 1 100); do
    mkdir "$LOCKDIR" 2>/dev/null && { trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT; return 0; }
    sleep 0.05
  done
  die "another process holds $LOCKDIR"
}

key_of() { [ -r "$KEYS" ] && awk -F'\t' -v s="$1" '$2 == s { print $1; exit }' "$KEYS"; return 0; }
slug_of() { [ -r "$KEYS" ] && awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$KEYS"; return 0; }

assign() {  # <slug> [<project>]; the caller holds the lock
  local slug=$1 prefix last high key
  key=$(key_of "$slug")
  if [ -n "$key" ]; then printf '%s\n' "$key"; return 0; fi
  prefix=$(prefix_for "${2-}") || die "no ticket prefix registered: set config/ticket-prefix or a project line in config/ticket-prefixes"
  last=$(awk -F'\t' -v p="$prefix" '$1 == p { print $2 }' "$COUNTERS" 2>/dev/null)
  high=$(awk -F'\t' -v p="$prefix-" 'index($1, p) == 1 { n = substr($1, length(p) + 1) + 0; if (n > m) m = n } END { print m + 0 }' "$KEYS" 2>/dev/null)
  last=${last:-0}; high=${high:-0}
  [ "$high" -le "$last" ] || last=$high
  last=$((last + 1))
  key="$prefix-$last"
  [ -z "$(slug_of "$key")" ] || die "key $key is already taken"
  printf '%s\t%s\n' "$key" "$slug" >> "$KEYS" || die "cannot write $KEYS"
  { awk -F'\t' -v p="$prefix" '$1 != p' "$COUNTERS" 2>/dev/null; printf '%s\t%s\n' "$prefix" "$last"; } > "$COUNTERS.new"
  mv "$COUNTERS.new" "$COUNTERS" || die "cannot write $COUNTERS"
  printf '%s\n' "$key"
}

# Open tickets as `since<TAB>slug<TAB>repo-less title`, oldest first.
open_items() {
  local text
  jg_backlog_present "$CONFIG" "$BACKLOG" || return 0
  text=$(jg_backlog_text "$CONFIG" "$BACKLOG") || return 1
  printf '%s\n' "$text" | awk '
    /^## / { open = ($0 !~ /^## Done/); next }
    open && /^- \[.\] / {
      line = substr($0, 7); slug = line; sub(/ - .*/, "", slug)
      title = line; sub(/^[^ ]+ - /, "", title)
      since = "0000-00-00"
      if (match(title, / \(since [0-9-]+\)$/)) {
        since = substr(title, RSTART + 8, RLENGTH - 9); title = substr(title, 1, RSTART - 1)
      }
      sub(/ \(priority: [0-9]\)$/, "", title)
      printf "%s\t%s\t%s\n", since, slug, title
    }' | LC_ALL=C sort -t "$TAB" -k1,1 -k2,2
}

cmd=${1:-}
[ "$#" -gt 0 ] && shift
case "$cmd" in
  -h|--help|'') usage ;;
  resolve)
    [ "$#" -ge 1 ] || die "resolve needs a key or slug"
    case "$1" in
      [A-Z][A-Z]-[0-9]*|[A-Z][A-Z][A-Z]-[0-9]*|[A-Z][A-Z][A-Z][A-Z]-[0-9]*)
        s=$(slug_of "$1")
        [ -n "$s" ] || die "no ticket has the key $1"
        printf '%s\n' "$s" ;;
      *) printf '%s\n' "$1" ;;
    esac ;;
  key-of) [ "$#" -ge 1 ] || die "key-of needs a slug"; key_of "$1" ;;
  assign) [ "$#" -ge 1 ] || die "assign needs a slug"; lock; assign "$@" ;;
  sync)
    prefix_for >/dev/null || exit 0
    lock
    items=$(open_items) || die "the backlog cannot be read, so no ticket was keyed"
    while IFS="$TAB" read -r _since slug _title; do
      [ -z "$slug" ] || [ -n "$(key_of "$slug")" ] || assign "$slug" >/dev/null
    done <<<"$items" ;;
  annotate)
    [ -r "$KEYS" ] || { cat; exit 0; }
    awk -F'\t' 'NR == FNR { k[$2] = $1; next }
      { id = $0; sub(/^ */, "", id); sub(/[, ].*/, "", id)
        if (id in k) { match($0, /^ */); print substr($0, 1, RLENGTH) k[id] "  " substr($0, RLENGTH + 1) } else print }' "$KEYS" - ;;
  annotate-show)
    [ -r "$KEYS" ] || { cat; exit 0; }
    awk -F'\t' 'NR == FNR { k[$2] = $1; next }
      { print } /^  id: / { id = substr($0, 7); if (id in k) print "  key: " k[id] }' "$KEYS" - ;;
  *) die "unknown command '$cmd'; try --help" ;;
esac

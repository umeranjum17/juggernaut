#!/usr/bin/env bash
# jg-critical-path.sh - the migration's critical path: which parts must run here first.
#
# A migration core that is Landed but not In use is not progress. This is the one reader
# of the ordered list, and the refusal that keeps a ship off a later step meanwhile.
#
# Usage: jg-critical-path.sh list
#        jg-critical-path.sh rows
#        jg-critical-path.sh first-pending
#        jg-critical-path.sh row <slug> | parts | title-row <title> | summary [--short]
#        jg-critical-path.sh brief-row <brief>
#        jg-critical-path.sh gate <brief> <project-dir> [<override-text>] [<caller>]
#   list           the critical slugs, one per line, in order
#   rows           slug<TAB>state<TAB>pr for each critical slug, from a fresh one-part probe
#   first-pending  the first critical slug that is not In use, or nothing
#   row            slug<TAB>state<TAB>detail<TAB>pr for any part, from a fresh one-part probe
#   parts          slug<TAB>name<TAB>title pattern for every part, from the probe's part table
#   title-row      the first critical slug whose title pattern matches <title>, or nothing
#   summary        `In use: n of m critical rows (slugs). Pending: slug - detail pr`; --short is
#                  `migration: n of m critical rows In use; first pending slug`
#   brief-row      the brief's `Migration row:` value, or nothing (Setup section only)
#   gate           exit 0 to admit a ship, or exit 1 with one error on stderr
#
# CONFIG. config/migration-card (key=value lines, the file bin/jg-migration-card.sh reads):
#   critical=nats,accounts,wake,inbox   the slugs in the order they must go live; the
#                                       slugs are bin/jg-migration-live.sh's PART_SLUGS
#   project=<name>                      the project this applies to (a project directory's
#                                       basename); the gate never applies without it
# No `critical=` key, or no project match: every command prints nothing and exits 0, so a
# home that does not configure this is unchanged.
#
# THE GATE. While `first-pending` is not empty and the project is the configured one:
#   - a brief with no `Migration row:` line is refused (add one with bin/jg-brief.sh
#     --migration-row <slug|none>), so no migration ship passes by omission;
#   - `Migration row: none` declares non-migration work and is admitted;
#   - `Migration row: <first-pending>` is admitted, since work on the blocking part is
#     always allowed;
#   - any other slug, critical or not, is refused with the first pending part, what its
#     probe measured and the open pull request that finishes it;
#   - <override-text> (bin/jg-spawn.sh --off-critical-path) admits the ship anyway, but
#     only when the brief's Setup quotes the same words on a `Critical-path override:`
#     line, so an override is never silent.
#
# PROBE SEAM. JG_MIGRATION_LIVE_BIN (default bin/jg-migration-live.sh beside this file) is
# run as `<bin> <slug>` and prints `NAME<TAB>state<TAB>detail<TAB>pr`; `<bin> --link` prints
# the card's link. Only the state column is read. A probe that cannot run or prints no
# state counts as pending, the safe direction. This file never edits the probe.
# JG_MIGRATION_TABLE (default: the probe file beside this one) is read, never run, for `parts`.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}"
CFG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}/migration-card"
PROBE="${JG_MIGRATION_LIVE_BIN:-$ROOT/bin/jg-migration-live.sh}"
TABLE="${JG_MIGRATION_TABLE:-$ROOT/bin/jg-migration-live.sh}"
TAB=$'\t'

cfg() { sed -n "s/^$1=//p" "$CFG" 2>/dev/null | tail -n 1; }

# critical_list: the configured slugs, one per line, blanks dropped.
critical_list() { cfg critical | tr ',' '\n' | tr -d '[:blank:]' | sed '/^$/d'; }

# probe_row <slug>: the part's `state<TAB>detail<TAB>pr`, state pending when unreadable.
probe_row() {
  local out state rest
  out=$("$PROBE" "$1" 2>/dev/null | head -n 1) || out=
  # NAME<TAB>state<TAB>detail<TAB>pr: drop the name.
  rest=${out#*"$TAB"}
  [ "$rest" != "$out" ] || rest=
  state=${rest%%"$TAB"*}
  case $state in
    live|pending|absent) printf '%s\n' "$rest" ;;
    *) printf 'pending%sthe probe printed no state for %s%s-\n' "$TAB" "$1" "$TAB" ;;
  esac
}

# first_pending: print "<slug><TAB>state<TAB>detail<TAB>pr" for the first critical part not In use.
first_pending() {
  local slug row
  while IFS= read -r slug; do
    row=$(probe_row "$slug")
    [ "${row%%"$TAB"*}" = live ] || { printf '%s%s%s\n' "$slug" "$TAB" "$row"; return 0; }
  done < <(critical_list)
  return 0
}

# brief_values <brief> <label>: the value of each `<label>: ` line inside the Setup section.
brief_values() {
  awk -v label="$2" '
    /^# / { setup = ($0 == "# Setup"); next }
    setup && index($0, label ": ") == 1 { print substr($0, length(label) + 3) }
  ' "$1"
}

# parts: the probe's part table, one `slug<TAB>name<TAB>title pattern` per part.
parts() {
  local PART_SLUGS=() PART_NAMES=() PART_PR_RE=() i
  eval "$(grep -E '^PART_(SLUGS|NAMES|PR_RE)=\(' "$TABLE" 2>/dev/null)"
  for i in "${!PART_SLUGS[@]}"; do printf '%s\t%s\t%s\n' "${PART_SLUGS[$i]}" "${PART_NAMES[$i]}" "${PART_PR_RE[$i]-}"; done
}

cmd_title_row() {  # <title>: the first critical slug whose title pattern matches
  local slug re
  while IFS= read -r slug; do
    re=$(parts | awk -F'\t' -v s="$slug" '$1 == s { print $3 }')
    if [ -n "$re" ] && printf '%s\n' "${1:-}" | grep -qiE -- "$re"; then printf '%s\n' "$slug"; return 0; fi
  done < <(critical_list)
  return 0
}

cmd_summary() {  # [--short]
  local slug row n=0 live=0 names='' pend=''
  while IFS= read -r slug; do
    row=$(probe_row "$slug"); n=$((n + 1))
    if [ "${row%%"$TAB"*}" = live ]; then live=$((live + 1)); names="$names${names:+, }$slug"
    elif [ -z "$pend" ]; then pend="$slug$TAB$row"; fi
  done < <(critical_list)
  [ "$n" -gt 0 ] || return 0
  slug=${pend%%"$TAB"*}; row=${pend#*"$TAB"}; row=${row#*"$TAB"}
  if [ "${1:-}" = --short ]; then
    printf 'migration: %d of %d critical rows In use; ' "$live" "$n"
    if [ -n "$pend" ]; then printf 'first pending %s\n' "$slug"; else printf 'no row pending\n'; fi
    return 0
  fi
  printf 'In use: %d of %d critical rows (%s).' "$live" "$n" "${names:-none}"
  if [ -n "$pend" ]; then printf ' Pending: %s - %s %s\n' "$slug" "${row%%"$TAB"*}" "${row##*"$TAB"}"; else printf ' Pending: none\n'; fi
}

cmd_rows() {
  local slug row state pr
  while IFS= read -r slug; do
    row=$(probe_row "$slug")
    state=${row%%"$TAB"*}
    pr=${row##*"$TAB"}
    printf '%s\t%s\t%s\n' "$slug" "$state" "$pr"
  done < <(critical_list)
}

cmd_gate() {  # <brief> <project-dir> [<override>] [<caller>]
  local brief=${1:-} project=${2:-} override=${3:-} caller=${4:-jg-spawn.sh}
  local first slug detail pr rest rows overrides n link
  [ -n "$brief" ] && [ -n "$project" ] || { echo "usage: jg-critical-path.sh gate <brief> <project-dir> [<override-text>] [<caller>]" >&2; return 2; }
  [ -n "$(critical_list)" ] || return 0
  [ "$(cfg project)" = "$(basename "$project")" ] || return 0
  first=$(first_pending)
  [ -n "$first" ] || return 0
  slug=${first%%"$TAB"*}
  rest=${first#*"$TAB"}
  rest=${rest#*"$TAB"}
  detail=${rest%%"$TAB"*}
  pr=${rest##*"$TAB"}
  link=$("$PROBE" --link 2>/dev/null | head -n 1) || link=
  rows=$(brief_values "$brief" "Migration row")
  overrides=$(brief_values "$brief" "Critical-path override")
  n=$(printf '%s' "$rows" | grep -c .) || n=0
  if [ "$n" -gt 1 ]; then
    echo "error: $caller: $brief records $n Migration row lines; keep one" >&2
    return 1
  fi
  if [ -n "$override" ]; then
    if ! printf '%s\n' "$overrides" | grep -qxF -- "$override"; then
      echo "error: $caller: --off-critical-path needs the brief's Setup to quote the same words on a 'Critical-path override: <text>' line (bin/jg-brief.sh --off-critical-path); $brief does not" >&2
      return 1
    fi
    return 0
  fi
  if [ -n "$overrides" ]; then
    echo "error: $caller: $brief records a Critical-path override but the spawn has no --off-critical-path; pass the captain's words to the spawn too, or re-scaffold the brief without one" >&2
    return 1
  fi
  case $rows in
    none) return 0 ;;
    "$slug") return 0 ;;
  esac
  {
    if [ -z "$rows" ]; then
      printf 'error: %s: %s has no Migration row line, and the critical path is not In use yet.\n' "$caller" "$brief"
    else
      printf 'error: %s: Migration row %s is off the critical path while %s is not In use.\n' "$caller" "$rows" "$slug"
    fi
    printf '  first part not In use: %s (%s)\n' "$slug" "$detail"
    printf '  open pull request that finishes it: %s\n' "$pr"
    [ -z "$link" ] || printf '  migration card: %s\n' "$link"
    printf '  Work on %s, or record non-migration work with Migration row: none (bin/jg-brief.sh --migration-row <slug|none>).\n' "$slug"
    printf '  Only the captain overrides this: --off-critical-path "<the captain'"'"'s words>" on the brief and the spawn.\n'
  } >&2
  return 1
}

case ${1:-} in
  list) critical_list ;;
  rows) cmd_rows ;;
  first-pending) first_pending | cut -f1 ;;
  brief-row) [ -r "${2:-}" ] || { echo "usage: jg-critical-path.sh brief-row <brief>" >&2; exit 2; }; brief_values "$2" "Migration row" | head -n 1 ;;
  gate) shift; cmd_gate "$@" ;;
  row) probe_row "${2:?usage: jg-critical-path.sh row <slug>}" | sed "s/^/$2\t/" ;;
  parts) parts ;;
  title-row) cmd_title_row "${2:-}" ;;
  summary) cmd_summary "${2:-}" ;;
  *) echo "usage: jg-critical-path.sh list|rows|row <slug>|parts|title-row <title>|summary [--short]|first-pending|brief-row <brief>|gate <brief> <project-dir> [<override-text>] [<caller>]" >&2; exit 2 ;;
esac

#!/usr/bin/env bash
# shellcheck shell=bash
# jg-peak-lib.sh - the two peak-window questions, answered purely and
# deterministically. No network, no clock read, no model.
#
# Usage: . bin/jg-peak-lib.sh
#
#   jg_peak_route_in_peak <route> <epoch>   exit 0 when the route bills at peak
#   jg_peak_route_peak_end <route> <epoch>  print the epoch the current peak ends
#   jg_peak_route_next_start <route> <epoch> print the epoch the next peak starts
#   jg_peak_rows [<file>]                   print the confirmed data rows
#
# defaults/peak-windows.tsv owns every window, its days, its hours, its source
# URL, and the date that source was read; this file owns only the arithmetic, so
# a price change is one data row and no code. A row gates only when its status is
# `confirmed`.
#
# A route is `provider/model` or a bare `model`. A row matches when its model
# glob matches the route (or the route's model part) and, when the route names a
# provider, when that prefix names the row's provider too. A bare route matches
# every row its model glob hits, which is deliberately the conservative union:
# with no provider named, the caller does not know which price list applies.
#
# Windows are UTC day-local and end-exclusive, so 18:00 is off-peak when the
# window closes at 18:00. The epoch is the caller's; the caller never reads a
# clock on this file's behalf.

# jg_peak_file [<root>]: the data file in force for this home.
jg_peak_file() {
  local root=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
  if [ -n "${JG_HOME:-}" ] && [ -f "$JG_HOME/config/peak-windows.tsv" ]; then
    printf '%s\n' "$JG_HOME/config/peak-windows.tsv"
  else
    printf '%s\n' "$root/defaults/peak-windows.tsv"
  fi
}

# jg_peak_rows [<file>]: provider, model glob, days, hours for every confirmed
# row, tab-separated. A missing file yields no rows, which gates nothing.
jg_peak_rows() {
  local file=${1:-} provider glob days hours status
  [ -n "$file" ] || file=$(jg_peak_file)
  [ -f "$file" ] || return 0
  # The source and checked columns are evidence for a reader, not for the
  # arithmetic, so they are read and deliberately not used here.
  while IFS=$'\t' read -r provider glob days hours _ _ status _; do
    [ -n "${provider:-}" ] && [ -n "${glob:-}" ] && [ -n "${days:-}" ] && [ -n "${hours:-}" ] || continue
    [ "${status:-}" = confirmed ] || continue
    printf '%s\t%s\t%s\t%s\n' "$provider" "$glob" "$days" "$hours"
  done <"$file"
}

# jg_peak_day_match <days> <iso-weekday>
jg_peak_day_match() {
  local days=$1 day=$2 part lo hi
  [ "$days" = '*' ] && return 0
  for part in ${days//,/ }; do
    case "$part" in
    *-*)
      lo=${part%-*} hi=${part#*-}
      case "$lo$hi" in '' | *[!0-9]*) continue ;; esac
      [ "$day" -ge "$lo" ] && [ "$day" -le "$hi" ] && return 0
      ;;
    *)
      case "$part" in '' | *[!0-9]*) continue ;; esac
      [ "$day" -eq "$part" ] && return 0
      ;;
    esac
  done
  return 1
}

# _jg_peak_iso_day <epoch>: ISO weekday, 1 = Monday. 1970-01-01 was a Thursday,
# so no date(1) call and no timezone can move this.
_jg_peak_iso_day() { printf '%s\n' $(( ($1 / 86400 + 3) % 7 + 1 )); }

# _jg_peak_midnight <epoch>: the UTC midnight at or before the epoch.
_jg_peak_midnight() { printf '%s\n' $(($1 - $1 % 86400)); }

# _jg_peak_minutes <HH:MM>: sets _JG_PEAK_MINUTES, or fails on anything else.
_jg_peak_minutes() {
  local hh mm
  case "$1" in
  *:*)
    hh=${1%%:*} mm=${1#*:}
    ;;
  *) return 1 ;;
  esac
  case "$hh$mm" in '' | *[!0-9]*) return 1 ;; esac
  [ ${#hh} -le 2 ] && [ ${#mm} -eq 2 ] || return 1
  [ "$((10#$hh))" -lt 24 ] && [ "$((10#$mm))" -lt 60 ] || return 1
  _JG_PEAK_MINUTES=$((10#$hh * 60 + 10#$mm))
}

# _jg_peak_window <hours> <minute-of-day>: prints "<start-minute> <end-minute>"
# for the window covering that minute, or fails.
_jg_peak_window() {
  local hours=$1 tod=$2 part s e
  for part in ${hours//,/ }; do
    case "$part" in *-*) ;; *) continue ;; esac
    _jg_peak_minutes "${part%%-*}" || continue
    s=$_JG_PEAK_MINUTES
    _jg_peak_minutes "${part#*-}" || continue
    e=$_JG_PEAK_MINUTES
    [ "$tod" -ge "$s" ] && [ "$tod" -lt "$e" ] || continue
    printf '%s %s\n' "$s" "$e"
    return 0
  done
  return 1
}

# _jg_peak_row_hits <provider> <glob> <route>: true when the row prices this route.
_jg_peak_row_hits() {
  local provider=$1 glob=$2 route=$3 prefix='' model=$3
  case "$route" in */*)
    prefix=${route%%/*}
    model=${route##*/}
    ;;
  esac
  # Unquoted on purpose: the glob is the pattern.
  # shellcheck disable=SC2254
  case "$model" in
  $glob) ;;
  *)
    case "$route" in
    $glob) ;;
    *) return 1 ;;
    esac
    ;;
  esac
  [ -n "$prefix" ] || return 0
  [ "${prefix%-cloud}" = "${provider%-cloud}" ]
}

# _jg_peak_row_at <days> <hours> <epoch>: prints "<start-epoch> <end-epoch>" of
# the row's window that covers the epoch, or fails.
_jg_peak_row_at() {
  local days=$1 hours=$2 epoch=$3 mid tod w
  jg_peak_day_match "$days" "$(_jg_peak_iso_day "$epoch")" || return 1
  mid=$(_jg_peak_midnight "$epoch")
  tod=$(((epoch % 86400) / 60))
  w=$(_jg_peak_window "$hours" "$tod") || return 1
  printf '%s %s\n' $((mid + ${w% *} * 60)) $((mid + ${w#* } * 60))
}

# jg_peak_route_in_peak <route> <epoch>
jg_peak_route_in_peak() {
  local route=$1 epoch=$2 provider glob days hours
  while IFS=$'\t' read -r provider glob days hours; do
    _jg_peak_row_hits "$provider" "$glob" "$route" || continue
    _jg_peak_row_at "$days" "$hours" "$epoch" >/dev/null && return 0
  done <<EOF
$(jg_peak_rows)
EOF
  return 1
}

# jg_peak_route_peak_end <route> <epoch>: the last end of every window covering
# the epoch, so a route inside two overlapping peaks stays in peak until both end.
jg_peak_route_peak_end() {
  local route=$1 epoch=$2 provider glob days hours w best=
  while IFS=$'\t' read -r provider glob days hours; do
    _jg_peak_row_hits "$provider" "$glob" "$route" || continue
    w=$(_jg_peak_row_at "$days" "$hours" "$epoch") || continue
    w=${w#* }
    if [ -z "$best" ] || [ "$w" -gt "$best" ]; then best=$w; fi
  done <<EOF
$(jg_peak_rows)
EOF
  [ -n "$best" ] && printf '%s\n' "$best"
}

# jg_peak_route_next_start <route> <epoch>: the earliest moment this route next
# bills at peak, searched over the coming week.
jg_peak_route_next_start() {
  local route=$1 epoch=$2 provider glob days hours d mid part cand best='' base
  base=$(_jg_peak_midnight "$epoch")
  while IFS=$'\t' read -r provider glob days hours; do
    _jg_peak_row_hits "$provider" "$glob" "$route" || continue
    for d in 0 1 2 3 4 5 6 7; do
      mid=$((base + d * 86400))
      jg_peak_day_match "$days" "$(_jg_peak_iso_day "$mid")" || continue
      for part in ${hours//,/ }; do
        case "$part" in *-*) ;; *) continue ;; esac
        _jg_peak_minutes "${part%%-*}" || continue
        cand=$((mid + _JG_PEAK_MINUTES * 60))
        [ "$cand" -gt "$epoch" ] || continue
        if [ -z "$best" ] || [ "$cand" -lt "$best" ]; then best=$cand; fi
      done
    done
  done <<EOF
$(jg_peak_rows)
EOF
  [ -n "$best" ] && printf '%s\n' "$best"
}

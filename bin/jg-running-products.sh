#!/usr/bin/env bash
# jg-running-products.sh - report whether each running fleet service is on the current release, and restart the
# ones allowed to restart themselves.
#
# A merge lands on the forge and the service that runs it keeps its old bytes until somebody restarts it by hand,
# so the captain sees the new version in the repository and the old version in the thing that answers.
# This check makes that gap visible and closes it for the services listed as auto.
#
# Usage: jg-running-products.sh [check|refresh] [--config FILE] [--home DIR]
#
# Config: $JG_HOME/config/running-products, else the checkout's defaults/running-products, one service per line,
# `#` starting a comment. Each line holds five fields; quote a command that has spaces:
#   <name> <systemd-user-unit> <running-version-command> <wanted-version-command> <auto|manual>
# A version command is run with bash and its first output line is the version. A command that fails or prints
# nothing yields `unknown`, and unknown never counts as current.
#
# Output, nothing else: `<name>: current <v>` when the service runs the wanted version, or
# `<name>: running <a>, wanted <b>` when it does not. `refresh` restarts every behind `auto` line with
# `systemctl --user restart <unit>` and then re-reads its running version, printing the new result.
# A `manual` line is reported and never restarted, and a service no line names is never touched.
#
# Exit: 0 when every listed service is current, 1 when any is behind, 2 for a usage or config error, 3 when a
# restart fails. `refresh` can still exit 1 after a successful pass, because a behind `manual` line stays behind.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$REPO_ROOT}}"

die() { printf 'jg-running-products: %s\n' "$1" >&2; exit "${2:-2}"; }

usage() {
  sed -n '9,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

split_fields() { # split_fields <line>: set FIELDS, honouring '...' and "..." so a command may hold spaces.
  local s=$1 ch cur='' q=''
  FIELDS=()
  while [ -n "$s" ]; do
    ch=${s:0:1}
    s=${s:1}
    if [ -n "$q" ]; then
      if [ "$ch" = "$q" ]; then q=; else cur+=$ch; fi
    elif [ "$ch" = "'" ] || [ "$ch" = '"' ]; then
      q=$ch
    elif [ "$ch" = ' ' ] || [ "$ch" = $'\t' ]; then
      [ -z "$cur" ] || { FIELDS+=("$cur"); cur=; }
    else
      cur+=$ch
    fi
  done
  [ -z "$cur" ] || FIELDS+=("$cur")
}

version() { # version <command>: print the first line the command prints, or fail when it prints none.
  local out
  out=$(bash -c "$1" 2>/dev/null </dev/null) || return 1
  out=${out%%$'\n'*}
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

walk() { # walk <check|refresh>: one pass over the config; returns 1 when any listed service is behind.
  local act=$1 behind=0 n=0 line name unit mode running wanted
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in '' | '#'*) continue ;; esac
    split_fields "$line"
    n=$((n + 1))
    [ "${#FIELDS[@]}" -eq 5 ] || die "line $n of $CONFIG needs 5 fields, got ${#FIELDS[@]}: $line"
    name=${FIELDS[0]} unit=${FIELDS[1]} mode=${FIELDS[4]}
    case $mode in auto | manual) ;; *) die "line $n of $CONFIG has mode '$mode', not auto or manual" ;; esac
    running=$(version "${FIELDS[2]}") || running=unknown
    wanted=$(version "${FIELDS[3]}") || wanted=unknown
    if [ "$running" != unknown ] && [ "$running" = "$wanted" ]; then
      printf '%s: current %s\n' "$name" "$running"
      continue
    fi
    behind=1
    if [ "$act" = refresh ] && [ "$mode" = auto ]; then
      systemctl --user restart "$unit" || die "systemctl --user restart $unit failed for $name" 3
      running=$(version "${FIELDS[2]}") || running=unknown
      if [ "$running" != unknown ] && [ "$running" = "$wanted" ]; then
        printf '%s: current %s\n' "$name" "$running"
        continue
      fi
    fi
    printf '%s: running %s, wanted %s\n' "$name" "$running" "$wanted"
  done <"$CONFIG"
  return "$behind"
}

CMD=check
CONFIG=
while [ "$#" -gt 0 ]; do
  case $1 in
    check | refresh) CMD=$1; shift ;;
    --config) CONFIG=${2:?--config needs a file}; shift 2 ;;
    --home) JG_HOME=${2:?--home needs a directory}; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
if [ -z "$CONFIG" ]; then
  CONFIG=$JG_HOME/config/running-products
  [ -f "$CONFIG" ] || CONFIG=$REPO_ROOT/defaults/running-products
fi
[ -f "$CONFIG" ] || die "no running-products config at $CONFIG"

walk "$CMD"

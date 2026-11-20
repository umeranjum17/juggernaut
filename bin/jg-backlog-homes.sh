#!/usr/bin/env bash
# jg-backlog-homes.sh - every home whose tickets a reader can open, so sign-off never parses the lead registry.
#
# Usage: jg-backlog-homes.sh --json        (bin/jg-backlog.sh `homes --json` runs it)
#
# Prints a JSON list, this home first, then each Squad Lead of data/squad_leads.md:
#   [{"home":"main","dir":"/abs/home"}, {"home":"lead:<id>","dir":"/abs/home"},
#    {"home":"lead:<id>","dir":null,"remote":true}]
# The name is the one the home's own writes carry as actor (bin/jg-home-name-lib.sh). A lead on another machine is marked
# "remote": true with no dir, because a local path cannot open its tickets. It reads files only: no store is opened and
# nothing is written.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
# shellcheck source=bin/jg-home-name-lib.sh
. "$SCRIPT_DIR/jg-home-name-lib.sh"
# shellcheck source=bin/jg-squad-lead-registry-lib.sh
. "$SCRIPT_DIR/jg-squad-lead-registry-lib.sh"

[ "${1:-}" = --json ] && [ "$#" -eq 1 ] || { printf 'usage: jg-backlog-homes.sh --json\n' >&2; exit 2; }

entry() {  # <home> <home dir or empty> [remote]
  jq -cn --arg home "$1" --arg dir "$2" --arg remote "${3:-}" \
    '{home: $home, dir: (if $dir == "" then null else $dir end)} + (if $remote == "1" then {remote: true} else {} end)'
}

{
  entry "$(jg_home_actor "$JG_HOME")" "$JG_HOME"
  reg=$DATA/squad_leads.md
  if [ -f "$reg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in '- '*) ;; *) continue ;; esac
      squad_lead_registry_parse_line "$line" || continue
      if [ "$SQUAD_LEAD_REGISTRY_REMOTE" = 1 ]; then
        entry "lead:$SQUAD_LEAD_REGISTRY_ID" "" 1
      else
        entry "lead:$SQUAD_LEAD_REGISTRY_ID" "$SQUAD_LEAD_REGISTRY_HOME"
      fi
    done < "$reg"
  fi
} | jq -s .

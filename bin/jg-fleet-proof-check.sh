#!/usr/bin/env bash
# jg-fleet-proof-check.sh - can every registered Squad Lead home show a merge on the board?
#
# Usage:
#   jg-fleet-proof-check.sh
#   jg-fleet-proof-check.sh --help
#
# A home makes its merges visible with two pieces of local config:
#   config/fleet-board   the board file its merge proof cards are appended to
#   config/merge-gate    the executable run before every landing
# A home holding neither merges silently: the card never reaches a board, so the
# outcome of that work never becomes visible. bin/jg-home-seed.sh wires both into
# a new home; this check finds the homes that were seeded before that wiring and
# never had it installed by hand.
#
# It reads this home's own data/squad_leads.md (the registry it owns), inspects
# each registered local home, and writes nothing. One line per home:
#   ok <id>            both pieces are in place
#   FAIL <id>: <why>   the home is registered and cannot show proof
#   skip <id>: remote home on <host>
# A remote home belongs to another host and is never inspected from here, and an
# unreadable registry record is a FAIL because this home cannot then prove that
# home either way. Exit 0 when every inspected home is ok, 1 when any FAIL
# printed. Run it from this home; JG_HOME and JG_DATA_OVERRIDE select another.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
REG="$DATA/squad_leads.md"

# shellcheck source=bin/jg-squad-lead-registry-lib.sh
. "$SCRIPT_DIR/jg-squad-lead-registry-lib.sh"

case "${1:-}" in
  -h|--help)
    sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  '') ;;
  *) echo "usage: jg-fleet-proof-check.sh" >&2; exit 2 ;;
esac

if [ ! -f "$REG" ]; then
  echo "ok: no registered Squad Lead homes ($REG is absent)"
  exit 0
fi

failed=0
inspected=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '- '*) ;;
    *) continue ;;
  esac
  if ! squad_lead_registry_parse_line "$line"; then
    printf 'FAIL %s: unreadable registry record\n' "$(printf '%s\n' "$line" | awk '{ print $2 }')"
    failed=$((failed + 1))
    continue
  fi
  id=$SQUAD_LEAD_REGISTRY_ID
  if [ "$SQUAD_LEAD_REGISTRY_REMOTE" = 1 ]; then
    printf 'skip %s: remote home on %s\n' "$id" "$SQUAD_LEAD_REGISTRY_HOST"
    continue
  fi
  inspected=$((inspected + 1))
  home=$SQUAD_LEAD_REGISTRY_HOME
  why=
  [ -s "$home/config/fleet-board" ] || why="no config/fleet-board"
  if [ ! -x "$home/config/merge-gate" ]; then
    why="${why:+$why; }no executable config/merge-gate"
  fi
  if [ -z "$why" ]; then
    printf 'ok %s\n' "$id"
  else
    printf 'FAIL %s: %s\n' "$id" "$why"
    failed=$((failed + 1))
  fi
done < "$REG"

if [ "$failed" -gt 0 ]; then
  printf 'error: %d of %d registered homes cannot show a merge on the board\n' "$failed" "$inspected" >&2
  printf 'error: rerun the owner-rules add-on installer in each one and copy the primary config/fleet-board into it; bin/jg-home-seed.sh now wires both for a new home\n' >&2
  exit 1
fi
printf '%d registered homes carry the board link and an executable merge gate\n' "$inspected"
exit 0

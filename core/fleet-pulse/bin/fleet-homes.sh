#!/usr/bin/env bash
# Print every known Juggernaut home once, resolved: the main home, the homes data/squad_leads.md
# lists, and sibling ~/.treehouse/juggernaut-*/*/juggernaut homes (override the treehouse root
# with JG_TREEHOUSE). Usage: fleet-homes.sh <main-home>
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo 'usage: fleet-homes.sh <main-home>' >&2
  exit 2
fi
main=$(cd "$1" && pwd -P)
treehouse=${JG_TREEHOUSE:-$HOME/.treehouse}

seen=
add_home() {
  local h=$1 resolved
  [ -d "$h" ] || return 0
  resolved=$(cd "$h" && pwd -P)
  case $'\n'"$seen"$'\n' in
    *$'\n'"$resolved"$'\n'*) return 0 ;;
  esac
  seen=${seen:+$seen$'\n'}$resolved
  printf '%s\n' "$resolved"
}

add_home "$main"
if [ -f "$main/data/squad_leads.md" ]; then
  while IFS= read -r hp; do
    [ -n "$hp" ] && add_home "$hp"
  done < <(sed -n 's/.*(home: \([^;]*\);.*/\1/p' "$main/data/squad_leads.md")
fi
if [ -d "$treehouse" ]; then
  for hp in "$treehouse"/juggernaut-*/*/juggernaut; do
    add_home "$hp"
  done
fi
exit 0

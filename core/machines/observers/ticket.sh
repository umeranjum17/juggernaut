#!/usr/bin/env bash
# ticket.sh - report-only observer of the ticket machine (core/machines/tables/ticket.tsv): one stage.sub word per task.
#
# Usage: ticket.sh <id>   print the state; print nothing when the older readers name no state of the ticket
#
# Until the stage rule over the Beads row exists (plan slice J2), this reads the older readers and maps their word by
# core/machines/maps/ticket-words.tsv: the lane-delivery word when the lane has one, else the task word. A change that
# landed on the trunk and sits in a release pull request reads the release word instead (observers/release.sh): the ticket
# is delivering.joining while the release is under way and released once it merged.
# The first target of the map that is a state of the ticket wins. It only reads.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); root=$(cd "$here/../../.." && pwd -P)
id=${1:?usage: ticket.sh <id>}
for list in lane-delivery task; do
  w=$("$here/$list.sh" "$id" 2>/dev/null) || continue
  [ -n "$w" ] || continue
  if [ "$list" = lane-delivery ]; then
    case $w in landed|live|live-partial|home-behind)
      r=$("$here/release.sh" "$id" 2>/dev/null); case $r in ''|abandoned) ;; *) list=release; w=$r ;; esac ;;
    esac
  fi
  t=$(bash "$root/bin/jg-machine.sh" word ticket-words "$list" "$w" 2>/dev/null | cut -f1) || continue
  for s in ${t//,/ }; do
    bash "$root/bin/jg-machine.sh" edge-check ticket "$s" "$s" >/dev/null 2>&1 && continue
    case $s in =|-|by-rule) continue ;; esac
    echo "$s"; exit 0
  done
done
exit 0

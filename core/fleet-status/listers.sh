#!/usr/bin/env bash
# listers.sh - the record lister of one machine: one `<id><TAB><epoch>` line for each record the machine's observer can be asked
# about, where epoch is when the record's source last changed. An empty epoch means the source holds no time (a source that is
# missing, or a record nobody has written yet): the reading reads unknown, never fresh and never quiet.
#
# Usage: listers.sh <machine>      with STATE, DATA and CONFIG set (core/fleet-status/lib.sh `fs_env`); records.tsv names the machines
#                                  this file serves, the machines whose lister is one line live there. It only reads.
set -u
export LC_ALL=C
: "${STATE:?}" "${DATA:?}" "${CONFIG:?}"
mt() { stat -c %Y -- "$1" 2>/dev/null; }

account() {  # claude.<id> and codex.<id> from each quota reading; a tool with no reading is one record with no time
  local tool f
  for tool in claude codex; do
    f=$STATE/$tool-accounts.json
    if [ -s "$f" ]; then jq -r --arg t "$tool" --arg e "$(mt "$f")" '.accounts[]? | "\($t).\(.id)\t\($e)"' "$f" 2>/dev/null
    else printf '%s.unread\t\n' "$tool"; fi
  done
}
bypass() { awk -F'\t' -v e="$(mt "$CONFIG/proof-bypass")" '$1 !~ /^#/ && $1 != "" { print $1 "\t" e }' "$CONFIG/proof-bypass" 2>/dev/null; }
cleanup() {  # a lane's pending close, and each jg-* entry of the temp folder the reaper owns
  local f i root=${JG_TMP_ROOT:-${TMPDIR:-/tmp}}
  for f in "$STATE"/*.backlog-close; do [ -e "$f" ] || continue; i=${f##*/}; printf '%s\t%s\n' "${i%.backlog-close}" "$(mt "$f")"; done
  for f in "$root"/jg-*; do [ -e "$f" ] || continue; printf 'tmp:%s\t%s\n' "${f##*/}" "$(mt "$f")"; done
}
tickets() { awk -F'\t' 'NF >= 5 && $1 ~ /^[0-9]+$/ { e[$2] = $1 } END { for (t in e) print t "\t" e[t] }' "$DATA/moves.log" 2>/dev/null; }  # the last move of each ticket
hold() { local f i; for f in "$STATE"/*.meta; do [ -e "$f" ] || continue; grep -q '^decision_keys=.' "$f" 2>/dev/null || continue; i=${f##*/}; printf '%s\t%s\n' "${i%.meta}" "$(mt "$f")"; done; }
host() { local f i; for f in "$STATE"/.stops/pool-*.pool-full; do [ -e "$f" ] || continue; i=${f##*/pool-}; printf '%s\t%s\n' "${i%.pool-full}" "$(mt "$f")"; done; }
markers() {  # each state/.<kind>-<pane key> for the kinds the markers table names
  local kind f
  while read -r kind; do
    for f in "$STATE/.$kind"-*; do [ -e "$f" ] || continue; printf '%s\t%s\n' "${f##*/}" "$(mt "$f")"; done
  done < <(awk -F'\t' '$1 == "marker" { print $2 }' "${JG_MACHINES_TABLES:?}/markers.tsv" 2>/dev/null)
}
squad-lead() {  # each registered home; its time is its session record, empty while the session has not answered
  local i; while read -r i; do printf '%s\t%s\n' "$i" "$(mt "$STATE/$i.meta")"; done < <(sed -n 's/^- \([^ ]*\) - .*/\1/p' "$DATA/squad_leads.md" 2>/dev/null)
}
status-verb() { local f i; for f in "$STATE"/*.status; do [ -e "$f" ] || continue; i=${f##*/}; printf '%s\t%s\n' "${i%.status}" "$(mt "$f")"; done; }
supervision() { [ -d "$STATE" ] && printf '%s\t%s\n' "$(basename "$JG_HOME")" "$(mt "$STATE/.last-watcher-beat")"; }  # the beat, not the clock
metas() { local f i; for f in "$STATE"/*.meta; do [ -e "$f" ] || continue; i=${f##*/}; printf '%s\t%s\n' "${i%.meta}" "$(mt "$f")"; done; }

case "${1:-}" in
  account|bypass|cleanup|hold|host|markers|squad-lead|status-verb|supervision) "$1" ;;
  ticket|delivering|proving) tickets ;;
  task|trunk-pointers) metas ;;
  *) echo "usage: listers.sh <machine>" >&2; exit 2 ;;
esac

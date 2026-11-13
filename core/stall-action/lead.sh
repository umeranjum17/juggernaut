#!/usr/bin/env bash
# lead.sh - the rungs of a Squad Lead session (report section 6.10, machine 2 `squad-lead`): a lead has the same rules as a worker.
# Usage: lead.sh check <jg-home>     one sweep over the lead homes Main registered; prints nothing, so it never wakes anyone.
# The beat is the lead's own: state/beats/<lead id> (`<epoch> <event>` lines, the hooks of the beat slice write them). For each
# lead whose home is not parked, retired or still starting, and whose session was not exited on purpose:
#   late-beat   The home has work (machine word `working`) and the lead's last beat is a working one (UserPromptSubmit,
#               PostToolBatch) older than the lead bound (10 min, whole minutes in config/stall-bound-leads). First sweep: ring
#               once (bin/jg-send.sh, fire and forget). A later sweep for the same beat, JG_LEAD_RUNG_GAP seconds (120) after the
#               ring: relaunch the session (bin/jg-control.sh <lead> relaunch). Three relaunches in 30 min: stop, raise
#               supervision-down--lead-<id> so Main reads it. A lead that is idle (last beat Stop) is healthy and is left alone.
#   undelivered The lead's steering inbox (state/<lead>.inbox/*.msg) holds a steer and the lead's last beat is not a working one.
#               At 1 min: ring once for that oldest steer (its own turn-end hook hands it the inbox when a turn ends). At 10 min:
#               raise undelivered--lead-<id>. An empty inbox resolves it.
# Not here: the ready-idle rung (an idle lead with ready work and a free lane) belongs to the refill tick of slice H9.
# One action per beat and per steer, recorded in data/lead-rungs/actions.tsv (epoch, lead, rung, key, ok). Rollback: stop running
# the check; the ledger is history. Seams for tests: JG_LEAD_NOW, JG_LEAD_SEND, JG_LEAD_CONTROL, JG_LEAD_ALERT, JG_LEAD_OBSERVER.
set -u
export LC_ALL=C
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: lead.sh check <jg-home>" >&2; exit 2; }
HOME_DIR=$(cd "$2" && pwd -P)
export JG_HOME=$HOME_DIR
STATE=$HOME_DIR/state DATA=$HOME_DIR/data
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd "$here/../.." && pwd -P)
SEND=${JG_LEAD_SEND:-$HOME_DIR/bin/jg-send.sh}
CONTROL=${JG_LEAD_CONTROL:-$HOME_DIR/bin/jg-control.sh}
ALERT=${JG_LEAD_ALERT:-$HOME_DIR/bin/jg-alert.sh}
OBSERVER=${JG_LEAD_OBSERVER:-$root/core/machines/observers/squad-lead.sh}
NOW=${JG_LEAD_NOW:-$(date +%s)}
GAP=${JG_LEAD_RUNG_GAP:-120}
RELAUNCH_MAX=3 RELAUNCH_WINDOW=1800 UNREAD_RING=60 UNREAD_ALERT=600
LEDGER=$DATA/lead-rungs/actions.tsv
umask 077

minutes() { local v; v=$(tr -dc 0-9 2>/dev/null < "$1"); [ "${v:-0}" -gt 0 ] && printf '%s' "$v" || printf '%s' "$2"; }
BOUND=$(( $(minutes "$HOME_DIR/config/stall-bound-leads" 10) * 60 ))

record() { printf '%s\t%s\t%s\t%s\t%s\n' "$NOW" "$1" "$2" "$3" "$4" >> "$LEDGER"; }  # <lead> <rung> <key> <ok|bad>
done_at() { cat "$LEDGER" 2>/dev/null | awk -F'\t' -v l="$1" -v r="$2" -v k="$3" '$2==l && $3==r && $4==k && $5=="ok" {t=$1} END {print t+0}'; }  # epoch of the last ok row, else 0
recent_relaunches() { cat "$LEDGER" 2>/dev/null | awk -F'\t' -v l="$1" -v c="$(( NOW - RELAUNCH_WINDOW ))" '$2==l && $3=="relaunch" && $1>=c' | wc -l; }
alert() {  # <raise|resolve> <alert> <lead> [note]
  if [ "$1" = raise ]; then "$ALERT" raise "$2" "lead-$3" --home "$HOME_DIR" --note "$4" >/dev/null 2>&1 || true
  else "$ALERT" resolve "$2--lead-$3" >/dev/null 2>&1 || true; fi
}

# ring <lead> <key> <text>: one fire-and-forget steer; the record holds the key so the same beat or steer is rung once.
ring() {
  local id; id=$(printf '%s %s' "$1" "$2" | sha256sum | cut -c1-16)
  if timeout 10 "$SEND" "$1" --fire-and-forget "$id" "$3" >/dev/null 2>&1; then record "$1" ring "$2" ok; else record "$1" ring "$2" bad; fi
}
# relaunch <lead> <key>: replace the lead's session through the control plane.
relaunch() {
  if timeout 60 "$CONTROL" "$1" relaunch >/dev/null 2>&1; then record "$1" relaunch "$2" ok; else record "$1" relaunch "$2" bad; fi
}

late_beat() {  # <lead> <last beat epoch> <event> <home word>
  local id=$1 at=$2 ev=$3 key rung_at
  case $ev in UserPromptSubmit|PostToolBatch) ;; *) return 0 ;; esac
  [ $(( NOW - at )) -ge "$BOUND" ] || return 0
  [ "$4" = working ] || return 0
  key=beat$at
  if [ "$(recent_relaunches "$id")" -ge "$RELAUNCH_MAX" ]; then
    alert raise supervision-down "$id" "Lead $id has no beat for $(( (NOW - at) / 60 )) minutes and $RELAUNCH_MAX relaunches in 30 minutes did not bring it back. Look at its session."
    return 0
  fi
  rung_at=$(done_at "$id" ring "$key")
  if [ "$rung_at" -eq 0 ]; then
    ring "$id" "$key" "Your session has shown no beat for $(( (NOW - at) / 60 )) minutes while your home has work. Check where your lanes stand, and carry on."
  elif [ "$(done_at "$id" relaunch "$key")" -eq 0 ] && [ $(( NOW - rung_at )) -ge "$GAP" ]; then
    relaunch "$id" "$key"
  fi
}

undelivered() {  # <lead> <last beat event>
  local id=$1 ev=$2 oldest age=0 first key
  first=$(find "$STATE/$id.inbox" -maxdepth 1 -name '*.msg' -printf '%T@ %p\n' 2>/dev/null | sort -n | head -n 1 | cut -d' ' -f2-)
  if [ -z "$first" ]; then alert resolve undelivered "$id"; return 0; fi
  case $ev in UserPromptSubmit|PostToolBatch) return 0 ;; esac
  oldest=$(stat -c %Y "$first" 2>/dev/null) || return 0
  age=$(( NOW - oldest )); key=steer${first##*/}
  if [ "$age" -ge "$UNREAD_ALERT" ]; then
    alert raise undelivered "$id" "A steer for lead $id has waited $(( age / 60 )) minutes in its inbox and the lead has not read it."
  elif [ "$age" -ge "$UNREAD_RING" ] && [ "$(done_at "$id" ring "$key")" -eq 0 ]; then
    ring "$id" "$key" "A steer waits in your inbox. Read it now: bin/jg-task-inbox-lib.sh hands it to you at your next turn end, or read the files in your steering inbox."
  fi
}

mkdir -p "$DATA/lead-rungs" 2>/dev/null || exit 0
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  grep -q '^kind=squad_lead$' "$meta" || continue
  id=${meta##*/}; id=${id%.meta}
  [ -e "$STATE/$id.exit" ] && [ "$STATE/$id.exit" -nt "$meta" ] && continue
  word=$(bash "$OBSERVER" "$id" 2>/dev/null) || continue
  case $word in working|idle) ;; *) continue ;; esac
  at='' ev='' rest=''
  read -r at ev rest < <(tail -n 1 "$STATE/beats/$id" 2>/dev/null) || true
  case ${at:-} in ''|*[!0-9]*) continue ;; esac   # no beat record: the pane rule of stall-action.sh keeps this lead
  late_beat "$id" "$at" "$ev" "$word"
  undelivered "$id" "$ev"
done
exit 0

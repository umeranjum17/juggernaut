#!/usr/bin/env bash
# shared-fault.sh - a fault every lane meets is repaired once, and the lanes it stopped resume by themselves (sourced by refusal-reach.sh).
#
# A final refusal no change to the lane's commit clears, because every lane meets it, has two shapes: a conflict only in a registry file all
# lanes share, and an environment fact of the repository (a foreign hook, a hook that cannot be installed). Each had one wait on the lead per
# lane, so the same repair was asked for again and again and no lane resumed when it was done. One owner now holds each distinct fault:
#   fault ticket   data backlog `fault-<project>-<signature>`, filed once, waiting on the lead (wait `lead`, reason `blocker`). The signature
#                  is `shared-<paths>` for the shared files, `hook` for the environment fact. A repair lane under that ticket id is the repair.
#   affected lane  one status line `blocked [key=<signature>-<head>]: waits-for: <fault ticket>`, once per head. The repair's landing runs
#                  resume_waiters (trunk-landing.sh), which steers each lane and resolves that key; no owner turn, no per-lane lead wait.
# Transitions (fault_route): no ticket -> filed (backlog add + wait lead) ; filed -> filed (a second lane: no second ticket, no second wait) ;
# lane head unrouted -> routed (one blocked line). A fault ticket the backlog shows closed is a repaired fault: the next lane to meet it files a new one.
# State: <MEM>/fault-<project>-<signature>.ticket (the ticket id), <MEM>/<task>.<head>.fault (the lane's routing, one line `<epoch> <ticket>`).
# Needs from the caller: STATE, MEM, FMH, DATA_DIR, and refusal_shared_conflict (refusal-reach.sh, which sources this file).

# shellcheck source=core/trunk-landing/verdict.sh
[ -n "${VERDICT_ENV_RE:-}" ] || . "$(dirname "${BASH_SOURCE[0]}")/verdict.sh"

# The fault a final refusal is, as a signature, or nothing (return 1) when it is not a fault all lanes share.
fault_signature() {  # <reason>
  local paths
  if refusal_shared_conflict "$1"; then
    paths=${1#*" in: "}; paths=${paths%%;*}
    printf 'shared-%s\n' "$(printf '%s\n' "$paths" | tr ' ' '\n' | sort -u | tr '\n' '-' | tr -c 'A-Za-z0-9\n-' '-' | sed 's/-*$//; s/^-*//' | cut -c1-60)"
  elif [[ $1 =~ $VERDICT_ENV_RE ]]; then
    printf 'hook\n'
  else
    return 1
  fi
}

# The fault's one open ticket; prints its id. Files it once, waiting on the lead.
fault_ticket() {  # <project name> <signature> <reason>
  local bin=${REFUSAL_BIN:-$FMH/bin} id=fault-$1-$2 mark="$MEM/fault-$1-$2.ticket" shown
  if [ -s "$mark" ]; then
    id=$(cat "$mark")
    shown=$(JG_HOME="$FMH" JG_DATA_OVERRIDE="${DATA_DIR:-$FMH/data}" "$bin/jg-backlog.sh" show "$id" 2>/dev/null) || shown=
    if ! printf '%s\n' "$shown" | grep -Eq '^  closed: "?[0-9]'; then printf '%s\n' "$id"; return 0; fi
    id=$id-$(date +%s)  # the earlier repair landed and the fault is back: a new ticket, still one open at a time
  fi
  JG_HOME="$FMH" JG_DATA_OVERRIDE="${DATA_DIR:-$FMH/data}" "$bin/jg-backlog.sh" add "$id" "[blocker] shared landing fault $2 on $1" --kind ship --priority 1 \
    --body "Every lane of $1 that meets this is refused and no change to its own commit clears it: $3
Why: each affected lane waits on this ticket and resumes by itself when it lands.
Done when: the cause is repaired on the trunk (the shared file resolved or the hook fixed), so a lane that landed past it is not refused." >/dev/null || return 1
  JG_HOME="$FMH" JG_DATA_OVERRIDE="${DATA_DIR:-$FMH/data}" "$bin/jg-backlog.sh" wait "$id" lead blocker >/dev/null || return 1
  printf '%s\n' "$id" > "$mark"; printf '%s\n' "$id"
}

# Route a final refusal that is a shared fault. Returns 1 when the refusal is not one (the caller keeps its own rule), 0 when routed.
fault_route() {  # <task-id> <head> <project dir> <reason>
  local id=$1 head=$2 sig ticket mark=$MEM/$1.$2.fault now
  sig=$(fault_signature "$4") || return 1
  [ ! -s "$mark" ] || return 0
  ticket=$(fault_ticket "$(basename "$3")" "$sig" "$4") || { echo "warning: could not file the shared fault ticket for $id" >&2; return 0; }
  now=$(date +%s)
  printf 'blocked [at=%s] [key=%s-%s]: waits-for: %s (every lane meets this landing refusal: %s)\n' "$now" "$sig" "${head:0:12}" "$ticket" "$(printf '%s' "$4" | cut -c1-160)" \
    | "${REFUSAL_BIN:-$FMH/bin}/jg-lavish-guard.sh" --append "$STATE/$id.status" >/dev/null || { echo "warning: could not attach $id to $ticket" >&2; return 0; }
  printf '%s %s\n' "$now" "$ticket" > "$mark"
}

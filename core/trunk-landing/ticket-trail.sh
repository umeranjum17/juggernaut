#!/usr/bin/env bash
# ticket-trail.sh - what the landing check writes on a lane's ticket the moment it happens (sourced by trunk-landing.sh).
#
# One owner for the two lane events of the lander that reach the ticket, so a single landing (`run`) and a stack (`runbatch`) write alike:
#   trail_proved <id>                    the lander took the lane up: its head holds the whole proof (the done line is refused without
#                                        it), so the ticket reads delivering instead of proving. Writes the moment proved_at.
#   trail_refused <id> <head> <state>    the lander refused the lane (<state> is the verdict line verdict_record stores: `final ...`,
#                                        `retry <n> ...` or `wait ...`). The ticket stays delivering and keeps the reason: a land event
#                                        with the reason in its payload, and the wait on the one who owes the next move, `worker` for a
#                                        final refusal (the lane fixes it) and `tick` for a retry or a wait (the check tries again),
#                                        both with the reason `blocker`. A newer status line of the lane clears the wait (bin/jg-wait-trace.sh).
# A failed write is one warning line and never stops a landing. The ticket is the `ticket=` line of the lane's record, else its task id.
[ -z "${_JG_TICKET_TRAIL:-}" ] || return 0
_JG_TICKET_TRAIL=1

trail_ticket() {  # <id>
  local t; t=$(sed -n 's/^ticket=//p' "$STATE/$1.meta" 2>/dev/null | tail -n 1); printf '%s\n' "${t:-$1}"
}

trail_proved() {  # <id>
  local t out; t=$(trail_ticket "$1")
  out=$(JG_HOME="$FMH" JG_DATA_OVERRIDE="$DATA_DIR" "$FMH/bin/jg-backlog.sh" moment "$t" proved_at 2>&1) \
    || echo "warning: proved_at of $t was not written: $(printf '%s' "$out" | head -n 1)" >&2
}

trail_refused() {  # <id> <head> <verdict line>
  local t who reason payload
  t=$(trail_ticket "$1"); case $3 in final*) who=worker ;; *) who=tick ;; esac
  reason=$(printf '%s' "${3#* }" | tr '\n' ' ' | cut -c1-300)
  payload=$(jq -cn --arg r "$reason" --arg w "$who" '{reason: $r, wait: $w}') || return 0
  if ! JG_HOME="$FMH" JG_DATA_OVERRIDE="$DATA_DIR" "$FMH/bin/jg-backlog.sh" trace record "$t" land work-id \
      "$1@${2:0:12}#$(printf '%s' "$3" | cksum | cut -d' ' -f1)" --source jg-trunk-refuse --payload "$payload" >/dev/null 2>&1 \
    || ! JG_HOME="$FMH" JG_DATA_OVERRIDE="$DATA_DIR" "$FMH/bin/jg-backlog.sh" wait "$t" "$who" blocker >/dev/null 2>&1; then
    echo "warning: the refusal of $t was not written on its ticket" >&2; return 0
  fi
  # The wait belongs to the status line it answered: the tick's wait step takes it off when the lane writes a newer line.
  mkdir -p "$STATE/.wait-trace" && printf 'refused:%s\n' "$(tail -n 1 "$STATE/$1.status" 2>/dev/null | sed -n 's/^[a-z-]*[^[]*\[at=\([0-9][0-9]*\)\].*/\1/p')" > "$STATE/.wait-trace/$1"
}

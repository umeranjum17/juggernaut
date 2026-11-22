#!/usr/bin/env bash
# ticket-trail.sh - what the landing check writes on a lane's ticket the moment it happens (sourced by trunk-landing.sh).
#
# One owner for the landing check's ticket transitions, so a single landing (`run`) and a stack (`runbatch`) write alike:
#   trail_proved <id>                    the lander took the lane up: its head holds the whole proof (the done line is refused without
#                                        it), so the ticket reads delivering instead of proving. Writes the moment proved_at.
#   trail_refused <id> <head> <state>    the lander refused the lane (<state> is the verdict line verdict_record stores: `final ...`,
#                                        `retry <n> ...` or `wait ...`). The ticket stays delivering and keeps the reason: a land event
#                                        with the reason in its payload, and the wait on the one who owes the next move, `worker` for a
#                                        final refusal (the lane fixes it) and `tick` for a retry or a wait (the check tries again),
#                                        both with the reason `blocker`. A newer status line of the lane clears the wait (bin/jg-wait-trace.sh).
#   No standing landing receipt      no close. A reverted receipt or a different current lane is never replayed.
#   Standing receipt, open ticket   close through the backlog's existing guards, independently of cleanup.
#   Close refused                   keep the ticket open, alert with the cause once, and retry from the receipt on a later check.
#   Ticket closed                   settle that receipt so replay leaves a later reopening alone.
# A failed write never stops a landing. Before landing, use the `ticket=` line of the lane's record, else its task id.
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

# Latest standing receipt per project and lane. A later revert cancels it; another landing can supersede the revert.
trail_landing_receipts() {  # [<id> <project>]
  [ -s "$DATA_DIR/trunk-landings.tsv" ] || return 0
  awk -F '\t' -v id="${1-}" -v project="${2-}" '
    project != "" && $2 != project { next }
    /^revert-/ { delete latest[$2 SUBSEP substr($1, 8)]; next }
    NF >= 5 && (id == "" || $1 == id) {
      ticket = "-"
      for (i = 6; i <= NF; i++) if ($i ~ /^ticket=/) ticket = substr($i, 8)
      latest[$2 SUBSEP $1] = $1 "\t" $2 "\t" $3 "\t" ticket
    }
    END { for (k in latest) print latest[k] }
  ' "$DATA_DIR/trunk-landings.tsv"
}

trail_close_landed() (  # <id> <project> <receipt commit> <ticket>; success means the ticket changed
  local id=$1 pn=$2 commit=$3 ticket=$4 record previous out cause hold_rc=0 control='' meta branch
  local slug='^[A-Za-z0-9][A-Za-z0-9._-]*$'
  local proj=$FMH/projects/$pn
  [[ $id =~ $slug && $pn =~ $slug && $ticket =~ $slug && $commit =~ ^[a-f0-9]{40,64}$ ]] || return 1
  lane_on_trunk "$proj" "$commit" || return 1
  record=$MEM/$id.$pn.ticket-close
  if [ "$LANDING_COMMAND" = check ]; then
    # Direct land and land-batch hold this while they finish provenance. Check the lane under the same lock.
    control=$STATE/.control-$id.lock
    jg_lock_try_acquire "$control" || return 1
    trap 'jg_lock_release "$control"' EXIT
    meta=$STATE/$id.meta
    if [ -f "$meta" ]; then
      [ "$(mval "$meta" project)" = "$proj" ] || return 1
      branch=$(mval "$meta" branch); branch=${branch:-fm/$id}
      [ "$(git -C "$proj" rev-parse --verify --quiet "refs/heads/$branch^{commit}")" = "$commit" ] || return 1
    fi
  fi
  jg_lock_try_acquire "$record.lock" || return 1
  trap 'jg_lock_release "$record.lock"; [ -z "$control" ] || jg_lock_release "$control"' EXIT
  previous=$(cat "$record" 2>/dev/null) || previous=
  [ "$previous" != "$commit closed" ] || return 1
  if out=$(JG_DATA_OVERRIDE="$DATA_DIR" "$FMH/bin/jg-backlog.sh" show "$ticket" 2>&1); then
    if grep -qx '  state: done' <<< "$out"; then
      printf '%s closed\n' "$commit" > "$record"
      return 1
    fi
    out=$(JG_DATA_OVERRIDE="$DATA_DIR" "$FMH/bin/jg-captain-hold.sh" open "$ticket" --distinguish-absent 2>&1) || hold_rc=$?
    case $hold_rc in
      0) out='the ticket still has an open captain decision' ;;
      1)
        if out=$(JG_DATA_OVERRIDE="$DATA_DIR" "$FMH/bin/jg-backlog.sh" 'done' "$ticket" --note 'local-trunk' --json 2>&1); then
          jq -e '.ok == true and .task.state == "done"' <<< "$out" >/dev/null 2>&1 || return 1
          printf '%s closed\n' "$commit" > "$record"
          jq -e '.already != true' <<< "$out" >/dev/null 2>&1
          return $?
        fi ;;
      3) return 1 ;;  # The row disappeared during the check.
    esac
  elif grep -qx 'code: NOT_FOUND' <<< "$out"; then
    return 1  # Some lanes have no backlog row.
  fi
  cause=${out%%$'\n'*}; cause=${cause:-the backlog gave no reason}
  [ "$previous" != "$commit $cause" ] || return 1
  cleanup_outbox "ALERT: ticket $ticket is still open after $id landed at ${commit:0:12}: $cause"
  printf '%s %s\n' "$commit" "$cause" > "$record"
  return 1
)

# A check can finish the close from the receipt even if the landing process and its metadata are gone.
trail_repair_tickets() {
  local receipts backlog id pn commit ticket proj repair_rc=1
  receipts=$(trail_landing_receipts); [ -n "$receipts" ] || return 1
  backlog=$(JG_DATA_OVERRIDE="$DATA_DIR" "$FMH/bin/jg-backlog.sh" list --fields item 2>/dev/null) || return 1
  while IFS=$'\t' read -r id pn commit ticket; do
    proj=$FMH/projects/$pn
    [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $pn =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
    [ -d "$proj" ] || continue
    local_trunk "$proj" || continue
    lane_landing_in_flight "$id" && continue
    if trail_close_landed "$id" "$pn" "$commit" "$ticket"; then
      cleanup_outbox "closed ticket $ticket from the landing receipt at ${commit:0:12}"
      repair_rc=0
    fi
  done < <(awk -F ',' '
    FILENAME == ARGV[1] {
      if ($1 !~ /^  [A-Za-z0-9][A-Za-z0-9._-]*$/) next
      name = substr($1, 3); repo = $4; gsub(/"/, "", repo)
      direct[name] = name; project[name] = repo
      if ($NF in by_lane) by_lane[$NF] = ""; else by_lane[$NF] = name
      next
    }
    {
      split($0, r, "\t")
      ticket = (r[4] != "-" ? direct[r[4]] : (r[1] in direct ? direct[r[1]] : by_lane[r[1]]))
      if (ticket != "" && (project[ticket] == "-" || project[ticket] == r[2]))
        print r[1] "\t" r[2] "\t" r[3] "\t" ticket
    }
  ' <(printf '%s\n' "$backlog") <(printf '%s\n' "$receipts"))
  return "$repair_rc"
}

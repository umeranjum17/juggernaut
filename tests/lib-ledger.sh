#!/usr/bin/env bash
# Sourced by a test that reads landing times from the ticket ledger: a fixture home's ticket tables, and the two records
# a landing leaves there (the lane's ready time and the lander's `land` event with its timing payload) plus its trunk-landings row.
# Needs tests/lib.sh sourced first.
unset BEADS_ACTOR JG_BACKLOG_LANE JG_BACKLOG_SPAWN_GEN JG_BACKLOG_AGENT JG_BACKLOG_LANE_HANDOVER
export TZ=UTC JG_TRUNK_LATENCY_BACKLOG=$ROOT/bin/jg-backlog.sh  # a fixture home holds no bin of its own

ledger_cli() { local h=$1; shift; JG_HOME=$h JG_DATA_OVERRIDE=$h/data "$ROOT/bin/jg-backlog.sh" "$@"; }
ledger_home() {  # <home dir>: a home with its ticket tables and no landings
  mkdir -p "$1/state"
  jg_test_beads_home "$1"
}
# ledger_landing <home> <task> <commit> <head> <landed> <ready|-> <stage> <queue_s|-> <landing_s|-> <gate_s> <load|-> <why|->
# A first call for a task files its ticket; each call adds the landing's trunk-landings row and its `land` event. The ledger only
# adds (a repeat of one event adds nothing), so a test changes what a feed reads by landing one more commit.
ledger_landing() {
  local h=$1 task=$2 commit=$3 head=$4 landed=$5 ready=$6 payload
  ledger_cli "$h" show "$task" >/dev/null 2>&1 || {
    ledger_cli "$h" add "$task" "[feature] $task" --priority 2 --body why >/dev/null || fail "file the ticket of $task"
    JG_HOME=$h python3 -I "$ROOT/core/item-store/adapters/bd_compat.py" update "$task" --set-metadata "task=$task" >/dev/null || fail "name the task of $task"
  }
  printf '%s\tdemo\t%s\t%s\tfull\n' "$task" "$commit" "$landed" >> "$h/data/trunk-landings.tsv"
  [ "$ready" = - ] || ledger_cli "$h" trace record "$task" commit work-id "$task@done-$ready" --source jg-done --at "$ready" >/dev/null || fail "record the ready time of $task"
  payload=$(jq -nc --arg head "$head" --arg stage "$7" --arg q "$8" --arg l "$9" --arg g "${10}" --arg load "${11}" --arg why "${12}" '
    def n: if . == "-" then null else tonumber end;
    {head: $head, stage: $stage, queue_s: ($q | n), landing_s: ($l | n), gate_s: ($g | n), load: ($load | n), queue_why: (if $why == "-" then null else $why end)}')
  ledger_cli "$h" trace record "$task" land git-sha "$commit" --source jg-trunk-land --at "$landed" --payload "$payload" >/dev/null || fail "record the landing of $task"
}

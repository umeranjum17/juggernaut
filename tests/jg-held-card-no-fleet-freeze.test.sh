#!/usr/bin/env bash
# One open captain card must not freeze the fleet (no-fleet-freeze-on-one-card).
# AGENTS.md section 10: a held item never stops the fleet; only work it is linked to is refused.
# Spawn, merge and landing scope their refusals to linked work (tests/jg-pending-decision-blocks-work.test.sh S2/M2).
# This journey covers the last path where one open decision hid unrelated work: the fleet snapshot's
# idle-with-ready-work flag for a Squad Lead home. The real bin/jg-fleet-snapshot.sh and bin/jg-fleet-view.sh
# read each lead's published home summary; a lead with ready backlog items and no worker working is flagged
# whether or not the home also has a captain decision open. A worker actually working still clears the flag.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(jg_test_tmproot jg-held-card-no-freeze)
MAIN="$TMP_ROOT/main"
mkdir -p "$MAIN/data" "$MAIN/state" "$MAIN/config" "$MAIN/projects"

NOW_EPOCH=$(date +%s)
NOW_ISO=$(date -u -d "@$NOW_EPOCH" +%Y-%m-%dT%H:%M:%SZ)

# lead <id> <state> <ready> <active> <decisions>: a seeded Squad Lead home that published a summary.
lead() {
  local id=$1 state=$2 ready=$3 active=$4 decisions=$5 home="$TMP_ROOT/leads/$1" child='[]' decided='[]'
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.jg-squad-lead-home"
  printf '# lead\n' > "$home/AGENTS.md"
  [ "$active" -eq 0 ] || child='[{"id":"w1","kind":"ship","state":"working","repo":null,"name":null,"source":"status","doing":"building"}]'
  [ "$decisions" -eq 0 ] || decided='[{"id":"card1","key":"card1","verb":"captain-hold","summary":"Pick the export format","reason":null,"source":"backlog"}]'
  jq -n --arg home "$home" --arg now "$NOW_ISO" --argjson epoch "$NOW_EPOCH" --arg state "$state" \
    --argjson ready "$ready" --argjson child "$child" --argjson decided "$decided" '{
      schema:"jg-squad-lead-home-summary.v1", hold_classifier_schema:"jg-captain-hold-buckets.v1",
      home:$home, generated:$now, generated_epoch:$epoch, valid:true, reason:null,
      invalidity:{kind:null,ids:[]}, state:$state, ready_work:$ready,
      active_children:$child, decisions_open:$decided, holds:[], queued:[], landed:[], endpoints:[],
      counts:{active_children:($child|length), decisions_open:($decided|length), holds:0, queued:$ready, landed:0, endpoints:0},
      omitted:[]}' > "$home/state/home-summary.json"
  printf -- '- %s - fixture lead (home: %s; scope: s; projects: p; added 2026-11-09)\n' "$id" "$home" >> "$MAIN/data/squad_leads.md"
}

lead lead-clean no_active_work 2 0 0   # control: nothing open, ready work waiting
lead lead-held captain_decision 2 0 1   # one open card, no worker, ready work waiting
lead lead-busy captain_decision 2 1 1   # one open card, a worker working, ready work waiting
lead lead-empty captain_decision 0 0 1  # one open card, nothing ready

SNAP=$(env JG_HOME="$MAIN" JG_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/jg-fleet-snapshot.sh" --json 2>"$TMP_ROOT/snap.err") \
  || fail "fleet snapshot failed: $(cat "$TMP_ROOT/snap.err")"

idle() {  # <lead-id>: the snapshot's idle_with_ready_work for it
  printf '%s' "$SNAP" | jq -r --arg id "$1" '.squad_lead_current.records[] | select(.id == $id) | .idle_with_ready_work'
}
for id in lead-clean lead-held lead-busy lead-empty; do
  printf '%s' "$SNAP" | jq -e --arg id "$id" '.squad_lead_current.records[] | select(.id == $id) | .provenance.summary_valid == true' >/dev/null \
    || fail "fixture lead $id did not read as a valid structured home: $(printf '%s' "$SNAP" | jq -c --arg id "$id" '.squad_lead_current.records[] | select(.id == $id) | .current')"
done

assert_equals true "$(idle lead-clean)" "a lead with ready work and nothing open is idle with ready work"
assert_equals true "$(idle lead-held)" "one open captain card must not hide a lead's ready work when no worker is working"
assert_equals false "$(idle lead-busy)" "a lead with a worker working is not idle"
assert_equals false "$(idle lead-empty)" "a lead with an open card and no ready work has nothing to dispatch"

VIEW=$(env JG_HOME="$MAIN" JG_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/jg-fleet-view.sh" 2>&1) || fail "fleet view failed: $VIEW"
assert_contains "$VIEW" "IDLE WITH READY WORK: lead-held" "the fleet view must flag the lead whose only open item is a captain card"
assert_contains "$VIEW" "IDLE WITH READY WORK: lead-clean" "the fleet view must flag the control lead"
assert_not_contains "$VIEW" "IDLE WITH READY WORK: lead-busy" "the fleet view must not flag a lead with a worker working"
assert_not_contains "$VIEW" "IDLE WITH READY WORK: lead-empty" "the fleet view must not flag a lead with nothing ready"
pass "one open captain card never hides a lead's ready work from the fleet snapshot and view"

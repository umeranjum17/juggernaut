#!/usr/bin/env bash
# tests/jg-dapr-workflow.test.sh - the wait ladder as a Dapr workflow, on real Dapr processes.
#
# What it proves, on a throw-away home with free ports and a private tool prefix: the scheduler,
# the sidecar and the worker come up; a workflow instance fires its rungs on REAL durable timers
# (the first no earlier than its timer, the second after it, each queued as the shell ladder
# queues its wake); the owner's `cleared` event ends an episode before its timer fires and nothing
# is delivered; and the owner install path writes exactly the argv the detached run executes,
# refuses a home that does not own the units, and touches no real service manager.
# Skipped when python3, Go, daprd or the network (for the scheduler release) is absent.
# This is also the test that owns journeys/dapr-workflow.sh (the done-done journey runs this file).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for tool in python3 go daprd curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'skip: no %s\n' "$tool"; exit 0; }
done

TMP=$(jg_test_tmproot jg-dapr-workflow)
TMP=$(cd "$TMP" && pwd)
HOME_DIR=$TMP/home
mkdir -p "$HOME_DIR/state" "$TMP/prefix"
export JG_HOME=$HOME_DIR JG_STATE_OVERRIDE=$HOME_DIR/state NPM_CONFIG_PREFIX=$TMP/prefix
# A fixture never reaches the machine's bus (tests/lib.sh points the wake path at port 1) and
# never installs into the real tool prefix: the scheduler lands in the private one above.
WF=$ROOT/bin/jg-dapr-workflow.sh
STATE=$HOME_DIR/state
export JG_WAIT_ALERT_SECS=2 JG_WAIT_ESCALATE_SECS=4 JG_WAIT_CARD_SECS=60 JG_PROMPT_REALERT_SECS=60

cleanup() { bash "$WF" down >/dev/null 2>&1 || true; }
trap cleanup EXIT

# The five escalation behaviours read the shared rule file; the test points the worker at a copy
# with small numbers (a 3s coalesce window, two wakes per hour for the budget lane, a 2x back-off
# capped at 8s) so recorded waits play out in seconds. The routing is by lane name in the key.
OPT=$TMP/escalation-optimization.json
jq '.spec.priority = [{class:"urgent",kind:"*",key:"*",payload:"*security*"},
      {class:"silent",kind:"check",key:"*-silent-a-*",payload:"*"},{class:"batch",kind:"check",key:"*-merged-*",payload:"*"}]
    | .spec.targets = [{key:"*-bud-*",target:"budget-lane"},{key:"*-back-*",target:"lead"},{key:"*",target:"main"}]
    | .spec.budget.targets = {main:50,lead:50,"budget-lane":2} | .spec.coalesce.windowSeconds = 3 | .spec.coalesce.groups = [{name:"merged",key:"*-merged-*"},{name:"other",key:"*"}]
    | .spec.backoff = {baseSeconds:2,factor:2,capSeconds:8,resetOn:"payload-change"}' \
  "$ROOT/core/bus/workflows/escalation-optimization.json" >"$OPT" || fail "cannot build the rule copy"
export JG_ESCALATION_OPT=$OPT

if ! out=$(bash "$ROOT/bin/jg-bootstrap.sh" install dapr-scheduler 2>&1); then
  printf 'skip: the pinned scheduler cannot be fetched here: %s\n' "$out"
  exit 0
fi

# wait_until <seconds> <command...>: poll that command until it succeeds.
wait_until() {
  local secs=$1 _
  shift
  for _ in $(seq 1 $((secs * 5))); do "$@" && return 0; sleep 0.2; done
  return 1
}
fired() { bash "$WF" episode "$1" 2>/dev/null | grep -q "fired=[^ ]*$2"; }
queue_has() { [ -f "$STATE/.wake-queue" ] && grep -q "$1" "$STATE/.wake-queue"; }

# 1. The processes come up, and a second `up` changes nothing.
if ! out=$(bash "$WF" up 2>&1); then
  # etcd preallocates its 64 MB write-ahead log; a temp directory whose quota refuses that cannot
  # host a scheduler at all, which says nothing about the code under test.
  if grep -q 'disk quota exceeded' "$STATE"/workflow/scheduler.log 2>/dev/null; then
    printf 'skip: this temp directory refuses the scheduler'"'"'s write-ahead log (disk quota); set TMPDIR to a disk path\n'
    exit 0
  fi
  fail "up failed: $out"
fi
for part in scheduler sidecar worker; do
  printf '%s\n' "$out" | grep -q "^$part .*running pid" || fail "up did not report $part running: $out"
done
bash "$WF" status >/dev/null || fail "status says a part is not running right after up"
pids=$(cat "$STATE"/workflow/*.pid)
bash "$WF" up >/dev/null 2>&1 || fail "a second up failed"
[ "$pids" = "$(cat "$STATE"/workflow/*.pid)" ] || fail "a second up restarted a part"
pass "scheduler, sidecar and worker run, and a second up changes nothing"

# 2. A real timer fires: the owner rung no earlier than its 2s timer, the escalation later.
key=waiting-timer-home-lane-g1-wait
t0=$(date +%s.%N)
bash "$WF" start wait lane "$key" >/dev/null 2>&1 || fail "start failed"
wait_until 20 fired "$key" owner || fail "the owner rung never fired: $(bash "$WF" episode "$key" 2>&1)"
t_owner=$(date +%s.%N)
awk -v a="$t0" -v b="$t_owner" 'BEGIN { exit !(b - a >= 2.0) }' \
  || fail "the owner rung fired in under its 2s timer ($t0 -> $t_owner): a timer that did not wait"
printf '# owner rung (2s timer) fired %s s after the instance started\n' "$(awk -v a="$t0" -v b="$t_owner" 'BEGIN { printf "%.2f", b - a }')"
queue_has "$key-owner" || fail "the owner rung queued no wake row: $(cat "$STATE/.wake-queue" 2>/dev/null)"
grep -q "level=owner; owning lead\\|level=owner; Main must recheck" "$STATE/.wake-queue" \
  || fail "the owner wake line does not name who rechecks: $(cat "$STATE/.wake-queue")"
wait_until 20 fired "$key" escalate || fail "the escalation rung never fired: $(bash "$WF" episode "$key" 2>&1)"
t_esc=$(date +%s.%N)
awk -v a="$t0" -v b="$t_esc" 'BEGIN { exit !(b - a >= 4.0) }' \
  || fail "the escalation rung fired in under its 4s timer ($t0 -> $t_esc)"
printf '# escalation rung (4s timer) fired %s s after the instance started\n' "$(awk -v a="$t0" -v b="$t_esc" 'BEGIN { printf "%.2f", b - a }')"
queue_has "$key-escalate" || fail "the escalation rung queued no wake row"
grep -q "level=escalate; Main must recheck" "$STATE/.wake-queue" || fail "the escalation wake does not go to Main: $(cat "$STATE/.wake-queue")"
pass "a workflow instance fires its rungs on real timers, the escalation to Main after the owner rung"

# 3. The owner's cleared event ends the episode and stops the ladder.
bash "$WF" clear "$key" >/dev/null 2>&1 || fail "clear failed"
wait_until 20 bash -c "bash '$WF' episode '$key' 2>/dev/null | grep -q COMPLETED" \
  || fail "a cleared episode did not complete: $(bash "$WF" episode "$key" 2>&1)"
bash "$WF" episode "$key" 2>/dev/null | grep -q '"cleared":true' \
  || fail "the completed episode does not say it was cleared: $(bash "$WF" episode "$key" 2>&1)"
key2=waiting-timer-home-lane2-g1-wait
JG_WAIT_ALERT_SECS=30 JG_WAIT_ESCALATE_SECS=60 bash "$WF" start wait lane2 "$key2" >/dev/null 2>&1 || fail "second start failed"
sleep 1
bash "$WF" clear "$key2" >/dev/null 2>&1 || fail "clear of the second episode failed"
wait_until 20 bash -c "bash '$WF' episode '$key2' 2>/dev/null | grep -q COMPLETED" || fail "the second cleared episode did not complete"
if queue_has "$key2"; then fail "an episode cleared before its timer still delivered: $(cat "$STATE/.wake-queue")"; fi
pass "clearing an episode before its timer ends it and delivers nothing"

# 3b. The five escalation behaviours, on recorded waits. Each row of the fixture is one recorded
# wait episode; all start together and are read at their checkpoints. The same recorded waits on
# a worker without the rules wake the owner for every lane (no silence, no budget, a flat
# re-alert cadence, no digest, no auto-resolve), which is how this section fails before the change.
printf '# state the wait was raised about\nblocked [at=1]: waiting for an answer\n' >"$STATE/resolve-a.status"
t0=$(date +%s)
while IFS=$'\t' read -r scen task key payload envs; do
  case "$scen" in '' | '#'*) continue ;; esac
  # shellcheck disable=SC2086
  env $envs bash "$WF" start wait "$task" "$key" "$payload" >/dev/null 2>&1 || fail "start of recorded wait $task failed"
done <"$ROOT/tests/fixtures/escalation-waits.tsv"
printf 'working [at=2]: the lane answered\n' >>"$STATE/resolve-a.status"
rkey() { awk -F'\t' -v t="$1" '$2 == t { print $3 }' "$ROOT/tests/fixtures/escalation-waits.tsv"; }
owner_rows() { grep -c -- "$(rkey "$1")-owner" "$STATE/.wake-queue" 2>/dev/null || true; }

# priority + budget: a silent wait wakes nobody; of three ordinary waits on a 2-per-hour lane two
# wake and one is held over budget; the security wait wakes even though that budget is spent.
wait_until 20 fired "$(rkey bud-urgent)" owner || fail "the urgent wait never woke its owner (budget must not stop it)"
sleep 1
[ "$(owner_rows silent-a)" = 0 ] || fail "a silent-class wait woke its owner: $(cat "$STATE/.wake-queue")"
bash "$WF" episode "$(rkey silent-a)" 2>/dev/null | grep -q 'owner:silent' || fail "the silent wait left no record that it was dropped: $(bash "$WF" episode "$(rkey silent-a)" 2>&1)"
woken=$((  $(owner_rows bud-1) + $(owner_rows bud-2) + $(owner_rows bud-3) ))
[ "$woken" = 2 ] || fail "a budget of 2 wakes per hour woke $woken of 3 ordinary waits: $(cat "$STATE/.wake-queue")"
[ "$(owner_rows bud-urgent)" = 1 ] || fail "the security wait did not wake its owner once"
pass "priority: a silent wait wakes nobody, a security wait ignores the spent budget; budget: 2 of 3 ordinary waits wake"

# coalesce: three waits on one group wake nobody one by one; one digest names all three.
wait_until 20 queue_has escalation-digest-merged || fail "no digest wake after the 3s window: $(cat "$STATE/.wake-queue")"
[ "$(grep -c escalation-digest-merged "$STATE/.wake-queue")" = 1 ] || fail "the group woke more than once"
grep escalation-digest-merged "$STATE/.wake-queue" | grep -q '3 events' || fail "the digest does not cover all three waits: $(grep escalation-digest-merged "$STATE/.wake-queue")"
[ "$(owner_rows merged-a)$(owner_rows merged-b)$(owner_rows merged-c)" = 000 ] || fail "a coalesced wait still woke its owner on its own"
pass "coalesce: three grouped waits leave as one digest wake"

# back-off: re-alerts at 2s, 4s then 8s gaps after the card rung; a flat cadence would have fired a fourth by now.
wait_until 30 fired "$(rkey back-1)" re-alert-2 || fail "re-alert-2 never fired: $(bash "$WF" episode "$(rkey back-1)" 2>&1)"
bash "$WF" episode "$(rkey back-1)" 2>/dev/null | grep -q 're-alert-3' && fail "re-alert-3 fired right after re-alert-2: the gaps did not grow"
pass "back-off: each re-alert waits twice as long as the one before, up to the cap"

# auto-resolve: the lane's own status changed, so its wait closes at its owner rung and wakes nobody.
wait_until 20 bash -c "bash '$WF' episode '$(rkey resolve-a)' 2>/dev/null | grep -q COMPLETED" || fail "the self-answered wait never closed"
bash "$WF" episode "$(rkey resolve-a)" 2>/dev/null | grep -q '"resolved":true' || fail "the closed wait does not say its state changed"
[ "$(owner_rows resolve-a)" = 0 ] || fail "a wait whose state changed still woke its owner"
pass "auto-resolve: a wait whose lane answered itself closes without a wake"

# 4. The owner install path: the units run the detached run's argv, a foreign owner is refused,
# and no real service manager is touched.
cleanup
UNITS=$TMP/units
STUB=$TMP/systemctl
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/calls"\n' "$TMP" >"$STUB"
chmod +x "$STUB"
mkdir -p "$UNITS/foreign"
printf '[Service]\nEnvironment="JG_HOME=%s"\n' "$TMP/other-home" >"$UNITS/foreign/jg-workflow-worker.service"
mkdir -p "$TMP/other-home"
if out=$(JG_WORKFLOW_UNIT_DIR=$UNITS/foreign JG_WORKFLOW_SYSTEMCTL=$STUB bash "$WF" install 2>&1); then
  fail "install ran over another home's units: $out"
fi
printf '%s\n' "$out" | grep -q "belong to $TMP/other-home" || fail "the refusal does not name the owning home: $out"
[ ! -e "$UNITS/foreign/jg-workflow-scheduler.service" ] || fail "a refused install still wrote a unit"
[ ! -e "$TMP/calls" ] || fail "a refused install still called the service manager"
out=$(JG_WORKFLOW_UNIT_DIR=$UNITS/mine JG_WORKFLOW_SYSTEMCTL=$STUB bash "$WF" install 2>&1) || fail "owner install failed: $out"
for part in scheduler sidecar worker; do
  [ -f "$UNITS/mine/jg-workflow-$part.service" ] || fail "install wrote no $part unit"
  want=$(bash "$WF" argv "$part" | tr '\n' ' ')
  got=$(sed -n 's/^ExecStart= *//p' "$UNITS/mine/jg-workflow-$part.service" | tr -d '\n')
  [ "$(printf '%s' "$want" | tr -s ' ' | sed 's/ $//')" = "$(printf '%s' "$got" | tr -s ' ' | sed 's/ $//')" ] \
    || fail "the $part unit does not run the detached argv: want [$want] got [$got]"
done
grep -q 'daemon-reload' "$TMP/calls" || fail "install did not reload the service manager"
[ "$(grep -c -- 'enable --now' "$TMP/calls")" = 3 ] || fail "install did not enable all three units: $(cat "$TMP/calls")"
grep -q '^Environment="DAPR_GRPC_PORT=' "$UNITS/mine/jg-workflow-worker.service" || fail "the worker unit carries no sidecar port"
pass "install writes the detached argv as units, refuses another home's units, and calls only the stub"

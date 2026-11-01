#!/usr/bin/env bash
# done-done journey: the escalation optimisation as the live rung the watcher runs.
# It drives the real core/escalation-optimize/bin/jg-escalation-optimize.sh decisions,
# the real bin/jg-escalation-workflows.sh tick and the real wake queue in a disposable
# home, and writes one transcript plus the step record into the evidence folder.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
H=$T/home
STATE=$H/state
mkdir -p "$H/config" "$STATE/.waiting-timers" "$H/data" "$T/tmp" "$T/root"
LOG=$OUT/escalation-rules-live.txt
: >"$LOG"
export JG_HOME=$H JG_STATE_OVERRIDE=$STATE JG_CONFIG_OVERRIDE=$H/config TMPDIR=$T/tmp
# The drain refuses to be quiet beside a checkout on a feature branch; point that
# tangle check at a directory that is not a git worktree, as the wake suites do.
export JG_ROOT_OVERRIDE=$T/root
OPT=$REPO/core/escalation-optimize/bin/jg-escalation-optimize.sh
FLOW=$REPO/bin/jg-escalation-workflows.sh
now=$(date +%s)
fails=0
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
step() { printf '\n== %s\n' "$*" | tee -a "$LOG"; }
expect() {  # <label> <want> <got>
  if [ "$2" = "$3" ]; then say "ok - $1"; else say "FAIL $1: want [$2] got [$3]"; fails=1; fi
}
contains() {  # <label> <text> <needle>
  case "$2" in
    *"$3"*) say "ok - $1" ;;
    *) say "FAIL $1: [$2] does not carry [$3]"; fails=1 ;;
  esac
}
decide() { bash "$OPT" decide "$@" 2>&1; }
classify() { bash "$OPT" classify "$@" 2>&1; }

step "priority classes come from the definition"
expect "a board key is batched into a digest" digest "$(classify check board-1 'plain payload')"
expect "a security payload is urgent" urgent "$(classify check anything 'a *security* event')"
expect "an unmatched event stays now" now "$(classify check plain 'plain payload')"

step "every escalation carries its evidence and the one action wanted, or is refused"
expect "no envelope is refused" "refuse missing-evidence" "$(decide check lane-key 'no envelope here' lane "$now")"
expect "an envelope delivers" "deliver now" \
  "$(decide check lane-key 'evidence=[the lane is blocked] action=[recheck the lane]' lane "$now")"

step "back-off holds the repeat and a changed payload resets it"
expect "the same payload is deferred" "defer backoff" \
  "$(decide check lane-key 'evidence=[the lane is blocked] action=[recheck the lane]' lane "$((now + 5))")"
expect "a changed payload delivers again" "deliver now" \
  "$(decide check lane-key 'evidence=[the lane is blocked again] action=[recheck the lane]' lane "$((now + 10))")"

step "one batched wake per group, with a one-line digest"
for i in 1 2 3; do
  expect "batch event $i joins its group" "defer digest" \
    "$(decide check "board-$i" "evidence=[queued $i] action=[review the batch]" "" "$((now + 20))")"
done
digest=$(bash "$OPT" flush --force "$((now + 400))" 2>&1)
contains "the flush is one digest line naming its rows" "$digest" "3 events: 3x board"
say "$digest"

step "a hop that cannot act is never woken"
printf 'held\n' >"$STATE/lane.captain-hold"
expect "a captain hold stops the climb" "drop not-actionable:captain-hold" \
  "$(decide check lane-key 'evidence=[the lane is blocked] action=[recheck the lane]' lane "$((now + 30))")"
rm -f -- "$STATE/lane.captain-hold"

step "a per-target wake budget, and urgent events ignore it"
for i in 1 2 3 4; do
  expect "captain wake $i is inside the budget" "deliver now" \
    "$(decide check "captain-item-$i" "evidence=[item $i] action=[decide item $i]" "" "$((now + 40))")"
done
expect "the fifth captain wake is held by the budget" "defer over-budget:captain" \
  "$(decide check captain-item-5 'evidence=[item 5] action=[decide item 5]' '' "$((now + 41))")"
expect "an urgent event wakes even over budget" "deliver urgent" \
  "$(decide check captain-breach 'a *security* breach evidence=[breach] action=[stop the line]' '' "$((now + 42))")"

step "an escalation closes when the state it was raised about changes"
printf 'working: building\n' >"$STATE/lane.status"
resolved=$(bash "$OPT" resolve "$((now + 50))" 2>&1)
contains "the open escalation closes on a status change" "$resolved" "resolved check lane-key (state changed)"

step "the live rung the watcher runs delivers an owner wake into the real queue"
printf 'kind=ship\nbackend=tmux\nwindow=fake:1\n' >"$STATE/lane.meta"
printf 'working: building\nblocked [at=%s] [key=wait]: external condition until 2099-01-01T00:00Z\n' \
  "$((now - 600))" >"$STATE/lane.status"
printf '1\t%s\t0\t0\twaiting-timer-0000aaaa-lane-g1-cur-wait\t0\t0\t0\n' "$((now - 600))" \
  >"$STATE/.waiting-timers/lane"
tick=$(bash "$FLOW" tick 2>&1)
contains "the tick names the lane and the level it climbs to" "$tick" "level=owner"
contains "the tick carries the evidence" "$tick" "evidence=[lane declared blocked key=wait"
contains "the tick carries the one action wanted" "$tick" "action=[recheck lane"
queued=$(bash "$REPO/bin/jg-wake-drain.sh" 2>&1)
contains "the wake is in the durable queue under its own key" "$queued" "waiting-timer-0000aaaa-lane-g1-cur-wait-owner"
say "$tick"

cat >"$OUT/steps.json" <<JSON
{"target":{"version":"$(git -C "$REPO" rev-parse --short HEAD)"},
 "start":"a disposable home whose lane declares a blocked wait, and the escalation rules this feature ships",
 "steps":["classify three events and read the priority class of each","decide an escalation without an envelope and one with it","decide the same payload twice and a changed payload once","queue three batch events and flush them","place a captain hold and decide again","fill the captain budget and then send an urgent event","change the state the escalation was raised about and resolve it","run the live tick the watcher calls and drain the queue"],
 "result":"the rules decide as configured and the live rung delivered one owner wake carrying its evidence and action: $(printf '%s' "$tick" | cut -c1-120)"}
JSON
if [ "$fails" -eq 0 ]; then say "PASS: escalation rules as the live rung"; exit 0; fi
exit 1

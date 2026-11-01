#!/usr/bin/env bash
# Each of the six escalation rules, firing and staying quiet, against the
# definition's own numbers (nothing starts a service; state is a temp dir).
set -u
# shellcheck source=tests/lib.sh source-path=SCRIPTDIR/../../..
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/lib.sh"

OPTSH="$ROOT/core/escalation-optimize/bin/jg-escalation-optimize.sh"
BASE=$(jg_test_tmproot jg-escalation-optimize)
T=1000000
OK='evidence=[x] action=[y]'
n=0

new_case() {  # <name>
  n=$((n + 1))
  CASE="$BASE/$n-$1"
  mkdir -p "$CASE/state" "$CASE/config"
  printf 'batch check merged-* *\nnow * * *\n' >"$CASE/wake-routing"
}
opt() {
  JG_HOME="$CASE" JG_STATE_OVERRIDE="$CASE/state" JG_CONFIG_OVERRIDE="$CASE/config" \
    JG_WAKE_ROUTING="$CASE/wake-routing" "$OPTSH" "$@"
}
decide() { opt decide "$@"; }   # <kind> <key> <payload> [task] [now]

# 1. priority classes beyond now/batch/silent
new_case priority
[ "$(opt classify check x 'a security finding')" = urgent ] || fail 'a security payload is not urgent'
[ "$(opt classify check slo-main-1 'x')" = soon ] || fail 'an slo key is not soon'
[ "$(opt classify check board-ask 'x')" = digest ] || fail 'a board key is not digest'
[ "$(opt classify check plain 'x')" = now ] || fail 'an unmatched event does not fall back to now'
pass 'priority classes: urgent, soon and digest fire; an unmatched event stays now'

# 1. per-target budget
new_case budget
limit=$(jq -r '.spec.budget.targets.main' "$ROOT/core/bus/workflows/escalation-optimization.json")
i=0
while [ "$i" -lt "$limit" ]; do
  [ "$(decide check "k$i" "p $OK" '' "$((T + i))")" = 'deliver now' ] || fail "wake $i inside the budget did not deliver"
  i=$((i + 1))
done
v=$(decide check over "p $OK" '' "$((T + limit))")
[ "$v" = 'defer over-budget:main' ] || fail "wake past the budget was not held: $v"
[ "$(decide check urg "a security thing $OK" '' "$((T + limit))")" = 'deliver urgent' ] || fail 'urgent did not bypass the budget'
[ "$(decide check later "p $OK" '' "$((T + 3700))")" = 'deliver now' ] || fail 'the budget did not reopen after the window'
[ "$(decide check lead-1 "p $OK" '' "$((T + limit))")" = 'deliver now' ] || fail "another target's budget was spent"
pass 'budget: holds past the hourly limit per target, urgent bypasses, window reopens'

# 2. backoff with a cap, reset only on payload change
new_case backoff
base=$(jq -r .spec.backoff.baseSeconds "$ROOT/core/bus/workflows/escalation-optimization.json")
cap=$(jq -r .spec.backoff.capSeconds "$ROOT/core/bus/workflows/escalation-optimization.json")
now=$T
[ "$(decide check stuck "same $OK" '' "$now")" = 'deliver now' ] || fail 'first sighting did not deliver'
[ "$(decide check stuck "same $OK" '' "$((now + base - 1))")" = 'defer backoff' ] || fail 'repeat inside the base interval woke'
now=$((now + base))
[ "$(decide check stuck "same $OK" '' "$now")" = 'deliver now' ] || fail 'repeat at the base interval did not deliver'
[ "$(decide check stuck "same $OK" '' "$((now + base))")" = 'defer backoff' ] || fail 'second interval did not double'
now=$((now + base * 2))
[ "$(decide check stuck "same $OK" '' "$now")" = 'deliver now' ] || fail 'repeat at the doubled interval did not deliver'
k=0
while [ "$k" -lt 12 ]; do
  now=$((now + cap))
  [ "$(decide check stuck "same $OK" '' "$now")" = 'deliver now' ] || fail "repeat $k at the cap did not deliver"
  k=$((k + 1))
done
[ "$(decide check stuck "same $OK" '' "$((now + cap - 1))")" = 'defer backoff' ] || fail 'the interval grew past the cap'
[ "$(decide check stuck "changed $OK" '' "$((now + 1))")" = 'deliver now' ] || fail 'a changed payload did not reset the back-off'
[ "$(decide check stuck "changed $OK" '' "$((now + 2))")" = 'defer backoff' ] || fail 'the reset did not restart at the base interval'
[ "$(decide check stuck "changed $OK" '' "$((now + 1 + base))")" = 'deliver now' ] || fail 'the reset interval is not the base'
pass 'backoff: doubles, stops at the cap, resets only when the payload changes'

# 3. coalesce by key
new_case coalesce
for i in 1 2 3; do
  [ "$(decide check "merged-$i" "pr$i $OK" '' "$((T + i))")" = 'defer batch' ] || fail "merged-$i was not held for the batch"
done
[ "$(decide check slo-late "late $OK" '' "$((T + 5))")" = 'deliver soon' ] || fail 'a soon event was held'
[ -z "$(opt flush "$((T + 10))")" ] || fail 'a group flushed before its window'
out=$(opt flush "$((T + 400))")
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "flush did not emit exactly one wake: $out"
case "$out" in *'3 events: 3x merged'*) ;; *) fail "digest line does not name 3 events: $out" ;; esac
case "$out" in *'evidence=['*'action=['*) ;; *) fail "digest carries no evidence or action: $out" ;; esac
[ -z "$(opt flush "$((T + 800))")" ] || fail 'a flushed group woke again'
pass 'coalesce: three events become one wake with a one-line digest, quiet before the window'

# 3. coalesce by count: maxEvents rows flush before the window ends
new_case coalesce-count
max=$(jq -r .spec.coalesce.maxEvents "$ROOT/core/bus/workflows/escalation-optimization.json")
i=1
while [ "$i" -lt "$max" ]; do decide check "merged-$i" "pr$i $OK" '' "$((T + i))" >/dev/null; i=$((i + 1)); done
[ -z "$(opt flush "$((T + 20))")" ] || fail 'a group flushed one row short of maxEvents'
decide check "merged-$max" "pr$max $OK" '' "$((T + 21))" >/dev/null
out=$(opt flush "$((T + 22))")
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "maxEvents did not flush exactly one digest: $out"
case "$out" in *"$max events: ${max}x merged"*) ;; *) fail "count digest does not name $max events: $out" ;; esac
pass 'coalesce: maxEvents rows flush one digest before the window ends'

# 4. actionability
new_case actionability
printf 'x\n' >"$CASE/state/t1.captain-hold"
printf 'x\n' >"$CASE/state/t2.declared-wait"
printf 'x\n' >"$CASE/state/t3.external-wait"
printf 'v1\n' >"$CASE/config/parked-homes"
for pair in 't1:captain-hold' 't2:declared-wait' 't3:external-wait'; do
  v=$(decide check "up-${pair%%:*}" "p $OK" "${pair%%:*}" "$T")
  [ "$v" = "drop not-actionable:${pair##*:}" ] || fail "${pair%%:*} climbed: $v"
done
v=$(decide check up-park "p $OK" v1 "$T")
[ "$v" = 'drop not-actionable:paused-home' ] || fail "a parked home climbed: $v"
[ "$(decide check up-free "p $OK" free "$T")" = 'deliver now' ] || fail 'a lane that can act was stopped'
rm -f "$CASE/state/t1.captain-hold"
[ "$(decide check up-t1 "p $OK" t1 "$T")" = 'deliver now' ] || fail 'a cleared hold still blocked the climb'
pass 'actionability: hold, declared wait, external wait and parked home never climb; a free lane does'

# 5. auto-resolve
new_case resolve
printf 'blocked [at=1]: a\n' >"$CASE/state/w.status"
[ "$(decide check w-key "p $OK" w "$T")" = 'deliver now' ] || fail 'no escalation opened'
[ -z "$(opt resolve "$T")" ] || fail 'an unchanged state resolved the escalation'
printf 'working [at=2]: b\n' >>"$CASE/state/w.status"
out=$(opt resolve "$((T + 1))")
case "$out" in 'resolved check w-key'*) ;; *) fail "a changed state did not resolve: $out" ;; esac
[ -z "$(opt resolve "$((T + 2))")" ] || fail 'a resolved escalation resolved twice'
[ "$(decide check w-key "p $OK" w "$((T + 3))")" = 'deliver now' ] || fail 'a resolved condition did not restart the back-off'
pass 'auto-resolve: closes once when the state changes, quiet while it holds, back-off restarts'

# 6. evidence and the one action
new_case envelope
[ "$(decide check e 'only text' '' "$T")" = 'refuse missing-evidence' ] || fail 'no evidence was accepted'
[ "$(decide check e 'evidence=[a]' '' "$T")" = 'refuse missing-action' ] || fail 'no action was accepted'
[ "$(decide check e 'evidence=[a] action=[b]' '' "$T")" = 'deliver now' ] || fail 'a full envelope was refused'
[ "$(opt wrap 'log line' 'restart it')" = 'evidence=[log line] action=[restart it]' ] || fail 'wrap shape changed'
pass 'envelope: missing evidence or action is refused; wrap builds the pair'

# the replay reports its three numbers on a known stream
new_case replay
: >"$CASE/rows"
i=0
while [ "$i" -lt 20 ]; do
  printf '%s\t%s\tcheck\tstuck\tsame\n' "$((T + i * 60))" "$i" >>"$CASE/rows"
  i=$((i + 1))
done
out=$(opt replay "$CASE/rows" 1000)
case "$out" in *'wakes_before=20'*'wakes_avoided='*'tokens_saved='*'mean_added_wait_seconds='*) ;; *) fail "replay output incomplete: $out" ;; esac
avoided=$(printf '%s' "$out" | sed -n 's/.*wakes_avoided=\([0-9]*\).*/\1/p')
[ "$avoided" -gt 0 ] || fail "an unchanged repeating condition avoided no wakes: $out"
pass 'replay: reports wakes avoided, tokens saved and added wait'

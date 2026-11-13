#!/usr/bin/env bash
# Integration journey for a stop, through the delivery pass without a watcher.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
D=$(jg_test_tmproot jg-stops)
trap jg_test_cleanup EXIT
H=$D/home
mkdir -p "$H/state/.stops" "$H/config" "$H/data"
printf 'fixture stop\n' > "$H/state/.stops/host.fixture"
JG_TEST_SEAM=0 bash "$ROOT/bin/jg-delivery-tick.sh" "$H"
[ ! -e "$H/state/.waiting-timers/.stops" ] || fail 'empty production table acted on a stop'
export JG_STOPS_TEST_ROW=$'fixture\tscript\tnotify\tlead\t10\t20\tdetector removes record'
tick() { JG_STOPS_TEST_NOW=$1 bash "$ROOT/bin/jg-delivery-tick.sh" "$H"; }
tick 100
[ ! -e "$H/state/.wake-bus.outbox.jsonl" ] || fail 'step ran before timer'
tick 110
grep -q waiting-timer-step "$H/state/.wake-bus.outbox.jsonl" || fail 'step did not run at timer'
[ "$(wc -l < "$H/state/.wake-bus.outbox.jsonl")" -eq 1 ] || fail 'first raise missing'
tick 129
[ "$(wc -l < "$H/state/.wake-bus.outbox.jsonl")" -eq 1 ] || fail 'repeat ran early'
tick 130
[ "$(wc -l < "$H/state/.wake-bus.outbox.jsonl")" -eq 2 ] || fail 'repeat did not raise'
[ "$(grep -c waiting-timer-step "$H/state/.wake-bus.outbox.jsonl")" -eq 1 ] || fail 'step ran twice'
rm "$H/state/.stops/host.fixture"
tick 140
tick 141
[ "$(wc -l < "$H/data/metrics/escalations.tsv")" -eq 2 ] || fail 'clear did not write exactly one ledger row'
[ "$(awk -F '\t' 'NR == 2 {print $6}' "$H/data/metrics/escalations.tsv")" = owner ] || fail 'clear ledger reports the wrong escalation level'
pass 'delivery tick runs and clears a stop without a watcher'

# A killed stop process cannot prevent a real fixture lane from landing.
# shellcheck source=tests/jg-trunk-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"
world killed-stop
cp -r "$W/root/bin" "$HOME_D/bin"
ln -s "$ROOT/core" "$HOME_D/core"
ln -s "$ROOT/policy" "$HOME_D/policy"
lane survivor one
head=$(git -C "$PROJ" rev-parse fm/survivor)
mkdir -p "$HOME_D/state/.stops"
printf 'fixture stop\n' > "$HOME_D/state/.stops/host.fixture"
JG_STOPS_TEST_ROW=$'fixture\tscript\ttest-terminate\tlead\t0\t20\tdetector removes record' \
  JG_STOPS_TEST_NOW=200 PATH="$W/fakebin:$PATH" JG_ROOT_OVERRIDE="$W/root" \
  bash "$ROOT/bin/jg-delivery-tick.sh" "$HOME_D" > "$W/tick.log" 2>&1 || fail 'stop failure changed the delivery exit'
for _ in $(seq 1 300); do
  grep -q '^landed' "$HOME_D/data/jg-trunk-landing/survivor.$head.state" 2>/dev/null && break
  sleep 0.1
done
grep -q '^landed' "$HOME_D/data/jg-trunk-landing/survivor.$head.state" || fail "landing did not complete: $(cat "$W/tick.log")"
grep -q 'stop processing failed' "$W/tick.log" || fail 'stop process death was not reported'
pass 'landing survives a killed stop process'

# Verification journey: journeys/required-checks.sh
D=$(jg_test_tmproot jg-check-not-wired)
trap jg_test_cleanup EXIT
H=$D/home
mkdir -p "$H/state" "$H/config" "$H/data" "$H/bin" "$D/share"
printf 'lead\n' > "$H/.jg-squad-lead-home"
cp -a "$ROOT/bin/." "$H/bin/"
mkdir -p "$H/core"
cp -a "$ROOT/core/trunk-latency" "$ROOT/core/machines" "$H/core/"
JG_HOME=$H JG_ROOT_OVERRIDE=$ROOT XDG_DATA_HOME=$D/share bash "$ROOT/bin/jg-session-start.sh" --reemit > "$D/digest" 2>&1 || true
grep -q 'required check missing: trunk-latency' "$D/digest" || fail 'session digest did not name the missing check'
[ ! -e "$H/state/trunk-latency.check.sh" ] || fail 'read-only digest wrote the check'
XDG_DATA_HOME=$D/share bash "$ROOT/bin/jg-delivery-tick.sh" "$H" > "$D/out" 2>&1
grep -q 'missing.*trunk-latency' "$D/out" || fail 'missing check was not named'
[ -f "$H/state/trunk-latency.check.sh" ] || fail 'check was not wired'
# The missing check raises the supervision-down alert through the alert function: one record, one wake that names it, and no wake of the old shape.
[ "$(JG_STATE_OVERRIDE=$H/state JG_HOME=$H bash "$H/bin/jg-alert.sh" word supervision-down--required-checks)" = open ] || fail 'the supervision-down alert was not raised'
grep -q 'alert-supervision-down--required-checks' "$H/state/.wake-queue" || fail 'the alert wake was not queued'
! grep -q 'check	required-checks	' "$H/state/.wake-queue" || fail 'the old required-checks wake is still raised'
[ -f "$H/state/trunk-latency.check-trust" ] || fail 'check was not registered'
XDG_DATA_HOME=$D/share bash "$ROOT/bin/jg-delivery-tick.sh" "$H" > "$D/again" 2>&1
[ ! -s "$D/again" ] || fail 'wired check was reported again'
[ "$(JG_STATE_OVERRIDE=$H/state JG_HOME=$H bash "$H/bin/jg-alert.sh" word supervision-down--required-checks)" = resolved ] || fail 'the alert did not resolve when the check was wired'
pass 'supervision names and wires the missing check once'

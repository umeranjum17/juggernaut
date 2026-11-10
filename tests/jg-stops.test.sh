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

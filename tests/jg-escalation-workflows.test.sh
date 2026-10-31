#!/usr/bin/env bash
# The escalation ladders and wait timers as a workflow definition, in shadow
# (docs/escalation-workflows.md). A replayed event set must produce the same rung
# rows on the authoritative ladder and on the definition's engine, and a
# deliberately shifted event on the new path must make the same check fail, so a
# green parity run is never vacuous. The shadow tick must also record the rungs it
# predicts without touching the authoritative episode.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOWS="$ROOT/bin/jg-escalation-workflows.sh"
HOME_DIR=$(jg_test_tmproot jg-escalation-workflows)
STATE_DIR="$HOME_DIR/state"
OUT="$HOME_DIR/out"
mkdir -p "$STATE_DIR/.wait-sources" "$HOME_DIR/config"
now=$(date +%s)

# Two recorded lanes: a keyed blocked decision that resolves after the card rung,
# and a declared pause that must ride the pause cadence and never escalate.
t0=$((now - 20000))
printf 'kind=ship\nbackend=tmux\nwindow=fake:1\n' >"$STATE_DIR/lane.meta"
printf 'working [at=%s]: building\nblocked [at=%s] [key=wait]: external condition\nresolved [at=%s] [key=wait]: cleared\n' \
  "$((t0 - 60))" "$t0" "$((t0 + 1500))" >"$STATE_DIR/lane.status"
printf 'kind=ship\nbackend=tmux\nwindow=fake:2\n' >"$STATE_DIR/paused-lane.meta"
printf 'working [at=%s]: building\npaused [at=%s]: waiting on the pipeline run\n' \
  "$((t0 - 60))" "$t0" >"$STATE_DIR/paused-lane.status"

# The definition is read from this checkout; nothing here starts a service.
run() {
  JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE_DIR" JG_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$WORKFLOWS" "$@" >"$OUT" 2>&1
}

run show || fail "show failed: $(cat "$OUT")"
grep -q 'ladder wait:' "$OUT" || fail "show does not print the wait ladder: $(cat "$OUT")"
grep -qE 'owner +\+120s' "$OUT" || fail "show does not print the owner rung at its timer: $(cat "$OUT")"
grep -qE 're-alert +every 14400s' "$OUT" || fail "show does not print the pause ladder's own cadence: $(cat "$OUT")"
pass "show prints the definition in force"

run parity --home "$HOME_DIR" --days 7 || fail "parity is not green: $(cat "$OUT")"
grep -qE 'differences=0' "$OUT" || fail "parity did not report zero differences: $(cat "$OUT")"
events=$(sed -n 's/.*events=\([0-9]*\).*/\1/p' "$OUT")
rungs=$(sed -n 's/.*rungs=\([0-9]*\).*/\1/p' "$OUT")
[ "${events:-0}" -ge 5 ] || fail "parity compared too few recorded events: ${events:-0} ($(cat "$OUT"))"
[ "${rungs:-0}" -ge 5 ] || fail "parity compared too few rungs: ${rungs:-0} ($(cat "$OUT"))"
pass "parity is green over $events recorded events and $rungs rungs"

# The same replay with one event shifted on the new path must not be green: a
# check that stayed green here would be proving nothing.
run parity --home "$HOME_DIR" --days 7 --corrupt || fail "the corrupted replay did not run: $(cat "$OUT")"
grep -qE 'differences=[1-9]' "$OUT" || fail "a corrupted event on the new path still produced no difference: $(cat "$OUT")"
pass "a corrupted event on the new path fails the same check"

# The live shadow: an open authoritative episode gets the rungs the definition
# predicts, and the authoritative record itself is left alone.
printf 'kind=ship\nbackend=tmux\nwindow=fake:1\n' >"$STATE_DIR/lane.meta"
printf 'blocked [at=%s] [key=wait]: external condition\n' "$t0" >"$STATE_DIR/lane.status"
mkdir -p "$STATE_DIR/.waiting-timers"
printf 'sig-keep\t%s\t%s\t0\twaiting-timer-fixture-lane-g%s-wait\t0\t0\t0\n' \
  "$t0" "$((t0 + 120))" "$t0" >"$STATE_DIR/.waiting-timers/lane"
cp "$STATE_DIR/.waiting-timers/lane" "$HOME_DIR/record.before"
: >"$HOME_DIR/config/escalation-workflows"
run tick || fail "tick failed: $(cat "$OUT")"
[ -s "$STATE_DIR/escalation-workflows.jsonl" ] || fail "tick recorded no shadow rung: $(cat "$OUT")"
grep -q '"rung":"escalate"' "$STATE_DIR/escalation-workflows.jsonl" \
  || fail "tick did not record the escalation rung the definition predicts: $(cat "$STATE_DIR/escalation-workflows.jsonl")"
grep -q '"recorded":0' "$STATE_DIR/escalation-workflows.jsonl" \
  || fail "tick did not record that the escalation rung has not fired yet"
cmp -s "$STATE_DIR/.waiting-timers/lane" "$HOME_DIR/record.before" \
  || fail "tick wrote into the authoritative episode record"
pass "tick records the predicted rungs and leaves the authoritative record alone"

# Off by default: no config switch, no shadow record.
: >"$STATE_DIR/escalation-workflows.jsonl"
rm -f "$HOME_DIR/config/escalation-workflows"
run tick || fail "tick failed while off: $(cat "$OUT")"
[ ! -s "$STATE_DIR/escalation-workflows.jsonl" ] || fail "tick recorded without config/escalation-workflows"
pass "tick does nothing until the home turns it on"

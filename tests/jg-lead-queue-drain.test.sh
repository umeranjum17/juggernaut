#!/usr/bin/env bash
# Real alert, queue, watcher resurface and drain in an isolated lead home.
set -eu
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || exec > >(tee "$DONE_DONE_EVIDENCE_ROOT/lead-queue-drain.log") 2>&1
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck disable=SC2034 # Used by make_case from wake-helpers.sh.
TMP_ROOT=$(jg_test_tmproot jg-lead-queue-drain)
d=$(make_case lead)
mkdir -p "$d/config" "$d/data" "$d/home" "$d/tmp" "$d/standin"
export JG_HOME="$d" JG_STATE_OVERRIDE="$d/state" JG_CONFIG_OVERRIDE="$d/config" JG_DATA_OVERRIDE="$d/data"
export HOME="$d/home" TMPDIR="$d/tmp" JG_LEAD_DAEMON=1 JG_INJECT_SKIP=1
export PATH="$d/fakebin:$PATH"
"$ROOT/bin/jg-alert.sh" raise line-red example --note 'example refusal' --deliver >/dev/null
# Source the real watcher and override only its terminal delivery operation.
reason=$(bash -c '
  . "$1/bin/jg-watch.sh"
  wake() { printf "%s\n" "$1"; }
  squad_lead_in_active_turn() { return 1; }
  own_queue_resurface
' _ "$ROOT")
case "$reason" in 'check: alert-line-red--'*) ;; *) fail "alert redelivery: $reason" ;; esac
bash -c '. "$1/bin/jg-supervise-daemon.sh"; is_wake_reason "$2"' _ "$ROOT" "$reason" || fail 'daemon rejected alert wake'
# A successful real drain routes and acknowledges the same row.
bash -c '. "$1/bin/jg-supervise-daemon.sh"; LOG="$2/log"; handle_durable_wakes "$3" "$2/state"' _ "$ROOT" "$d" "$reason" || fail 'real drain failed'
[ -z "$("$ROOT/bin/jg-bus.sh" watcher oldest)" ] || fail 'alert row was not acknowledged'
append_wake "$d/state" check alert-line-red--sample 'check: sample already prefixed'
reason=$(bash -c '
  . "$1/bin/jg-watch.sh"
  wake() { printf "%s\n" "$1"; }
  squad_lead_in_active_turn() { return 1; }
  own_queue_resurface
' _ "$ROOT")
[ "$reason" = 'check: sample already prefixed' ] || fail "prefixed reason changed: $reason"
cat > "$d/standin/jg-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
printf '\nrefused: a test reason\n' >&2
exit 1
SH
chmod +x "$d/standin/jg-wake-drain.sh"
# Exercise the same handler and failure logger the daemon loop uses.
bash -c '
  . "$1/bin/jg-supervise-daemon.sh"
  LOG="$2/log"; JG_DAEMON_DIR="$2/standin"
  for i in 1 2 3 4; do
    if ! handle_durable_wakes "check: sample" "$2/state"; then wake_ack_failed "$2/state"; fi
  done
' _ "$ROOT" "$d" 2>/dev/null
grep -q 'durable wake handling was not acknowledged: refused: a test reason; restarting for recovery' "$d/log" || fail 'refusal missing from log'
alert="$d/state/alerts/supervision-down--wake-ack-failing.rec"
if ! [ -f "$alert" ] || ! grep -qx 'state=open' "$alert" || ! grep -q 'note=wake acknowledgements failing: refused: a test reason' "$alert"; then
  fail 'failure alert missing'
fi
[ "$(find "$d/state/alerts" -name 'supervision-down--wake-ack-failing.rec' | wc -l)" -eq 1 ] || fail 'duplicate alert'
bash -c '. "$1/bin/jg-supervise-daemon.sh"; LOG="$2/log"; handle_durable_wakes "check: sample" "$2/state"' _ "$ROOT" "$d" || fail 'recovery drain failed'
grep -qx 'state=resolved' "$alert" || fail 'alert did not resolve'
[ ! -s "$d/state/.wake-ack-failures" ] || fail 'failure count did not clear'
# A failure outside the ten-minute window cannot contribute to the threshold.
printf '%s\n' "$(($(date +%s) - 700))" > "$d/state/.wake-ack-failures"
bash -c '. "$1/bin/jg-supervise-daemon.sh"; JG_WAKE_ACK_ERROR=old; wake_ack_result failure "$2/state"' _ "$ROOT" "$d"
[ "$(wc -l < "$d/state/.wake-ack-failures")" -eq 1 ] || fail 'old failure retained'
grep -qx 'state=resolved' "$alert" || fail 'old failure reopened alert'
printf 'ok - lead queue redelivery, acknowledgement and failure recovery\n'

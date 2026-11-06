#!/usr/bin/env bash
# tests/jg-sentinel-wake-deferred-alert.test.sh - a wake the primary keeps not taking raises one captain alert.
#
# Real Herdr lab session with no pane that runs the locked primary session, so every wake defers.
# The sentinel's tick must stay quiet at first, send exactly one alert once the deferral has lasted
# JG_SENTINEL_DEFER_ALERT_SECS, send no second one while the episode lasts, end the episode when
# the beacon is healthy, and alert again for a new episode. Every Herdr call uses a lab session
# that is never the default; the alert command is a stand-in that appends to a log.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="jg-lab-defer-alert-$$"
export HERDR_SESSION="$SESSION"
LAB=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/jg-defer-alert.XXXXXX") || exit 1
[ -d "$LAB" ] || exit 1
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
cleanup() {
  local s=$?
  herdr_safe_stop_and_delete "$SESSION" 2>/dev/null || true
  [ -z "${KEEP:-}" ] && rm -rf -- "$LAB"
  exit "$s"
}
trap cleanup EXIT
herdr_prepare_runtime "$SESSION" || fail "could not prepare the isolated Herdr lab session"

# shellcheck source=bin/jg-backend.sh
. "$ROOT/bin/jg-backend.sh"
jg_backend_source herdr || fail "cannot load the Herdr adapter"
jg_backend_herdr_container_ensure /tmp >/dev/null || fail "cannot start the lab Herdr server"

JG_HOME=$("$ROOT/bin/jg-lab-home.sh" create "$LAB/home") || fail "cannot create the lab home"
STATE=$JG_HOME/state
ALERTS=$LAB/alerts.log
: >"$ALERTS"
cat >"$LAB/say.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$ALERTS"
SH
chmod +x "$LAB/say.sh"
printf '%s\n' no-such-session >"$STATE/.lock-session"

tick() {
  JG_HOME=$JG_HOME JG_SENTINEL_HERDR_SESSION=$SESSION JG_SENTINEL_DEFER_ALERT_SECS=3 JG_SENTINEL_TMP_SWEEP_SECS=0 JG_TMP_WARN_PCT=101 \
    JG_SENTINEL_CAPTAIN_SAY="$LAB/say.sh" "$ROOT/bin/jg-sentinel.sh" tick >>"$LAB/tick.out" 2>&1
}
alerts() { grep -c . "$ALERTS" 2>/dev/null || true; }
pend() { printf '%s\n' "a wake is pending" >"$STATE/.sentinel-wake-pending"; }

# The first tick makes the herdr identity record; the next ones hit the pending wake.
tick
pend
tick
[ -s "$STATE/.sentinel-wake-deferred" ] || fail "the wake did not defer, so the episode never opened: $(cat "$LAB/tick.out")"
[ "$(alerts)" = 0 ] || fail "alerted on the first deferral"
pass "the first deferral opens an episode and alerts nothing"

sleep 4
tick
[ "$(alerts)" = 1 ] || fail "expected one alert after the deferral lasted, got $(alerts): $(tail -4 "$LAB/tick.out")"
grep -q 'not taking a waiting message' "$ALERTS" || fail "alert text is not the deferred-wake alert: $(cat "$ALERTS")"
pass "a deferral that lasts raises one alert"

tick; tick
[ "$(alerts)" = 1 ] || fail "alerted again inside one episode: $(alerts)"
pass "the same episode does not alert again"

# A healthy beacon with no pending wake ends the episode.
rm -f "$STATE/.sentinel-wake-pending"
touch "$STATE/.last-watcher-beat"
tick
[ ! -e "$STATE/.sentinel-wake-deferred" ] || fail "a healthy beacon left the episode open"
pend
tick
sleep 4
tick
[ "$(alerts)" = 2 ] || fail "a new episode must alert once more, got $(alerts)"
pass "a new episode after recovery alerts once more"

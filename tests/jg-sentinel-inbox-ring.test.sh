#!/usr/bin/env bash
# tests/jg-sentinel-inbox-ring.test.sh - real-Herdr journey, token-free, for the captain-note ring.
#
# A stand-in primary (a bash loop that registers as a Herdr agent with a session id, as
# tests/jg-afk-inject-herdr-e2e.test.sh does) sits idle in a named lab session. The home has no
# lane in flight and no watcher beacon, which is Main after a server restart. A note filed with
# bin/jg-inbox.sh must reach the primary as a typed doorbell within seconds: no tick, no 300 s
# beacon grace. A live watcher beacon must keep the ring away, and a repeat ring for the same
# queued note must wait out the rewake window.
# Every Herdr call goes through a lab session that is never the default.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="jg-lab-inbox-ring-$$"
export HERDR_SESSION="$SESSION"
LAB=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/jg-inbox-ring.XXXXXX") || exit 1
[ -d "$LAB" ] || exit 1
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
cleanup() {
  local s=$?
  herdr_safe_stop_and_delete "$SESSION" 2>/dev/null || true
  rm -rf -- "$LAB"
  exit "$s"
}
trap cleanup EXIT
herdr_prepare_runtime "$SESSION" || fail "could not prepare the isolated Herdr lab session"

# shellcheck source=bin/jg-backend.sh
. "$ROOT/bin/jg-backend.sh"
jg_backend_source herdr || fail "cannot load the Herdr adapter"

JG_HOME=$("$ROOT/bin/jg-lab-home.sh" create "$LAB/home") || fail "cannot create the lab home"
STATE=$JG_HOME/state
LOG=$LAB/submitted.log
: >"$LOG"
SID=lab-primary-session-1

CONTAINER_RAW=$(jg_backend_herdr_container_ensure /tmp) || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED=${CONTAINER_RAW#*$'\t'}
TASK_IDS=$(jg_backend_herdr_create_task "$CONTAINER" jg-ring-primary /tmp "$SEEDED") || fail "cannot create the primary pane"
read -r _TAB PANE <<<"$TASK_IDS"
[ -n "$PANE" ] || fail "no primary pane"

cat >"$LAB/primary.sh" <<'LOOP'
#!/usr/bin/env bash
LOG=$1 SID=$2
rep() { herdr pane report-agent "$HERDR_PANE_ID" --source herdr:claude --agent claude --state "$1" --session "$HERDR_SESSION" >/dev/null 2>&1; }
herdr pane report-agent-session --source herdr:claude --agent claude --seq "$(date +%s%N)" --agent-session-id "$SID" --session-start-source startup --session "$HERDR_SESSION" "$HERDR_PANE_ID" >/dev/null 2>&1
stty -echo -icanon min 1 time 0 2>/dev/null || true
rep idle
buf=
redraw() { printf '\r\033[K❯ %s' "$buf"; }
redraw
while IFS= read -r -n 1 c; do
  if [ -z "$c" ] || [ "$c" = $'\r' ]; then
    printf '%s\n' "$buf" >>"$LOG"; buf=; printf '\r\033[K\n'; redraw
    rep working; sleep 0.6; rep idle
  else buf="$buf$c"; redraw; fi
done
LOOP
chmod +x "$LAB/primary.sh"
jg_backend_herdr_send_text_line "$SESSION:$PANE" "exec -a claude bash '$LAB/primary.sh' '$LOG' '$SID'" || fail "cannot start the stand-in primary"
sleep 2
printf '%s\n' "$SID" >"$STATE/.lock-session"
rm -f "$STATE/.last-watcher-beat"

note() { JG_HOME="$JG_HOME" JG_SENTINEL_HERDR_SESSION="$SESSION" "$ROOT/bin/jg-inbox.sh" note --request-id "$1" "$2" >/dev/null 2>&1; }
rings() { grep -c . "$LOG" 2>/dev/null || true; }
wait_rings() {  # <count> <seconds>
  local i=0
  while [ "$i" -lt "$(( $2 * 5 ))" ]; do [ "$(rings)" -ge "$1" ] && return 0; sleep 0.2; i=$((i + 1)); done
  return 1
}

# 1. A live watcher beacon keeps the ring away; the note still queues its wake.
touch "$STATE/.last-watcher-beat"
note live-1 "captain note while a watcher is live" || fail "note was not filed"
sleep 6
[ "$(rings)" = 0 ] || fail "rang the primary although a watcher beacon was fresh"
pass "a fresh watcher beacon: the note is queued and the primary is not rung"

# 1b. A captain at the screen (no away record) is never typed at: no beacon, yet
# the doorbell stays out of his message box and the log says why.
rm -f "$STATE/.last-watcher-beat" "$STATE/.sentinel-inbox-woken"
note attended-1b "captain note while he is at the screen" || fail "attended note was not filed"
sleep 6
[ "$(rings)" = 0 ] || fail "typed a doorbell into an attended primary"
grep -q 'attended; wake left to the Stop hook' "$STATE/.sentinel.log" || fail "the attended skip was not logged"
pass "an attended primary is not typed at"

# 2. No beacon, no lane in flight, captain away: the note rings the primary in seconds.
printf 'away\n' >"$STATE/.afk"
rm -f "$STATE/.last-watcher-beat" "$STATE/.sentinel-inbox-woken"
t0=$(date +%s)
note ring-2 "captain note with no live cycle" || fail "second note was not filed"
wait_rings 1 20 || fail "no doorbell: $(tail -3 "$STATE/.sentinel.log" 2>/dev/null)"
secs=$(( $(date +%s) - t0 ))
grep -q 'operational input waiting' "$LOG" || fail "the typed text is not the note doorbell: $(cat "$LOG")"
[ "$secs" -le 30 ] || fail "the ring took $secs s"
pass "no live cycle: the note reached the primary as a doorbell in ${secs} s"

# 3. The same queued notes do not ring again inside the rewake window.
JG_HOME=$JG_HOME JG_SENTINEL_HERDR_SESSION=$SESSION "$ROOT/bin/jg-sentinel.sh" ring >/dev/null 2>&1
sleep 2
[ "$(rings)" = 1 ] || fail "a repeat ring for the same notes typed again: $(rings) lines"
pass "a repeat ring for the same queued notes waits out the rewake window"

#!/usr/bin/env bash
# tests/jg-composer-self-repair.test.sh - the sentinel repairs our own stale doorbell line in the
# primary's input box, and the captain hears nothing (task jg-7v6uw-s32).
#
# Real Herdr lab session, never the default. A stand-in primary (a bash loop registered as a Herdr
# agent with a session id, as tests/jg-sentinel-inbox-ring.test.sh does) holds a message box whose
# text the test controls: a flag file makes it report busy, another makes it ignore the clear key.
# The captain is away (state/.afk), a wake waits (state/.sentinel-wake-pending), and each case
# runs the real sentinel tick:
#   1. a whole stale line in a turn: cleared by key, one repair row, the wake follows once the turn ends
#   2. a leading part of a line, agent idle: cleared and the wake is delivered in the same tick
#   3. a whole stale line, agent idle: submitted, one repair row
#   4. a person's draft: no key reaches the box, no row, the wake waits
#   5. a long turn with an empty box: the wake waits and arrives at the end of the turn
#   6. a box that will not clear: the second failed repair calls the relaunch command once, no more
# No case may call the captain: the stand-in for bin/jg-captain-say.sh must stay unused.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="jg-lab-self-repair-$$"
export HERDR_SESSION="$SESSION"
LAB=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/jg-self-repair.XXXXXX") || exit 1
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

JG_HOME=$("$ROOT/bin/jg-lab-home.sh" create "$LAB/home") || fail "cannot create the lab home"
STATE=$JG_HOME/state
mkdir -p "$JG_HOME/data"
ROWS=$JG_HOME/data/composer-repairs.tsv
SUBMITTED=$LAB/submitted.log
KEYS=$LAB/keys.log
BUF=$LAB/box.txt
ALERTS=$LAB/alerts.log
RELAUNCH=$LAB/relaunch.log
: >"$SUBMITTED"; : >"$KEYS"; : >"$BUF"; : >"$ALERTS"; : >"$RELAUNCH"
SID=lab-primary-session-32
STALE="$STATE/operational-inbox/1-aaaaaaaaaaaaaaaa.msg"
STALE_LINE=": Juggernaut operational input waiting: read '$STALE' and handle its contents as Juggernaut operational input."

CONTAINER_RAW=$(jg_backend_herdr_container_ensure /tmp) || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED=${CONTAINER_RAW#*$'\t'}
TASK_IDS=$(jg_backend_herdr_create_task "$CONTAINER" jg-repair-primary /tmp "$SEEDED") || fail "cannot create the primary pane"
read -r _TAB PANE <<<"$TASK_IDS"
[ -n "$PANE" ] || fail "no primary pane"
TARGET="$SESSION:$PANE"

# The stand-in: types into one box (the screen shows what the box holds), logs each submitted line,
# clears the box on C-u unless $LAB/ignore-clear exists, and reports busy while $LAB/busy exists.
cat >"$LAB/primary.sh" <<'LOOP'
#!/usr/bin/env bash
LAB=$1 SID=$2
rep() { herdr pane report-agent "$HERDR_PANE_ID" --source herdr:claude --agent claude --state "$1" --session "$HERDR_SESSION" >/dev/null 2>&1; }
herdr pane report-agent-session --source herdr:claude --agent claude --seq "$(date +%s%N)" --agent-session-id "$SID" --session-start-source startup --session "$HERDR_SESSION" "$HERDR_PANE_ID" >/dev/null 2>&1
MAIN=$$
trap 'screen' USR1
( last=; while :; do
    if [ -e "$LAB/busy" ]; then now=working; else now=idle; fi
    [ "$now" = "$last" ] || { last=$now; kill -USR1 "$MAIN" 2>/dev/null; }
    rep "$now"; sleep 0.3
  done ) &
stty -echo -icanon min 1 time 0 2>/dev/null || true
buf=
screen() {
  printf '\033[2J\033[H'
  [ ! -e "$LAB/busy" ] || printf '✻ Working… (12s · esc to interrupt)\n'
  printf '❯ %s' "$buf"; printf '%s' "$buf" >"$LAB/box.txt"
}
screen
while :; do
  IFS= read -r -n 1 c; rc=$?
  [ "$rc" -le 128 ] || continue
  [ "$rc" -eq 0 ] || break
  if [ -z "$c" ] || [ "$c" = $'\r' ]; then
    printf '%s\n' "$buf" >>"$LAB/submitted.log"; buf=; screen
  elif [ "$c" = $'\025' ]; then
    printf 'C-u\n' >>"$LAB/keys.log"
    [ -e "$LAB/ignore-clear" ] || { buf=; screen; }
  else buf="$buf$c"; printf '%s' "$c"; printf '%s' "$buf" >"$LAB/box.txt"; fi
done
LOOP
chmod +x "$LAB/primary.sh"
# argv[0] claude makes the pane's foreground process read as an agent and not as a shell (a shell
# pane's busy state reads unknown, so the busy cases would prove nothing).
jg_backend_herdr_send_text_line "$TARGET" "exec -a claude bash '$LAB/primary.sh' '$LAB' '$SID'" || fail "cannot start the stand-in primary"
sleep 2
printf '%s\n' "$SID" >"$STATE/.lock-session"
printf 'away\n' >"$STATE/.afk"
rm -f "$STATE/.last-watcher-beat"

cat >"$LAB/say.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$ALERTS"
SH
printf '#!/usr/bin/env bash\nprintf "called\\n" >>"%s"\n' "$RELAUNCH" >"$LAB/relaunch.sh"
chmod +x "$LAB/say.sh" "$LAB/relaunch.sh"

tick() {
  JG_HOME=$JG_HOME JG_SENTINEL_HERDR_SESSION=$SESSION JG_SENTINEL_TMP_SWEEP_SECS=0 JG_TMP_WARN_PCT=101 \
    JG_SENTINEL_CAPTAIN_SAY="$LAB/say.sh" JG_SENTINEL_PRIMARY_RELAUNCH="$LAB/relaunch.sh" \
    "$ROOT/bin/jg-sentinel.sh" tick >>"$LAB/tick.out" 2>&1
}
set_busy() {  # on|off: the flag drives the reported state; the stand-in redraws its busy line
  if [ "$1" = on ]; then touch "$LAB/busy"; else rm -f "$LAB/busy"; fi
  # Herdr settles a reported state over a few seconds; wait until the sentinel's own reader agrees.
  local want=idle i=0
  [ "$1" != on ] || want=busy
  while [ "$i" -lt 40 ]; do
    [ "$(jg_backend_busy_state herdr "$TARGET")" != "$want" ] || return 0
    sleep 0.25; i=$((i + 1))
  done
  fail "the stand-in never read $want"
}
pend() { printf '%s\n' "wake body $1" >"$STATE/.sentinel-wake-pending"; }
rows() { grep -c . "$ROWS" 2>/dev/null || true; }
fresh_rings() { grep -c "operational input waiting" "$SUBMITTED" 2>/dev/null | head -1; }
box() { cat "$BUF" 2>/dev/null; }
type_in() {  # <text>: type without submitting
  jg_backend_herdr_send_literal "$TARGET" "$1" || fail "cannot type into the stand-in"
  sleep 0.6
}
reset_case() {  # empty box, no flags, no wake
  rm -f "$LAB/busy" "$LAB/ignore-clear" "$STATE/.sentinel-wake-pending" "$STATE/.sentinel-repair-failed"
  jg_backend_herdr_send_key "$TARGET" C-u >/dev/null 2>&1; sleep 0.8
  : >"$KEYS"; : >"$SUBMITTED"
}

tick   # the first tick records the Herdr identity
reset_case
[ -z "$(box)" ] || fail "the stand-in box is not empty to start: $(box)"

# 1. A whole stale line while the agent is in a turn: cleared by key, then the wake waits for the turn's end.
reset_case; set_busy on
type_in "$STALE_LINE"
[ -n "$(box)" ] || fail "the stale line did not reach the box"
pend one
tick
[ -z "$(box)" ] || fail "the stale line is still in the box: $(box)"
[ "$(rows)" = 1 ] || fail "expected one repair row, got $(rows): $(cat "$ROWS" 2>/dev/null)"
grep -q 'cleared-by-key' "$ROWS" || fail "the row does not say the line was cleared by key: $(cat "$ROWS")"
[ "$(fresh_rings)" = 0 ] || fail "typed a wake into a turn"
[ -e "$STATE/.sentinel-wake-pending" ] || fail "the wake was dropped while the agent was busy"
set_busy off
tick
[ "$(fresh_rings)" = 1 ] || fail "the wake did not arrive at the end of the turn: $(tail -3 "$STATE/.sentinel.log")"
[ ! -e "$STATE/.sentinel-wake-pending" ] || fail "the delivered wake is still pending"
[ "$(rows)" = 1 ] || fail "a second row appeared for the end-of-turn delivery"
pass "a stale line in a turn is cleared by key, one row, and the wake arrives at the end of the turn"

# 2. A leading part of a line, agent idle: cleared and the wake delivered in the same tick.
reset_case
type_in "${STALE_LINE:0:70}"
[ -n "$(box)" ] || fail "the partial line did not reach the box"
pend two
before=$(rows)
tick
[ "$(fresh_rings)" = 1 ] || fail "the wake was not delivered in the same tick: $(tail -3 "$STATE/.sentinel.log")"
grep -q "aaaaaaaa" "$SUBMITTED" && fail "the partial stale line was submitted"
[ "$(rows)" = $((before + 1)) ] || fail "expected one new repair row"
pass "a partial stale line is cleared and the wake is delivered in the same tick"

# 3. A whole stale line, agent idle: submitted, not cleared.
reset_case
type_in "$STALE_LINE"
pend three
before=$(rows)
tick
grep -q "aaaaaaaaaaaaaaaa" "$SUBMITTED" || fail "the stale line was not submitted: $(cat "$SUBMITTED")"
[ ! -s "$KEYS" ] || fail "a clear key was sent to an idle agent's whole line"
[ "$(rows)" = $((before + 1)) ] || fail "expected one new repair row"
tail -n 1 "$ROWS" | grep -q 'submitted' || fail "the row does not say submitted: $(tail -n 1 "$ROWS")"
pass "a whole stale line on an idle agent is submitted, one row"

# 4. A person's draft: no key, no row, the wake waits.
reset_case
type_in "please look at the build before you do anything else"
pend four
before=$(rows)
tick
[ "$(box)" = "please look at the build before you do anything else" ] || fail "the person's draft was touched: $(box)"
[ ! -s "$KEYS" ] || fail "a key reached a person's draft"
[ "$(rows)" = "$before" ] || fail "a person's draft produced a repair row"
[ -e "$STATE/.sentinel-wake-pending" ] || fail "the wake was dropped behind a person's draft"
[ ! -s "$SUBMITTED" ] || fail "something was submitted over a person's draft: $(cat "$SUBMITTED")"
grep -q "someone else's text" "$STATE/.sentinel.log" || fail "the wait was not logged"
pass "a person's draft gets no key and no row; the wake waits"

# 5. A long turn only (empty box): the wake waits, then arrives at the end of the turn.
reset_case; set_busy on
pend five
before=$(rows)
tick; tick
[ "$(fresh_rings)" = 0 ] || fail "typed a wake into a turn"
[ -e "$STATE/.sentinel-wake-pending" ] || fail "the wake was dropped during the turn"
[ "$(rows)" = "$before" ] || fail "a busy agent produced a repair row"
set_busy off
tick
[ "$(fresh_rings)" = 1 ] || fail "the wake did not arrive when the turn ended: $(tail -3 "$STATE/.sentinel.log")"
pass "a long turn: the wake waits and arrives at its end"

# 6. A box that will not clear: the second failed repair calls the relaunch command once.
reset_case; touch "$LAB/ignore-clear"; set_busy on
type_in "$STALE_LINE"
pend six
tick
[ ! -s "$RELAUNCH" ] || fail "relaunched after one failed repair"
tick
[ "$(grep -c called "$RELAUNCH")" = 1 ] || fail "expected one relaunch after two failed repairs, got $(grep -c called "$RELAUNCH")"
tick; tick
[ "$(grep -c called "$RELAUNCH")" = 1 ] || fail "relaunched more than once for the same wake"
[ -e "$STATE/.sentinel-wake-pending" ] || fail "the wake was dropped behind a box that would not clear"
pass "two failed repairs call the relaunch once, and only once"

# No case may have called the captain.
[ ! -s "$ALERTS" ] || fail "the captain was called: $(cat "$ALERTS")"
pass "no case called the captain"

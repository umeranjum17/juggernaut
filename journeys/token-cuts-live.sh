#!/usr/bin/env bash
# done-done journey: the lead's wake turns over one fixed hour of events, before and after the
# token cuts, through the real jg_wake_append (a turn is an event that routes to `now`), then
# the settled types stay out of the queue, the cap holds, and the digest arrives once.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
BEFORE_RULES=${TOKEN_CUTS_BEFORE_RULES:-}
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
LOG=$OUT/token-cuts-live.txt
: >"$LOG"
fails=0
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
expect() {  # <label> <want> <got>
  if [ "$2" = "$3" ]; then say "ok - $1"; else say "FAIL $1: want [$2] got [$3]"; fails=1; fi
}
if [ -z "$BEFORE_RULES" ]; then
  BEFORE_RULES=$T/before.routing
  grep -v -E '^(silent@|set silence-cap|set restart-pass)' "$REPO/defaults/wake-routing" >"$BEFORE_RULES"
fi

# One hour: 8 pause acks and 6 timers on parked homes, 4 restart-pass relaunch notices, 3 re-arms,
# 3 events that need a model, 9 merged-PR checks. Prints "<class> <what>" per event.
run_hour() {  # <routing-file> <home-dir>
  local rules=$1 home=$2 state=$2/state i
  mkdir -p "$state" "$home/config" "$home/homes" "$home/tmp" "$home/root"
  : >"$home/config/parked-homes"
  for i in 1 2 3 4 5 6 7 8; do
    mkdir -p "$home/homes/alpha$i"
    printf 'alpha%s\n' "$i" >"$home/homes/alpha$i/.jg-squad-lead-home"
    printf 'kind=squad_lead\nhome=%s\n' "$home/homes/alpha$i" >"$state/alpha$i.meta"
    printf 'alpha%s\n' "$i" >>"$home/config/parked-homes"
  done
  mkdir -p "$home/homes/beta"
  printf 'beta\n' >"$home/homes/beta/.jg-squad-lead-home"
  printf 'kind=squad_lead\nhome=%s\n' "$home/homes/beta" >"$state/beta.meta"
  printf '%s\tbeta\n' "$(date +%s)" >"$state/.squad-lead-restart-pass"
  JG_HOME=$home JG_STATE_OVERRIDE=$state JG_CONFIG_OVERRIDE=$home/config JG_WAKE_ROUTING=$rules \
    JG_ROOT_OVERRIDE=$home/root TMPDIR=$home/tmp bash -c '
    . "$1/bin/jg-wake-lib.sh"
    ev() { jg_wake_append "$1" "$2" "$3"; printf "%s %s\n" "${JG_WAKE_LAST%%:*}" "$4"; }
    for i in 1 2 3 4 5 6 7 8; do
      printf "paused [at=%s]: acknowledged\n" "$i" >"$STATE/alpha$i.status"
      ev signal "alpha$i.status" "signal: alpha$i.status" pause-ack
    done
    for i in 1 2 3 4; do
      ev check "squad-lead-relaunch-beta-$i" "check: squad_lead beta auto-relaunched after dead (pane)" relaunch-notice
    done
    for i in 1 2 3 4 5 6; do
      ev check "waiting-timer-$i-owner" "check: waiting-state alpha$((i % 8 + 1)) (blocked, observed 900s)" paused-timer
    done
    for i in 1 2 3; do
      c=$(jg_wake_route_class check rearm-resurface "check: rearm-resurface"); echo "$c rearm-resurface"
    done
    printf "needs-decision [at=1]: pick\n" >"$STATE/w1.status"; ev signal w1.status "signal: w1.status" needs-decision
    printf "failed [at=2]: broke\n" >"$STATE/w2.status"; ev signal w2.status "signal: w2.status" failed
    printf "done [at=3]: shipped\n" >"$STATE/w3.status"; ev signal w3.status "signal: w3.status" done
    for i in 1 2 3 4 5 6 7 8 9; do ev check "merged-$i" "check: merged-$i https://example.test/pull/$i" merged-check; done
  ' _ "$REPO"
}

turns() { awk '$1 == "now"' | wc -l | tr -d ' '; }
BEFORE_LOG=$OUT/events-before.txt
AFTER_LOG=$OUT/events-after.txt
run_hour "$BEFORE_RULES" "$T/before" >"$BEFORE_LOG" 2>&1
run_hour "$REPO/defaults/wake-routing" "$T/after" >"$AFTER_LOG" 2>&1
total=$(wc -l <"$AFTER_LOG" | tr -d ' ')
b=$(turns <"$BEFORE_LOG")
a=$(turns <"$AFTER_LOG")
say "== the same $total events in one hour"
say "wake turns before: $b"
say "wake turns after:  $a"
expect "the events that need a model still wake it" 3 "$(awk '$1 == "now" && ($2 == "needs-decision" || $2 == "failed" || $2 == "done")' "$AFTER_LOG" | wc -l | tr -d ' ')"
expect "no silenced wake type wakes a model" 0 "$(awk '$1 == "now" && ($2 == "pause-ack" || $2 == "relaunch-notice" || $2 == "paused-timer" || $2 == "rearm-resurface")' "$AFTER_LOG" | wc -l | tr -d ' ')"
[ "$a" -lt "$b" ] || { say "FAIL wake turns did not drop: $b -> $a"; fails=1; }

say "== each silenced type stays silent: recorded, never queued"
Q=$T/after/state/.wake-queue
S=$T/after/state/.wake-settled
for needle in alpha1.status squad-lead-relaunch-beta-1 waiting-timer-1-owner; do
  expect "$needle is not in the queue" 0 "$(grep -c -F "$needle" "$Q" 2>/dev/null)"
  expect "$needle is readable in the settled record" 1 "$(grep -q -F "$needle" "$S" 2>/dev/null && echo 1 || echo 0)"
done
expect "the needs-decision event is queued" 1 "$(grep -q -F w1.status "$Q" 2>/dev/null && echo 1 || echo 0)"


say "== the batched digest arrives once"
DT=$T/digest
mkdir -p "$DT/state" "$DT/config"
OPT=$REPO/core/escalation-optimize/bin/jg-escalation-optimize.sh
now=$(date +%s)
dec() { JG_HOME=$DT JG_STATE_OVERRIDE=$DT/state JG_CONFIG_OVERRIDE=$DT/config JG_WAKE_ROUTING=$REPO/defaults/wake-routing bash "$OPT" "$@"; }
for i in 1 2 3 4 5 6 7 8 9; do dec decide check "merged-$i" "pr$i evidence=[merged $i] action=[none]" "" "$((now + i))" >/dev/null; done
expect "nine events are held below the event count" "" "$(dec flush "$((now + 20))")"
dec decide check merged-10 "pr10 evidence=[merged 10] action=[none]" "" "$((now + 21))" >/dev/null
digest=$(dec flush "$((now + 22))")
expect "the tenth event flushes exactly one digest" 1 "$(printf '%s\n' "$digest" | grep -c .)"
say "$digest"
expect "the digest does not arrive twice" "" "$(dec flush "$((now + 900))")"

cat >"$OUT/steps.json" <<JSON
{"target":{"version":"$(git -C "$REPO" rev-parse --short HEAD)"},"start":"two disposable homes, old and new routing, the same $total events",
 "steps":["feed the hour through the real wake append","count model turns","check settled types stay out of the queue","fill the cap","flush the digest"],
 "result":"wake turns fell from $b to $a"}
JSON
if [ "$fails" -eq 0 ]; then say "PASS: wake turns $b -> $a over the same hour"; exit 0; fi
exit 1

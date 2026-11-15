#!/usr/bin/env bash
# Integration test for the registered check core/green-pin-stale/stale.sh on a throwaway trunk: a real git repository, the real
# core/machines/observers/trunk.sh and the real bin/jg-alert.sh, one fixture home per case.
# G1 a pin 60 minutes old with commits above it raises ONE line-red alert to Main (rung 3) for each cause, and the note names it:
#    red (a verify failed), over budget (a shard ran past its budget), verify running (a live process holds the verify slot).
# G2 a second tick, and a third a minute later, during the same stall raise no second alert (one record, one wake).
# G3 a pin that moved less than 60 minutes ago, a tip at the pin, and a stall whose oldest commit just landed raise nothing.
# G4 the pin moving ends the open alert, and a later stall above the new pin raises its own.
# G5 the wiring installs the check, registers it and the installed shim raises the alert; the unwiring removes it.
# With DONE_DONE_EVIDENCE_ROOT set it writes green-pin-stale.log there.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(jg_test_tmproot jg-green-pin-stale)
LOG=${DONE_DONE_EVIDENCE_ROOT:+$DONE_DONE_EVIDENCE_ROOT/green-pin-stale.log}
say() { printf '%s\n' "$*" | tee -a "${LOG:-/dev/null}"; }
ok() { say "ok - $1"; }
export TZ=UTC
NOW=1800000000
OLD=$((NOW - 7200))  # two hours ago: the commits landed and the pin moved then
export JG_GREEN_PIN_STALE_NOW=$NOW JG_GREEN_PIN_STALE_ALERT=$ROOT/bin/jg-alert.sh
CHECK=$ROOT/core/green-pin-stale/stale.sh

c1='' c2='' c3=''
# home <name>: a home with project "proj" on trunk "release/v1": c1 is the green pin and c2, c3 landed above it, two hours ago.
home() {
  local h=$T/$1 d
  d=$h/projects/proj
  mkdir -p "$h/state" "$h/data" "$h/config" "$d"
  git -C "$d" init -q -b release/v1
  for n in 1 2 3; do
    printf '%s\n' "$n" > "$d/f"; git -C "$d" add f
    GIT_AUTHOR_DATE="@$OLD +0000" GIT_COMMITTER_DATE="@$OLD +0000" git -C "$d" -c user.name=t -c user.email=t@t commit -q -m "c$n"
    eval "c$n=$(git -C "$d" rev-parse HEAD)"
  done
  printf '%s\n' "$c3" > "$h/state/trunk-tip-proj"; printf '%s\n' "$c1" > "$h/state/trunk-green-proj"
  touch -d "@$OLD" "$h/state/trunk-green-proj"
  H=$h
}
tick() { env -u JG_STATE_OVERRIDE bash "$CHECK" check "$1"; }
keys() { JG_STATE_OVERRIDE=$1/state "$ROOT/bin/jg-alert.sh" list 2>/dev/null | grep -c 'stale-pin' || true; }
note() { cat "$1"/state/alerts/line-red--proj-stale-pin-*.rec 2>/dev/null; }
wakes() { grep -c 'stale-pin' "$1/state/.wake-queue" 2>/dev/null || true; }

# G1 + G2: one case per cause.
for cause in red 'over budget' 'verify running'; do
  home "g1-${cause// /-}"; h=$H; verify_pid=''
  case $cause in
    red) printf 'proj\t%s\t%s\tred\n' "$c2" "$OLD" > "$h/data/trunk-ci.tsv" ;;
    'over budget') mkdir -p "$h/data/trunk"; printf '%s\t%s\tshard-1\t900000\t600000\t3.0\t8\n' "$OLD" "$c3" > "$h/data/trunk/load-proj.tsv" ;;
    'verify running') mkdir -p "$h/state/.trunk-verify-proj.lock"; sleep 30 & verify_pid=$!; echo "$verify_pid" > "$h/state/.trunk-verify-proj.lock/pid" ;;
  esac
  tick "$h"
  [ "$(keys "$h")" = 1 ] || fail "$cause: one alert expected, got $(keys "$h")"
  note "$h" | grep -q "Cause - $cause:" || fail "$cause: the note names the cause: $(note "$h")"
  note "$h" | grep -q '^rung=3$' || fail "$cause: the alert goes to Main (rung 3): $(note "$h")"
  [ "$(wakes "$h")" = 1 ] || fail "$cause: one wake to Main expected, got $(wakes "$h")"
  before=$(wakes "$h")
  JG_GREEN_PIN_STALE_NOW=$((NOW + 60)) tick "$h"; JG_GREEN_PIN_STALE_NOW=$((NOW + 600)) tick "$h"
  [ "$(keys "$h")" = 1 ] && [ "$(wakes "$h")" = "$before" ] || fail "$cause: a later tick of the same stall raised again"
  [ -z "$verify_pid" ] || kill "$verify_pid" 2>/dev/null
  ok "G1/G2 $cause: one alert to Main naming it, and no second alert on later ticks"
done

# G3: nothing to say.
home g3-moved; h=$H; touch -d "@$((NOW - 1800))" "$h/state/trunk-green-proj"; tick "$h"
[ "$(keys "$h")" = 0 ] || fail "a pin that moved 30 minutes ago raised an alert"
home g3-clean; h=$H; printf '%s\n' "$c3" > "$h/state/trunk-green-proj"; tick "$h"
[ "$(keys "$h")" = 0 ] || fail "a tip at the pin raised an alert"
home g3-fresh-landing; h=$H; printf 'proj\t%s\t%s\t%s\tlane\n' x "$c2" "$((NOW - 600))" > "$h/data/trunk-landings.tsv"; tick "$h"
[ "$(keys "$h")" = 0 ] || fail "commits landed 10 minutes ago above an old pin raised an alert"
home g3-59; h=$H; touch -d "@$((NOW - 3540))" "$h/state/trunk-green-proj"; tick "$h"
[ "$(keys "$h")" = 0 ] || fail "a pin 59 minutes old raised an alert"
ok "G3 a pin that moved, a tip at the pin, a fresh landing and 59 minutes raise nothing"

# G4: the pin moves, the alert ends; a new stall above the new pin alerts again.
home g4; h=$H; tick "$h"; [ "$(keys "$h")" = 1 ] || fail "G4: no first alert"
printf '%s\n' "$c2" > "$h/state/trunk-green-proj"; touch -d "@$((NOW + 100))" "$h/state/trunk-green-proj"; JG_GREEN_PIN_STALE_NOW=$((NOW + 200)) tick "$h"
[ "$(JG_STATE_OVERRIDE=$h/state "$ROOT/bin/jg-alert.sh" word "line-red--proj-stale-pin-${c1:0:12}")" = resolved ] || fail "G4: the pin moved and the alert stayed open"
JG_GREEN_PIN_STALE_NOW=$((NOW + 4000)) tick "$h"
JG_STATE_OVERRIDE=$h/state "$ROOT/bin/jg-alert.sh" show "line-red--proj-stale-pin-${c2:0:12}" >/dev/null 2>&1 || fail "G4: no alert for the stall above the new pin"
ok "G4 a moved pin ends the alert and a new stall alerts once more"

# G5: wiring round trip through the real register script.
home g5; h=$H; ln -sn "$ROOT/bin" "$h/bin"; ln -sn "$ROOT/core" "$h/core"
export XDG_DATA_HOME=$T/xdg
{
  bash "$ROOT/core/green-pin-stale/wiring.sh" "$h" >/dev/null || fail "G5: wiring failed"
  [ -x "$XDG_DATA_HOME/jg-green-pin-stale/stale.sh" ] && [ -x "$h/state/green-pin-stale.check.sh" ] || fail "G5: the check is not installed"
  "$h/state/green-pin-stale.check.sh"; [ "$(keys "$h")" = 1 ] || fail "G5: the installed shim raised no alert"
  bash "$ROOT/core/green-pin-stale/unwiring.sh" "$h" >/dev/null || fail "G5: unwiring failed"
  [ ! -e "$h/state/green-pin-stale.check.sh" ] && [ ! -e "$XDG_DATA_HOME/jg-green-pin-stale/stale.sh" ] || fail "G5: unwiring left the check behind"
  ok "G5 wiring installs and registers the check, and unwiring removes it"
}
printf 'pass\n'

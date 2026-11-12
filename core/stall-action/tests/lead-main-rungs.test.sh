#!/usr/bin/env bash
# Journey: lead.sh check and main-beat.sh run against a fixture home. The squad lead machine observer is the real one; the
# send, control and alert commands are recorders; beats, inbox files, the lock and the wake queue are the real records.
# a) a lead whose last beat is a working one 11 min old while its home has work is rung once, not relaunched in the same
#    sweep, relaunched on a later sweep, and never rung or relaunched twice for the same beat;
# b) three relaunches in 30 min raise supervision-down for the lead and relaunch no more;
# c) an idle lead (last beat Stop), a lead with a fresh beat, a lead whose home has no work and a parked lead are untouched;
# d) a steer waiting 2 min for an idle lead is rung once; at 11 min the undelivered alert is raised; an empty inbox resolves it;
# e) a Main whose last beat is a working one 11 min old is restarted once and the owner is paged once; a rerun does nothing;
# f) a wake unacknowledged for 21 min restarts Main too; a fresh beat and a young queue resolve the alert; a stopped session is left alone.
# Usage: stall-action/tests/lead-main-rungs.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
FM=$d/fm LH=$d/leadhome
mkdir -p "$FM/state/beats" "$FM/data" "$FM/config" "$LH/state"
NOW=$(date +%s); export JG_LEAD_NOW=$NOW JG_MAIN_NOW=$NOW
export STUB_LOG=$d/calls
cat > "$d/rec" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$STUB_LOG"
STUB
chmod +x "$d/rec"; for n in send control alert relaunch; do ln -s "$d/rec" "$d/$n"; done
export JG_LEAD_SEND=$d/send JG_LEAD_CONTROL=$d/control JG_LEAD_ALERT=$d/alert JG_MAIN_ALERT=$d/alert JG_MAIN_RELAUNCH=$d/relaunch
LOG=${DONE_DONE_EVIDENCE_ROOT:+$DONE_DONE_EVIDENCE_ROOT/lead-main-rungs.log}
fails=0
say() { printf '%s\n' "$*" | tee -a "${LOG:-/dev/null}"; }
check() { if [ "$2" = "$3" ]; then say "ok: $1"; else say "FAIL: $1 (want: $3, got: $2)"; fails=$((fails + 1)); fi; }
calls() { grep -c "^$1 " "$STUB_LOG" 2>/dev/null || true; }
: > "$STUB_LOG"
sweep() { printf '%s' "$(bash "$SRC/lead.sh" check "$FM")"; }
at() { JG_LEAD_NOW=$(( NOW + $1 )) bash "$SRC/lead.sh" check "$FM"; }   # a sweep <n> seconds later

# lead <id> <beat event> <minutes since the beat> <work yes|no>
lead() {
  printf 'window=default:w1:p%s\nkind=squad_lead\n' "$1" > "$FM/state/$1.meta"
  printf -- '- %s - the %s lead (home: %s; scope: fixture)\n' "$1" "$1" "$LH" >> "$FM/data/squad_leads.md"
  printf '%s %s\n' "$(( NOW - $3 * 60 ))" "$2" > "$FM/state/beats/$1"
}
lead late UserPromptSubmit 11 yes; lead idle Stop 11 yes; lead fresh PostToolBatch 2 yes
printf 'kind=ship\n' > "$LH/state/work.meta"   # the home's own lane: the machine word of every lead above is working

out=$(sweep)
check "a) the check prints nothing" "$out" ""
check "a) the late lead is rung once" "$(grep -c '^send late --fire-and-forget' "$STUB_LOG")" 1
check "a) no other lead is rung" "$(grep -c '^send' "$STUB_LOG")" 1
check "a) not relaunched in the same sweep" "$(calls control)" 0
sweep >/dev/null
check "a) a second sweep in the gap neither rings nor relaunches" "$(calls send)$(calls control)" 10
at 130 >/dev/null
check "a) after the gap the lead is relaunched" "$(grep -c '^control late relaunch' "$STUB_LOG")" 1
at 400 >/dev/null
check "a) the same beat is acted on no more" "$(calls send)$(calls control)" 11

# b) three relaunches inside 30 min
: > "$STUB_LOG"; rm -f "$FM/data/lead-rungs/actions.tsv"
for i in 1 2 3; do printf '%s\tlate\trelaunch\tbeat%s\tok\n' "$(( NOW - i * 300 ))" "$i"; done > "$FM/data/lead-rungs/actions.tsv"
sweep >/dev/null
check "b) three relaunches in 30 min raise supervision-down" "$(grep -c '^alert raise supervision-down lead-late' "$STUB_LOG")" 1
check "b) and relaunch no more" "$(calls control)" 0

# c) no work, parked
: > "$STUB_LOG"; rm -f "$FM/data/lead-rungs/actions.tsv"; rm "$LH/state/work.meta"
check "c) a home with no work leaves a late lead alone" "$(sweep >/dev/null; calls send)$(calls control)" 00
printf 'kind=ship\n' > "$LH/state/work.meta"; printf 'late\n' > "$FM/config/parked-homes"
check "c) a parked lead is left alone" "$(sweep >/dev/null; calls send)$(calls control)" 00
rm -f "$FM/config/parked-homes"; rm -f "$FM/state/late.meta" "$FM/state/fresh.meta"

# d) a steer waiting for the idle lead
: > "$STUB_LOG"; mkdir -p "$FM/state/idle.inbox"
printf 'steer\n' > "$FM/state/idle.inbox/001.msg"; touch -d "@$(( NOW - 120 ))" "$FM/state/idle.inbox/001.msg"
sweep >/dev/null
check "d) a 2 min old steer is rung once" "$(grep -c '^send idle --fire-and-forget' "$STUB_LOG")" 1
sweep >/dev/null
check "d) and not rung again" "$(calls send)" 1
touch -d "@$(( NOW - 660 ))" "$FM/state/idle.inbox/001.msg"; sweep >/dev/null
check "d) at 11 min the undelivered alert is raised" "$(grep -c '^alert raise undelivered lead-idle' "$STUB_LOG")" 1
rm "$FM/state/idle.inbox/001.msg"; sweep >/dev/null
check "d) an empty inbox resolves it" "$(grep -c '^alert resolve undelivered--lead-idle' "$STUB_LOG")" 1

# e) Main
: > "$STUB_LOG"
sleep 300 & live=$!; echo "$live" > "$FM/state/.lock"
main() { JG_HOME=$FM bash "$SRC/../sentinel/main-beat.sh" run; }
printf '%s UserPromptSubmit\n' "$(( NOW - 660 ))" > "$FM/state/beats/main"
main
check "e) a silent Main is restarted" "$(calls relaunch)" 1
check "e) and the owner is paged" "$(grep -c '^alert raise supervision-down main-silent' "$STUB_LOG")" 1
main
check "e) a rerun for the same beat does nothing" "$(calls relaunch)$(grep -c '^alert raise' "$STUB_LOG")" 11

# f) a wake unacknowledged, a fresh beat, a stopped session
: > "$STUB_LOG"; printf '%s Stop\n' "$(( NOW - 30 ))" > "$FM/state/beats/main"
printf '7\t%s000\tcheck\tk\treason\n' "$(( NOW - 1260 ))" > "$FM/state/.wake-queue"
main
check "f) a wake unacknowledged for 21 min restarts Main" "$(calls relaunch)" 1
: > "$STUB_LOG"; printf '8\t%s000\tcheck\tk\treason\n' "$(( NOW - 60 ))" > "$FM/state/.wake-queue"
main
check "f) a young queue and a fresh beat resolve the alert" "$(grep -c '^alert resolve supervision-down--main-silent' "$STUB_LOG")$(calls relaunch)" 10
: > "$STUB_LOG"; kill "$live"; wait "$live" 2>/dev/null || true
printf '%s UserPromptSubmit\n' "$(( NOW - 3600 ))" > "$FM/state/beats/main"; rm -f "$FM/data/main-beat/episodes"
main
check "f) a stopped session is left alone" "$(calls relaunch)" 0

if [ "$fails" -eq 0 ]; then say "PASS"; else say "FAILED: $fails"; exit 1; fi

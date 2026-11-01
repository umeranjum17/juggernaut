#!/usr/bin/env bash
# done-done journey: replay a stalled ready backlog in real time with the shipped timings.
# A disposable main home and Squad Lead home each run the real bin/jg-watch.sh and
# bin/jg-wake-drain.sh as a supervision loop over a copy of this checkout; the lead's
# backlog is a real tasks-axi backlog with one ready item and four free lanes, and nothing
# starts. Only the terminal (one idle lead pane), the board, and the steer and interrupt
# endpoints are recorders, because a disposable lead has no live pane to type into.
# Expected: the lead's ready-work wake at once, the backstop at 10 minutes (lead re-woken,
# Main told and steering the lead), a re-fire 10 minutes later, the board card 10 minutes after
# Main first saw the report, and the report and card closed once the item is held. Writes the timeline and records into the evidence folder.
# shellcheck disable=SC2329 # the wait and check helpers are called through "$@"
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
T=$(mktemp -d)
FORK="$T/fork"
M="$T/main"
L="$T/lead"
mkdir -p "$FORK"
cp -a "$REPO/bin" "$REPO/core" "$FORK/"
for f in jg-send.sh jg-control.sh; do
  # shellcheck disable=SC2016 # the recorder expands its own arguments when run
  printf '#!/usr/bin/env bash\nprintf "%%s %%s %%s\\n" "$(date +%%s)" %s "$*" >> "$JG_HOME/sent"\n' "${f%.sh}" > "$FORK/bin/$f"
done

home() {  # <dir>
  mkdir -p "$1/state" "$1/config" "$1/data" "$1/home" "$1/tmp" "$1/fakebin"
  cat > "$1/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
t=; prev=
for a in "$@"; do [ "$prev" = -t ] && t=$a; prev=$a; done
case "${1:-}" in
  list-windows) printf 'fake:1\n' ;;
  capture-pane) [ "$t" = fake:1 ] || exit 1; printf 'all quiet\n> \n' ;;
  display-message)
    [ "$t" = fake:1 ] || exit 1
    case "$*" in *pane_tty*) printf '/dev/pts/fake\n' ;; *pane_current_command*) printf 'claude\n' ;; *) printf '%%1\n' ;; esac ;;
  *) exit 1 ;;
esac
SH
  cat > "$1/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(date +%s)" "$*" >> "$JG_HOME/cards"
case "${1:-}" in
  raise) shift; while [ $# -gt 1 ]; do [ "$1" = --key ] && printf '%s\n' "$2" >> "$JG_HOME/open-cards"; shift; done ;;
  dismiss) [ -f "$JG_HOME/open-cards" ] && { grep -vxF "$2" "$JG_HOME/open-cards" > "$JG_HOME/open-cards.new"; mv "$JG_HOME/open-cards.new" "$JG_HOME/open-cards"; } ;;
  list) printf '{"decisions":['
        [ -f "$JG_HOME/open-cards" ] && sed 's/.*/{"key":"&"}/' "$JG_HOME/open-cards" | paste -sd, -
        printf ']}\n' ;;
esac
exit 0
SH
  chmod +x "$1/fakebin/"*
}
home "$M"
home "$L"
printf 'lead1\n' > "$L/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$M" > "$L/.jg-squad-lead-parent"
printf 'kind=squad_lead\nmode=squad_lead\nbackend=tmux\nwindow=fake:1\nharness=claude\nhome=%s\n' "$L" > "$M/state/lead1.meta"
: > "$M/state/lead1.status"
printf '4\n' > "$L/config/lane-target"
JG_HOME="$L" "$FORK/bin/jg-tasks-axi.sh" add alpha "[feature] ship the routed fix" --priority 1 --body "users wait on the routed fix" >/dev/null || { echo "fixture: backlog add failed"; exit 1; }

START=$(date +%s)
stamp() { printf '+%4ss' "$(( $(date +%s) - START ))"; }
log() { printf '%s %s\n' "$(stamp)" "$*" | tee -a "$OUT/timeline.txt"; }

# One supervision loop: run the watcher until it wakes, log the wake, drain and
# acknowledge it, and start the next watcher, until the journey stops it.
supervise() {  # <home> <label>
  local h=$1 label=$2 pid seq gen line
  while [ ! -e "$T/stop" ]; do
    env -i HOME="$h/home" TMPDIR="$h/tmp" PATH="$h/fakebin:$PATH" LANG=C.UTF-8 \
      JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" JG_CONFIG_OVERRIDE="$h/config" \
      JG_SQUAD_LEAD_LIVENESS_SECS=99999999 JG_BUSY_TURN_MAX_SECS=999999 JG_STALE_ESCALATE_SECS=999999 \
      JG_SQUAD_LEAD_WAKE_STALL_SECS=999999 JG_HOME_SUMMARY_INTERVAL=999999 \
      "$FORK/bin/jg-watch.sh" > "$h/out" 2>> "$h/err" &
    pid=$!
    printf '%s\n' "$pid" > "$h/watcher.pid"
    wait "$pid" 2>/dev/null
    [ ! -e "$T/stop" ] || break
    while IFS= read -r line; do
      [ -n "$line" ] && log "$label wake: $line"
    done < "$h/out"
    JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" "$FORK/bin/jg-wake-drain.sh" > "$h/drain" 2> "$h/ack"
    seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$h/ack")
    gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$h/ack")
    [ -z "$seq" ] || JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" "$FORK/bin/jg-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  done
}

overdue() { grep -c 'waiting-timer-backlog-overdue' "$M/state/lead1.status"; }
wait_until() {  # <deadline-seconds-from-start> <command...>
  local deadline=$(( START + $1 ))
  shift
  while ! "$@" && [ "$(date +%s)" -lt "$deadline" ]; do sleep 5; done
  "$@"
}
fired_twice() { [ "$(overdue)" -ge 2 ]; }
resolved() { grep -q 'waiting-timer-cleared: lead1 ready backlog' "$M/state/lead1.status"; }
carded() { grep -q 'ready-backlog-card' "$M/cards" 2>/dev/null; }
dismissed() { grep -q 'dismiss waiting-timer-.*-ready-backlog-card' "$M/cards" 2>/dev/null; }
steered_twice() { [ "$(grep -c 'You have ready backlog work' "$M/sent" 2>/dev/null)" -ge 2 ]; }

: > "$OUT/timeline.txt"
log "start: lead home has ready item alpha (P1), lane target 4, 0 lanes open; nothing will start"
supervise "$L" lead &
supervise "$M" main &
wait_until 1800 fired_twice
log "parent channel holds $(overdue) stalled-backlog report(s) from the lead"
wait_until 1900 steered_twice
wait_until 1950 carded
log "Main has steered the lead $(grep -c 'You have ready backlog work' "$M/sent" 2>/dev/null) time(s)"
JG_HOME="$L" "$FORK/bin/jg-tasks-axi.sh" hold alpha --reason "waits on the vendor" >/dev/null
log "the lead holds alpha with its reason"
wait_until 2100 resolved
wait_until 2250 dismissed
sleep 40
log "stop"
: > "$T/stop"
for h in "$L" "$M"; do kill "$(cat "$h/watcher.pid" 2>/dev/null)" 2>/dev/null || true; done
wait

# Only records that show the outcome go in the evidence folder: done-done refuses an empty
# or duplicate file, so the board recorder and the watchers' stderr are checked below instead.
cp "$M/state/lead1.status" "$OUT/main-parent-channel-lead1.txt"
cp "$M/sent" "$OUT/main-steers-to-lead.txt" 2>/dev/null || : > "$OUT/main-steers-to-lead.txt"

# Checks, each against the recorded files above.
check() {  # <label> <command...>
  local label=$1
  shift
  if "$@"; then echo "PASS $label"; else echo "FAIL $label"; fi
}
quiet() { ! [ -s "$1" ] && ! [ -s "$2" ]; }  # <file> <file>: both absent or empty
between() { [ -n "$1" ] && [ "$1" -ge "$2" ] && [ "$1" -lt "$3" ]; }  # <value> <low> <high>
t1=0
first_at=$(sed -n 's/.*waiting-timer-backlog-overdue: .*since=\([0-9]*\)).*/\1/p' "$M/state/lead1.status" | head -n 1)
times=$(sed -n 's/^blocked \[key=[^]]*\] \[at=\([0-9]*\)\]: waiting-timer-backlog-overdue: .*/\1/p' "$M/state/lead1.status")
t1=$(printf '%s\n' "$times" | sed -n 1p)
t2=$(printf '%s\n' "$times" | sed -n 2p)
{
  echo "episode armed at $first_at; first report at $t1 (after $((t1 - first_at))s); re-fire at $t2 ($((t2 - t1))s later)"
  check "the lead's first-sight ready-work wake fired" grep -q 'lead wake: check: ready work waiting with free lane slots (0/4 open): alpha' "$OUT/timeline.txt"
  check "the first stalled-backlog report came at 10 minutes, not before" between "$((t1 - first_at))" 600 720
  check "the lead was woken again by the backstop" grep -q 'lead wake: check: ready backlog stalled: alpha waits with free lanes (0/4 open)' "$OUT/timeline.txt"
  check "Main got an event from the report" grep -q 'main wake: .*lead1' "$OUT/timeline.txt"
  check "Main steered the lead about its ready backlog" grep -q 'jg-send lead1 --fire-and-forget [0-9a-f]* You have ready backlog work that can start now' "$OUT/main-steers-to-lead.txt"
  check "the report re-fired 10 minutes later" between "$((${t2:-0} - t1))" 600 720
  check "Main steered the lead again on the re-fire" [ "$(grep -c 'You have ready backlog work' "$OUT/main-steers-to-lead.txt")" -ge 2 ]
  check "Main posted the board card for the still-open report" grep -q 'raise.*--key waiting-timer-.*-ready-backlog-card' "$M/cards"
  check "holding the item dismissed the board card" grep -q 'dismiss waiting-timer-.*-ready-backlog-card' "$M/cards"
  check "holding the item closed Main's report" grep -q '^resolved \[key=waiting-timer-.*-ready-backlog\].*waiting-timer-cleared: lead1 ready backlog: no ready work waits to start now' "$M/state/lead1.status"
  check "neither watcher wrote to stderr" quiet "$L/err" "$M/err"
  for f in "$L/err" "$M/err"; do [ -s "$f" ] && { echo "stderr of ${f#"$T"/}:"; head -n 20 "$f"; }; done
} | tee "$OUT/checks.txt"
fails=0
grep -q '^FAIL' "$OUT/checks.txt" && fails=1

cat > "$OUT/steps.json" <<J
{"target":{"version":"juggernaut $(git -C "$REPO" rev-parse HEAD)"},
 "start":"a disposable main home and Squad Lead home, each supervised by the real watcher and wake drain; the lead's real backlog has one ready P1 item, lane target 4, no lane open, and the lead never starts it",
 "steps":["the lead's watcher raises its ready-work wake at once","10 minutes pass with nothing started","the lead's watcher wakes the lead again and reports the stalled backlog to Main on the parent channel","Main's watcher wakes on the report and steers the lead","10 more minutes pass and both fire again","the lead holds the item with its reason"],
 "result":"the lead was re-woken and Main was told and steered the lead at 10 minutes and again 10 minutes later, Main posted the board card while the report stayed open, and holding the item closed the report and the card"}
J
rm -rf -- "$T"
exit "$fails"

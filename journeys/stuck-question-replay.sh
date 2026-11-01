#!/usr/bin/env bash
# done-done journey: a real Claude worker (Haiku) opens an AskUserQuestion dialog in a private
# tmux server; the real bin/jg-watch.sh and wait-timers library, with thresholds shortened to
# seconds, record it as a wait source and climb owner -> Main -> board card, then clear when the
# dialog is answered. Only the steer/interrupt endpoints and the board are recorders.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
T=$(mktemp -d)
H=$T/home F=$T/fork
export TMUX_TMPDIR=$T/tmux
mkdir -p "$TMUX_TMPDIR" "$H/state" "$H/config" "$H/home" "$H/tmp" "$H/work" "$T/fakebin" "$F"
trap 'tmux kill-server 2>/dev/null; rm -rf -- "$T"' EXIT
cp -a "$REPO/bin" "$REPO/core" "$F/"
for f in jg-send.sh jg-control.sh; do
  # shellcheck disable=SC2016 # the recorder expands its own arguments when run
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %s "$*" >> "$JG_HOME/sent"\n' "${f%.sh}" > "$F/bin/$f"
done
cat > "$T/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
log="$JG_HOME/cards"
case "${1:-}" in
  raise)
    key=; prev=
    for a in "$@"; do [ "$prev" = --key ] && key=$a; prev=$a; done
    printf 'raise %s\n' "$*" >> "$log"
    grep -Fxq "$key" "$log.open" 2>/dev/null || printf '%s\n' "$key" >> "$log.open" ;;
  list) printf '{"decisions":[%s]}\n' "$(sed 's/.*/{"key":"&"}/' "$log.open" 2>/dev/null | paste -sd, -)" ;;
  dismiss) printf 'dismiss %s\n' "$2" >> "$log" ;;
esac
SH
chmod +x "$T/fakebin/sign-off-axi"
log() { printf '%s\n' "$*" | tee -a "$OUT/replay.txt"; }
cycle() {
  env -u JG_TASK_ID HOME="$H/home" TMPDIR="$H/tmp" PATH="$T/fakebin:$PATH" JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" \
    JG_CONFIG_OVERRIDE="$H/config" JG_POLL=1 JG_SIGNAL_GRACE=1 JG_CHECK_INTERVAL=999999 \
    JG_HEARTBEAT=999999 JG_HOME_SUMMARY_INTERVAL=999999 JG_WAIT_ALERT_SECS=2 JG_WAIT_ESCALATE_SECS=4 JG_WAIT_CARD_SECS=6 \
    JG_PROMPT_REALERT_SECS=900 timeout 20 "$F/bin/jg-watch.sh" >> "$H/events" 2>> "$H/err"
  JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" "$F/bin/jg-wake-drain.sh" > /dev/null 2> "$H/ack"
  local seq gen
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$H/ack")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$H/ack")
  [ -z "$seq" ] || JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" "$F/bin/jg-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" > /dev/null 2>&1
}
until_seen() {  # <pattern> <file> - cycle until the pattern shows (at most 8 cycles)
  local _
  for _ in 1 2 3 4 5 6 7 8; do grep -qE -e "$1" "$2" 2>/dev/null && return 0; cycle; done
  grep -qE -e "$1" "$2" 2>/dev/null
}
backdate() {
  local f=$H/state/.waiting-timers/w1 sig since owner parent key misses card last v out=()
  IFS=$'\t' read -r sig since owner parent key misses card last < "$f"
  for v in "$since" "$owner" "$parent" "${card:-0}" "${last:-0}"; do
    if [ "$v" -gt 1 ]; then out+=("$((v - 8))"); else out+=("$v"); fi
  done
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sig" "${out[0]}" "${out[1]}" "${out[2]}" "$key" "${misses:-0}" "${out[3]}" "${out[4]}" > "$f"
}
fail() { log "FAIL: $*"; cp "$H/err" "$OUT/watcher-stderr.txt" 2>/dev/null; cp "$H/events" "$OUT/watcher-events.txt" 2>/dev/null; cp "$H/cards" "$OUT/board-calls.txt" 2>/dev/null; ls -R "$H/state/.waiting-timers" "$H/state/.wait-sources" >> "$OUT/replay.txt" 2>&1; tmux capture-pane -p -t lab:w > "$OUT/pane-at-failure.txt" 2>/dev/null; exit 1; }

: > "$OUT/replay.txt"
tmux new-session -d -s lab -n w -x 150 -y 45 -c "$H/work" \
  "claude --model claude-haiku-5-5 --dangerously-skip-permissions 'Call the AskUserQuestion tool right now with one question: Which color? options Red and Blue. Do nothing else.'"
for _ in $(seq 1 60); do tmux capture-pane -p -t lab:w | grep -q 'Enter to select' && break; sleep 1; done
tmux capture-pane -p -t lab:w > "$OUT/pane-question.txt"
grep -q 'Enter to select' "$OUT/pane-question.txt" || fail "the real Claude worker never opened its question dialog"
log "worker pane shows the question dialog: $(grep 'Enter to select' "$OUT/pane-question.txt" | tr -s ' ')"
printf 'kind=ship\nbackend=tmux\nwindow=lab:w\nharness=claude\n' > "$H/state/w1.meta"
: > "$H/state/w1.status"
until_seen . "$H/state/.wait-sources/w1.question" || fail "the watcher recorded no question wait source"
log "wait source: $(cat "$H/state/.wait-sources/w1.question")"
sleep 3; backdate
until_seen 'waiting-state w1 \(question.*level=owner' "$H/events" || fail "the question never reached the owner rung"
log "owner rung fired"
backdate
until_seen 'waiting-state w1 \(question.*level=main' "$H/events" || fail "the question never reached Main"
log "Main rung fired"
backdate
until_seen '-w1-.*-question-card' "$H/cards" || fail "no board card was raised: $(cat "$H/err")"
log "board card raised: $(grep -c raise "$H/cards") raise call(s)"
tmux send-keys -t lab:w Enter
for _ in $(seq 1 30); do tmux capture-pane -p -t lab:w | grep -q 'Enter to select' || break; sleep 1; done
tmux capture-pane -p -t lab:w > "$OUT/pane-answered.txt"
! grep -q 'Enter to select' "$OUT/pane-answered.txt" || fail "the dialog is still open after the answer"
for _ in 1 2 3 4; do [ ! -e "$H/state/.wait-sources/w1.question" ] || cycle; done
[ ! -e "$H/state/.wait-sources/w1.question" ] || fail "the wait source outlived the answered dialog"
cp "$H/events" "$OUT/watcher-events.txt"; cp "$H/cards" "$OUT/board-calls.txt"
log "dialog answered; wait source cleared"
jq -n --arg v "$(claude --version 2>/dev/null | head -1)" --arg sha "$(git -C "$REPO" rev-parse --short HEAD)" '{target:{version:("bin/jg-watch.sh at " + $sha + " driving " + $v)},
  start:"a real Claude Haiku worker pane with no question open",
  steps:["the worker opens an AskUserQuestion dialog","the watcher records the dialog as a question wait source","the owner rung fires","the Main rung fires","a board card is raised","the dialog is answered"],
  result:"the wait source and episode are cleared after the dialog is answered"}' > "$OUT/steps.json"
log "PASS"

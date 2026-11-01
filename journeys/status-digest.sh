#!/usr/bin/env bash
# done-done journey: the batch digest, driven by the real script against real
# records. A milestone pushes the five lines at once, a second run inside the
# configured window pushes nothing, a changed state past the window pushes once,
# and a live captain channel takes the digest instead of a card.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
DIGEST=$REPO/bin/jg-status-digest.sh
LOG=$OUT/status-digest.txt
: > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
fail() { log "FAIL: $*"; exit 1; }
# The live digest cards on the proof board: a replaced card stays on the board
# with a discarded status, so only the rows still waiting are live.
live_cards() {
  sign-off-axi list "$BOARD" --full 2>/dev/null | grep 'status-digest-' | grep -c ',waiting,'
}

# One home with the records the digest reads, and a real board for the card.
HOME_DIR=$T/home
mkdir -p "$HOME_DIR"/{data/metrics,config,bin} || fail "cannot build the fixture home"
{
  printf 'home\ttask\tkind\tproject\tmodels\tstarted\tended\toutcome\tpr\n'
  printf 'main\tlanded-a\tship\tx\tpi:m\t1799999000\t1800000100\tmerged\thttps://example.test/1\n'
  printf 'main\tlanded-b\tship\tx\tpi:m\t1799999000\t1800000200\tmerged\thttps://example.test/2\n'
  printf 'main\tolder\tship\tx\tpi:m\t1700000000\t1700000900\tmerged\thttps://example.test/3\n'
} > "$HOME_DIR/data/metrics/task-outcomes.tsv"
printf 'every-hours=4\n' > "$HOME_DIR/config/status-digest"
(
  cd "$T" && SIGN_OFF_HOME=$T/so sign-off-axi init >/dev/null 2>&1
) || fail "could not create the proof board"
BOARD=$T/.sign-off/decisions.json
[ -f "$BOARD" ] || fail "the proof board was not created"
printf '%s\n' "$BOARD" > "$HOME_DIR/config/fleet-board"

log "== the fixture table"
bash "$REPO/tests/jg-status-digest.test.sh" >> "$LOG" 2>&1 || fail "the fixture table failed"

log ""
log "== one milestone on real records: it pushes at once"
OUT1=$(bash "$DIGEST" "$HOME_DIR" record "the migration card landed" --left "3 items left in the batch" \
  --blockers "one review" --since 1799999000 --now 1800001000 2>&1) || fail "the milestone did not push: $OUT1"
log "$OUT1"
COUNT=$(live_cards)
log "live cards on the proof board: $COUNT"
[ "$COUNT" = 1 ] || {
  sign-off-axi list "$BOARD" --full | tee -a "$LOG" >/dev/null
  fail "the milestone should leave one live card on the board, found $COUNT"
}
log "the card the board lists:"
sign-off-axi list "$BOARD" --full | grep 'status-digest-' | tee -a "$LOG" >/dev/null

log ""
log "== a second run inside the 4 h window: nothing is resent"
OUT2=$(bash "$DIGEST" "$HOME_DIR" tick --now 1800003600 2>&1) || fail "a tick inside the window failed: $OUT2"
log "$OUT2"
COUNT=$(live_cards)
log "live cards on the proof board: $COUNT"
[ "$COUNT" = 1 ] || fail "a tick inside the window must not post another card, found $COUNT"

log ""
log "== a changed state past the window: one push, replacing the card"
printf 'main\tlanded-c\tship\tx\tpi:m\t1799999000\t1800010000\tmerged\thttps://example.test/4\n' \
  >> "$HOME_DIR/data/metrics/task-outcomes.tsv"
printf 'jg-0.9.0 2026-11-01 the first batch release\n' > "$HOME_DIR/data/releases"
OUT3=$(bash "$DIGEST" "$HOME_DIR" tick --now 1800016000 2>&1) || fail "the cadence push failed: $OUT3"
log "$OUT3"
COUNT=$(live_cards)
log "live cards on the proof board: $COUNT (the previous card is dismissed)"
[ "$COUNT" = 1 ] || fail "one live digest card expected after the cadence push, found $COUNT"
sign-off-axi list "$BOARD" --full | grep 'status-digest-' | tee -a "$LOG" >/dev/null

log ""
log "== the same state again past the window: never pushed twice"
OUT4=$(bash "$DIGEST" "$HOME_DIR" tick --now 1800031000 2>&1) || fail "the repeat tick failed: $OUT4"
log "$OUT4"
case $OUT4 in *unchanged*) : ;; *) fail "an unchanged digest must not be pushed again: $OUT4" ;; esac

log ""
log "== a live captain channel: it takes the digest instead of a card"
cat > "$HOME_DIR/bin/jg-bus.sh" <<'SH'
#!/usr/bin/env bash
[ "${1-}" = config ] && { printf 'live\n'; exit 0; }
printf 'captain channel %s\n' "$*" >> "$BUS_LOG"
SH
chmod +x "$HOME_DIR/bin/jg-bus.sh"
: > "$T/bus.log"
OUT5=$(BUS_LOG=$T/bus.log bash "$DIGEST" "$HOME_DIR" record "the captain channel went live" \
  --left "2 items left in the batch" --since 1799999000 --now 1800100000 2>&1) || fail "the channel push failed: $OUT5"
log "$OUT5"
cat "$T/bus.log" >> "$LOG"
grep -q '^captain channel publish digest status-digest-' "$T/bus.log" || fail "the digest did not reach the captain channel"
log "the live card count did not move: $(live_cards)"

log ""
log "RESULT: the milestone pushed the five lines once, the window held for 4 h, a changed state past the window pushed once and replaced the card, the same state was never pushed twice, and a live captain channel took the digest instead of a card."
jq -n '{target:{version:"bin/jg-status-digest.sh from this branch"},
  start:"a home with the task outcome and release records, config/status-digest at 4 h, and a real board",
  steps:["run the fixture table",
         "record one milestone on real records and read the board",
         "tick inside the 4 h window and read the board again",
         "change the records, tick past the window and read the board",
         "tick again with the same state",
         "record with a live captain channel"],
  result:"the milestone pushed the five lines once, the window held, the changed state pushed once and replaced the card, the same state was never pushed twice, and the live channel took the digest instead of a card"}' > "$OUT/steps.json"
